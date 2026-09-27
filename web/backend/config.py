"""Where things live, and how many may happen at once.

Everything here is settable from the environment, because the container is
where this runs and the environment is what a container is configured with.
"""

from __future__ import annotations

import os
import shutil
from pathlib import Path


def _int(name: str, default: int) -> int:
    try:
        return int(os.environ.get(name, "") or default)
    except ValueError:
        return default


def _path(name: str, default: str) -> Path:
    return Path(os.environ.get(name, "") or default).expanduser()


# The command-line binary this whole service is a front end for. In the image
# it sits in /opt/voiceannotate/bin; outside it, the repository's own bin/.
_REPO_ROOT = Path(__file__).resolve().parents[2]

CLI_BINARY = Path(
    os.environ.get("VA_CLI")
    or shutil.which("voiceannotate-cli")
    or (_REPO_ROOT / "bin" / "voiceannotate-cli")
).expanduser()

# Uploaded audio, the transcripts made from it, and the job records.
DATA_DIR = _path("VA_DATA_DIR", "/var/lib/voiceannotate")
JOBS_DIR = DATA_DIR / "jobs"
SESSIONS_FILE = DATA_DIR / "sessions.json"

# Vosk models. The first is where a download lands; all of them are searched,
# which mirrors the native application's modelSearchPath.
MODELS_DIR = _path("VA_MODELS_DIR", "/var/lib/voiceannotate/models")
EXTRA_MODEL_DIRS = [
    Path(p).expanduser()
    for p in (os.environ.get("VA_EXTRA_MODEL_DIRS", "") or "").split(":")
    if p.strip()
]


def model_search_path() -> list[Path]:
    seen: list[Path] = []
    for directory in [MODELS_DIR, *EXTRA_MODEL_DIRS, _REPO_ROOT / "models"]:
        if directory not in seen:
            seen.append(directory)
    return seen


# --- the two limits the service exists to enforce --------------------------
#
# The backend transcribes at most MAX_CONCURRENT files at a time, whoever asks;
# past that, jobs wait in a queue and the front end is told where in it they
# are. Separately, one user may have only MAX_PER_USER transcription going,
# so nobody can take the whole machine by submitting ten files.
MAX_CONCURRENT = max(1, _int("VA_MAX_CONCURRENT", 4))
MAX_PER_USER = max(1, _int("VA_MAX_PER_USER", 1))

# An upload larger than this is refused outright rather than filling the disk.
MAX_UPLOAD_BYTES = _int("VA_MAX_UPLOAD_MB", 512) * 1024 * 1024

# How many finished jobs a user keeps. The oldest are dropped, with their
# audio, so an unattended instance does not grow without bound.
MAX_JOBS_PER_USER = max(1, _int("VA_MAX_JOBS_PER_USER", 20))

# Vosk's own catalogue of downloadable models.
CATALOGUE_URL = os.environ.get(
    "VA_CATALOGUE_URL", "https://alphacephei.com/vosk/models/model-list.json"
)
# The server gives out about 0.7 MB/s per connection whatever else is
# happening, so asking for a model in several pieces at once adds up almost
# linearly. Eight is as much as a freely hosted service should be asked for.
DOWNLOAD_CONNECTIONS = max(1, _int("VA_DOWNLOAD_CONNECTIONS", 8))
# Under this, splitting costs more in requests than it saves.
DOWNLOAD_SPLIT_THRESHOLD = 4 * 1024 * 1024

# Downloading a model from the interface is how the native application gets
# one; an instance open to the public may want it off.
ALLOW_MODEL_DOWNLOAD = (os.environ.get("VA_ALLOW_MODEL_DOWNLOAD", "1") or "1") not in (
    "0",
    "no",
    "false",
)

AUDIO_EXTENSIONS = {".mp3", ".wav", ".wave"}


def ensure_directories() -> None:
    for directory in (DATA_DIR, JOBS_DIR, MODELS_DIR):
        directory.mkdir(parents=True, exist_ok=True)
