"""Vosk models: finding the installed ones, and fetching new ones.

This is the web counterpart of the "Vosk models" panel and its "Download a
model..." dialog in tcl/app.tcl. The catalogue is the same JSON file Vosk
publishes, filtered the same way, sorted the same way -- lightest first,
because a full model is a long download to start by accident.

The transfer is split into eight simultaneous byte ranges for the same reason
the native application does it: the server caps a single connection at around
0.7 MB/s whatever else is happening, and the connections add up.

One download runs at a time for the whole service. A model is shared by every
user, so two people asking for the same one must not fetch it twice, and
nobody should be able to saturate the link by queueing forty of them.
"""

from __future__ import annotations

import asyncio
import shutil
import time
import zipfile
from pathlib import Path
from typing import Any, Dict, List, Optional

import httpx

from . import config


# --- what is already on disk ------------------------------------------------


def _looks_like_speaker_model(name: str) -> bool:
    return "spk" in name.lower()


def _looks_like_recognition_model(directory: Path) -> bool:
    # The same test the native application makes: a recognition model carries
    # an am/ or a conf/ directory.
    return (directory / "am").is_dir() or (directory / "conf").is_dir()


def installed_models() -> List[Dict[str, Any]]:
    """Every model directory found, tagged as recognition or speaker."""
    found: Dict[str, Dict[str, Any]] = {}
    for root in config.model_search_path():
        if not root.is_dir():
            continue
        for entry in sorted(root.iterdir()):
            if not entry.is_dir() or entry.name.startswith("."):
                continue
            if entry.name in found:
                continue
            if _looks_like_speaker_model(entry.name):
                kind = "speaker"
            elif _looks_like_recognition_model(entry):
                kind = "recognition"
            else:
                continue
            found[entry.name] = {
                "name": entry.name,
                "path": str(entry),
                "kind": kind,
            }
    return sorted(found.values(), key=lambda m: (m["kind"], m["name"]))


def installed_model_path(name: str) -> Optional[str]:
    for root in config.model_search_path():
        candidate = root / name
        if candidate.is_dir():
            return str(candidate)
    return None


def resolve_model(value: str, kind: str) -> Optional[str]:
    """Turns what the browser sent into a directory on this machine.

    The front end sends a model's name, never a path: a path from a browser is
    a way to point the recogniser at any directory on the server.
    """
    if not value:
        return None
    name = Path(value).name
    for model in installed_models():
        if model["name"] == name and model["kind"] == kind:
            return model["path"]
    return None


def autodetect() -> Dict[str, str]:
    """First recognition model and first speaker model found, by name.

    What the native application does on a first launch, so a container started
    with models already mounted needs nothing configured.
    """
    picked = {"model": "", "spkmodel": ""}
    for model in installed_models():
        if model["kind"] == "speaker" and not picked["spkmodel"]:
            picked["spkmodel"] = model["name"]
        elif model["kind"] == "recognition" and not picked["model"]:
            picked["model"] = model["name"]
    return picked


# --- the published catalogue ------------------------------------------------


def human_bytes(size: int) -> str:
    if size < 1024:
        return f"{size} B"
    value = size / 1024.0
    for unit in ("KiB", "MiB", "GiB"):
        if value < 1024 or unit == "GiB":
            return f"{value:.1f} {unit}"
        value /= 1024.0
    return f"{value:.1f} GiB"


def _field(entry: Dict[str, Any], key: str, fallback: Any = "") -> Any:
    """Missing keys are normal: the catalogue is someone else's file."""
    value = entry.get(key)
    return fallback if value in (None, "") else value


def _model_kind(entry: Dict[str, Any]) -> str:
    return {
        "spk": "speakers",
        "small": "light",
        "big": "full",
        "big-lgraph": "full, lgraph",
    }.get(str(_field(entry, "type")), str(_field(entry, "type")))


def _usable(entries: List[Dict[str, Any]]) -> List[Dict[str, Any]]:
    """Text-to-speech entries share the catalogue but have no use here, and an
    obsolete entry is one upstream has already replaced."""
    out = []
    for entry in entries:
        if not _field(entry, "name") or not _field(entry, "url"):
            continue
        if str(_field(entry, "obsolete")).lower() == "true":
            continue
        if _field(entry, "type") == "tts":
            continue
        out.append(entry)
    return out


class Catalogue:
    """The model list, fetched once and kept."""

    def __init__(self) -> None:
        self._entries: List[Dict[str, Any]] = []
        self._fetched_at = 0.0
        self._lock = asyncio.Lock()

    async def entries(self, refresh: bool = False) -> List[Dict[str, Any]]:
        async with self._lock:
            stale = time.time() - self._fetched_at > 3600
            if self._entries and not refresh and not stale:
                return self._entries
            async with httpx.AsyncClient(timeout=30, follow_redirects=True) as client:
                response = await client.get(config.CATALOGUE_URL)
                response.raise_for_status()
                self._entries = _usable(response.json())
            self._fetched_at = time.time()
            return self._entries

    async def view(self, refresh: bool = False) -> Dict[str, Any]:
        """The list as the dialog shows it: languages, then the rows."""
        entries = await self.entries(refresh)

        languages = sorted(
            {
                str(_field(entry, "lang_text", _field(entry, "lang")))
                # "all" is the speaker model's language: it belongs with every
                # one of them, so it is not offered as a choice of its own.
                for entry in entries
                if _field(entry, "lang") != "all"
            },
            key=str.lower,
        )

        rows = []
        for entry in entries:
            name = str(_field(entry, "name"))
            size = int(_field(entry, "size", 0) or 0)
            rows.append(
                {
                    "name": name,
                    "language": str(_field(entry, "lang_text", _field(entry, "lang"))),
                    "universal": _field(entry, "lang") == "all",
                    "size": size,
                    "size_text": str(_field(entry, "size_text", human_bytes(size))),
                    "kind": _model_kind(entry),
                    "type": str(_field(entry, "type")),
                    "installed": installed_model_path(name) is not None,
                }
            )
        # Smallest first: the light models are what most people want.
        rows.sort(key=lambda r: (r["size"], r["name"]))
        return {"languages": languages, "models": rows}

    async def entry(self, name: str) -> Optional[Dict[str, Any]]:
        for candidate in await self.entries():
            if str(_field(candidate, "name")) == name:
                return candidate
        return None


class Download:
    """One model transfer, watched from the browser while it runs."""

    def __init__(self, name: str, size: int, kind: str) -> None:
        self.name = name
        self.size = size
        self.kind = kind  # "spk" for the speaker model, else recognition
        self.state = "downloading"  # downloading | unpacking | done | failed
        self.received = 0
        self.message = ""
        self.path = ""
        self.task: Optional[asyncio.Task] = None

    def view(self) -> Dict[str, Any]:
        fraction = self.received / self.size if self.size else 0.0
        return {
            "name": self.name,
            "state": self.state,
            "received": self.received,
            "size": self.size,
            "fraction": min(1.0, fraction),
            "message": self.message,
            "kind": "speaker" if self.kind == "spk" else "recognition",
        }


class Downloader:
    """One transfer at a time, for the whole service."""

    def __init__(self, catalogue: Catalogue) -> None:
        self.catalogue = catalogue
        self.current: Optional[Download] = None
        self.last: Optional[Download] = None

    def busy(self) -> bool:
        return self.current is not None

    def view(self) -> Optional[Dict[str, Any]]:
        active = self.current or self.last
        return active.view() if active else None

    async def start(self, name: str) -> Dict[str, Any]:
        if not config.ALLOW_MODEL_DOWNLOAD:
            raise PermissionError("downloading models is switched off on this server")
        if self.busy():
            raise RuntimeError(f"another model is already downloading ({self.current.name})")

        entry = await self.catalogue.entry(name)
        if entry is None:
            raise LookupError(f"no model named {name}")

        existing = installed_model_path(name)
        if existing:
            # Already on disk: put it to use rather than fetch it a second time.
            done = Download(name, int(_field(entry, "size", 0) or 0), str(_field(entry, "type")))
            done.state = "done"
            done.path = existing
            done.message = "already installed"
            self.last = done
            return done.view()

        download = Download(
            name, int(_field(entry, "size", 0) or 0), str(_field(entry, "type"))
        )
        self.current = download
        download.task = asyncio.create_task(self._run(download, str(_field(entry, "url"))))
        return download.view()

    def cancel(self) -> bool:
        if self.current and self.current.task:
            self.current.task.cancel()
            return True
        return False

    async def _run(self, download: Download, url: str) -> None:
        destination = config.MODELS_DIR
        destination.mkdir(parents=True, exist_ok=True)
        cache = destination / ".cache"
        cache.mkdir(parents=True, exist_ok=True)
        archive = cache / f"{download.name}.zip"

        try:
            await self._fetch(url, archive, download)
            download.state = "unpacking"
            # zipfile is blocking and a full model is well over a gigabyte, so
            # it goes to a thread rather than stalling every other request.
            await asyncio.to_thread(self._unpack, archive, destination, download.name)
            download.path = str(destination / download.name)
            download.state = "done"
            download.message = "ready"
        except asyncio.CancelledError:
            download.state = "failed"
            download.message = "cancelled"
            raise
        except Exception as error:  # noqa: BLE001 -- reported, not swallowed
            download.state = "failed"
            download.message = str(error) or error.__class__.__name__
            shutil.rmtree(destination / download.name, ignore_errors=True)
        finally:
            archive.unlink(missing_ok=True)
            self.last = download
            self.current = None

    async def _fetch(self, url: str, archive: Path, download: Download) -> None:
        size = download.size
        connections = config.DOWNLOAD_CONNECTIONS
        timeout = httpx.Timeout(30.0, read=120.0)

        async with httpx.AsyncClient(timeout=timeout, follow_redirects=True) as client:
            if size < config.DOWNLOAD_SPLIT_THRESHOLD or connections < 2:
                await self._fetch_range(client, url, archive, None, download)
                return

            parts = [archive.with_suffix(f".part{i}") for i in range(connections)]
            span = size // connections
            ranges = [
                (i * span, size - 1 if i == connections - 1 else (i + 1) * span - 1)
                for i in range(connections)
            ]
            try:
                await asyncio.gather(
                    *(
                        self._fetch_range(client, url, part, byte_range, download)
                        for part, byte_range in zip(parts, ranges)
                    )
                )
                # The unpacker wants one file and the ranges arrived separately.
                with archive.open("wb") as out:
                    for part in parts:
                        with part.open("rb") as handle:
                            shutil.copyfileobj(handle, out, 1024 * 1024)
                written = archive.stat().st_size
                if size and written != size:
                    # A range that came back short would otherwise surface only
                    # as a corrupt archive, long after the cause is visible.
                    raise RuntimeError(
                        f"the download came back incomplete: "
                        f"{human_bytes(written)} of {human_bytes(size)}"
                    )
            finally:
                for part in parts:
                    part.unlink(missing_ok=True)

    async def _fetch_range(
        self,
        client: httpx.AsyncClient,
        url: str,
        target: Path,
        byte_range: Optional[tuple],
        download: Download,
    ) -> None:
        headers = {}
        if byte_range is not None:
            headers["Range"] = f"bytes={byte_range[0]}-{byte_range[1]}"
        async with client.stream("GET", url, headers=headers) as response:
            response.raise_for_status()
            with target.open("wb") as handle:
                async for chunk in response.aiter_bytes(256 * 1024):
                    handle.write(chunk)
                    download.received += len(chunk)

    @staticmethod
    def _unpack(archive: Path, destination: Path, name: str) -> None:
        with zipfile.ZipFile(archive) as zf:
            for member in zf.namelist():
                # An archive from elsewhere must not be able to write outside
                # the models directory by way of "../" in a member name.
                resolved = (destination / member).resolve()
                if not str(resolved).startswith(str(destination.resolve())):
                    raise RuntimeError(f"refusing a path outside the models directory: {member}")
            zf.extractall(destination)
        if not (destination / name).is_dir():
            raise RuntimeError("the archive did not contain the expected directory")
