"""The HTTP surface: the same application, reached through a browser.

Every command the Tk interface offers has an endpoint here, and nothing else
does. The two limits the service enforces -- four transcriptions at once for
the whole backend, one at a time per user -- live in jobs.py; this module only
reports them honestly so the front end can show a queue rather than a button
that quietly does nothing.
"""

from __future__ import annotations

import asyncio
import json
import re
import secrets
import unicodedata
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Any, AsyncIterator, Dict

from fastapi import Body, FastAPI, File, Form, HTTPException, Request, Response, UploadFile
from fastapi.responses import StreamingResponse
from fastapi.staticfiles import StaticFiles

from . import catalogue as catalogue_module
from . import config, jobs as jobs_module
from .transcript import FORMATS, extension_for, media_type_for

SESSION_COOKIE = "va_session"
FRONTEND_DIR = Path(__file__).resolve().parents[1] / "frontend"

store = jobs_module.JobStore()
catalogue = catalogue_module.Catalogue()
downloader = catalogue_module.Downloader(catalogue)


@asynccontextmanager
async def lifespan(_: FastAPI) -> AsyncIterator[None]:
    config.ensure_directories()
    store.load_sessions()
    store.load_jobs()
    yield


app = FastAPI(title="voiceannotate", docs_url=None, redoc_url=None, lifespan=lifespan)


# --- who is asking ----------------------------------------------------------
#
# A cookie, nothing more. There is no account system here: "a user" means a
# browser, which is what the per-user limit is really about -- one person
# should not be able to fill the machine from one window.


def session_id(request: Request) -> str:
    return request.cookies.get(SESSION_COOKIE) or ""


def ensure_session(request: Request, response: Response) -> str:
    existing = session_id(request)
    if existing and re.fullmatch(r"[0-9a-f]{32}", existing):
        return existing
    fresh = secrets.token_hex(16)
    response.set_cookie(
        SESSION_COOKIE,
        fresh,
        max_age=60 * 60 * 24 * 365,
        httponly=True,
        samesite="lax",
    )
    return fresh


def owned_job(request: Request, job_id: str) -> jobs_module.Job:
    job = store.jobs.get(job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="no such job")
    if job.session != session_id(request):
        # Not "forbidden": whose job it is is not something to confirm to
        # somebody who is not its owner.
        raise HTTPException(status_code=404, detail="no such job")
    return job


def safe_filename(name: str) -> str:
    """A name that is only ever used as a leaf, with a known extension."""
    name = unicodedata.normalize("NFC", name or "")
    name = Path(name).name
    name = re.sub(r"[^\w.\- ]+", "_", name, flags=re.UNICODE).strip() or "audio"
    stem, dot, extension = name.rpartition(".")
    extension = f".{extension.lower()}" if dot else ""
    if extension not in config.AUDIO_EXTENSIONS:
        raise HTTPException(
            status_code=400,
            detail="only MP3 and WAV are read. Convert first: "
            "ffmpeg -i source.m4a -ar 16000 -ac 1 out.wav",
        )
    return f"{(stem or 'audio')[:120]}{extension}"


def public_models() -> list:
    """The installed models, by name and kind only.

    Where they sit on the server is nobody's business but the server's, and
    the page never needs it: it sends a name back, and resolve_model turns
    that into a directory on this side.
    """
    return [
        {"name": m["name"], "kind": m["kind"]}
        for m in catalogue_module.installed_models()
    ]


# --- state ------------------------------------------------------------------


@app.get("/api/state")
async def get_state(request: Request, response: Response) -> Dict[str, Any]:
    session = ensure_session(request, response)
    settings = store.settings_for(session)

    # A first visit gets whatever models are on the machine already, the way a
    # first launch of the native application does.
    if not settings.model or not settings.spkmodel:
        detected = catalogue_module.autodetect()
        settings.model = settings.model or detected["model"]
        settings.spkmodel = settings.spkmodel or detected["spkmodel"]

    return {
        "settings": settings.to_dict(),
        "models": public_models(),
        "queue": store.capacity(),
        "jobs": [job.view() for job in store.jobs_for(session)],
        "download": downloader.view(),
        "limits": {
            "max_upload_bytes": config.MAX_UPLOAD_BYTES,
            "allow_model_download": config.ALLOW_MODEL_DOWNLOAD,
            "formats": list(FORMATS),
        },
    }


@app.put("/api/settings")
async def put_settings(
    request: Request, response: Response, payload: Dict[str, Any] = Body(default={})
) -> Dict[str, Any]:
    session = ensure_session(request, response)
    settings = jobs_module.Settings.from_dict(
        {**store.settings_for(session).to_dict(), **payload}
    )
    store.set_settings(session, settings)
    return settings.to_dict()


@app.get("/api/queue")
async def get_queue() -> Dict[str, Any]:
    return store.capacity()


@app.get("/api/models")
async def get_models() -> Dict[str, Any]:
    return {"models": public_models()}


# --- the catalogue ----------------------------------------------------------


@app.get("/api/catalogue")
async def get_catalogue(refresh: bool = False) -> Dict[str, Any]:
    try:
        return await catalogue.view(refresh=refresh)
    except Exception as error:  # noqa: BLE001 -- someone else's server
        raise HTTPException(
            status_code=502,
            detail=f"Vosk's model list could not be fetched: {error}",
        ) from error


@app.post("/api/catalogue/download")
async def post_download(payload: Dict[str, Any] = Body(default={})) -> Dict[str, Any]:
    name = str(payload.get("name") or "")
    try:
        return await downloader.start(name)
    except PermissionError as error:
        raise HTTPException(status_code=403, detail=str(error)) from error
    except LookupError as error:
        raise HTTPException(status_code=404, detail=str(error)) from error
    except RuntimeError as error:
        raise HTTPException(status_code=409, detail=str(error)) from error


@app.get("/api/catalogue/download")
async def get_download() -> Dict[str, Any]:
    return {"download": downloader.view(), "models": public_models()}


@app.post("/api/catalogue/download/cancel")
async def cancel_download() -> Dict[str, Any]:
    return {"cancelled": downloader.cancel()}


# --- jobs -------------------------------------------------------------------


@app.post("/api/jobs")
async def post_job(
    request: Request,
    response: Response,
    file: UploadFile = File(...),
    settings: str = Form("{}"),
) -> Dict[str, Any]:
    session = ensure_session(request, response)

    try:
        submitted = json.loads(settings or "{}")
    except json.JSONDecodeError:
        submitted = {}
    merged = jobs_module.Settings.from_dict(
        {**store.settings_for(session).to_dict(), **submitted}
    )
    store.set_settings(session, merged)

    if not catalogue_module.resolve_model(merged.model, "recognition"):
        raise HTTPException(
            status_code=400,
            detail="Choose a Vosk recognition model in the panel on the right.",
        )

    # Checked before the file is written, so a user who is over their limit
    # does not first upload half a gigabyte for nothing.
    mine = store.active_for(session)
    if len(mine) >= config.MAX_PER_USER:
        raise HTTPException(
            status_code=409,
            detail=f"One transcription at a time. {mine[0].filename} is still going.",
        )

    filename = safe_filename(file.filename or "")
    job = jobs_module.new_job(session, filename, merged)

    written = 0
    try:
        with job.audio_path.open("wb") as handle:
            while chunk := await file.read(1024 * 1024):
                written += len(chunk)
                if written > config.MAX_UPLOAD_BYTES:
                    raise HTTPException(
                        status_code=413,
                        detail=f"the file is larger than "
                        f"{config.MAX_UPLOAD_BYTES // (1024 * 1024)} MB",
                    )
                handle.write(chunk)
    except HTTPException:
        await store.remove(job)
        raise
    if written == 0:
        await store.remove(job)
        raise HTTPException(status_code=400, detail="the file is empty")

    try:
        await store.submit(job)
    except PermissionError as error:
        await store.remove(job)
        raise HTTPException(status_code=409, detail=str(error)) from error

    return {"job": job.view(with_segments=True), "queue": store.capacity()}


@app.get("/api/jobs")
async def get_jobs(request: Request, response: Response) -> Dict[str, Any]:
    session = ensure_session(request, response)
    return {
        "jobs": [job.view() for job in store.jobs_for(session)],
        "queue": store.capacity(),
    }


@app.get("/api/jobs/{job_id}")
async def get_job(request: Request, job_id: str) -> Dict[str, Any]:
    job = owned_job(request, job_id)
    return {"job": job.view(with_segments=True), "queue": store.capacity()}


@app.delete("/api/jobs/{job_id}")
async def delete_job(request: Request, job_id: str) -> Dict[str, Any]:
    job = owned_job(request, job_id)
    await store.remove(job)
    return {"ok": True, "queue": store.capacity()}


@app.post("/api/jobs/{job_id}/cancel")
async def post_cancel(request: Request, job_id: str) -> Dict[str, Any]:
    job = owned_job(request, job_id)
    if not job.active():
        raise HTTPException(status_code=409, detail="that job has already finished")
    await store.cancel(job)
    return {"job": job.view()}


@app.post("/api/jobs/{job_id}/recluster")
async def post_recluster(
    request: Request, job_id: str, payload: Dict[str, Any] = Body(default={})
) -> Dict[str, Any]:
    job = owned_job(request, job_id)
    if job.transcript is None or not job.transcript.segments:
        raise HTTPException(status_code=409, detail="transcribe a file first")

    settings = jobs_module.Settings.from_dict({**job.settings.to_dict(), **payload})
    speakers = store.recluster(job, settings)
    store.set_settings(job.session, jobs_module.Settings.from_dict(settings.to_dict()))
    return {
        "job": job.view(with_segments=True),
        "speakers": speakers,
        # Said out loud because it surprises people: the grouping is redone
        # from scratch, so a name given to "speaker 2" no longer has an owner.
        "note": f"Regrouped: {speakers} speaker(s). Custom names have been reset.",
    }


@app.post("/api/jobs/{job_id}/speakers/{speaker}/name")
async def post_speaker_name(
    request: Request, job_id: str, speaker: int, payload: Dict[str, Any] = Body(default={})
) -> Dict[str, Any]:
    job = owned_job(request, job_id)
    try:
        store.rename_speaker(job, speaker, str(payload.get("name") or ""))
    except LookupError as error:
        raise HTTPException(status_code=404, detail=str(error)) from error
    return {"job": job.view(with_segments=True)}


@app.post("/api/jobs/{job_id}/segments/{index}/speaker")
async def post_segment_speaker(
    request: Request, job_id: str, index: int, payload: Dict[str, Any] = Body(default={})
) -> Dict[str, Any]:
    job = owned_job(request, job_id)
    try:
        speaker = int(payload.get("speaker"))
    except (TypeError, ValueError) as error:
        raise HTTPException(status_code=400, detail="a speaker index is needed") from error
    try:
        store.assign_segment(job, index, speaker)
    except LookupError as error:
        raise HTTPException(status_code=404, detail=str(error)) from error
    return {"job": job.view(with_segments=True)}


@app.get("/api/jobs/{job_id}/export")
async def get_export(request: Request, job_id: str, format: str = "txt") -> Response:
    job = owned_job(request, job_id)
    if job.transcript is None or not job.transcript.segments:
        raise HTTPException(status_code=409, detail="transcribe a file first")
    if format not in FORMATS:
        raise HTTPException(status_code=400, detail=f"unknown format '{format}'")

    body = job.transcript.render(format)
    stem = Path(job.filename).stem
    filename = f"{stem}{extension_for(format)}"
    return Response(
        content=body.encode("utf-8"),
        media_type=media_type_for(format),
        headers={"Content-Disposition": f'attachment; filename="{filename}"'},
    )


# --- the event stream -------------------------------------------------------


@app.get("/api/jobs/{job_id}/events")
async def get_events(request: Request, job_id: str) -> StreamingResponse:
    job = owned_job(request, job_id)
    queue = store.subscribe(job.id)

    async def stream() -> AsyncIterator[bytes]:
        try:
            # The first frame is the whole job: a browser that reconnects
            # mid-run then has everything, rather than only what comes next.
            yield _frame({"type": "snapshot", "job": job.view(with_segments=True),
                          "queue": store.capacity()})
            while True:
                if await request.is_disconnected():
                    break
                try:
                    payload = await asyncio.wait_for(queue.get(), timeout=15.0)
                except asyncio.TimeoutError:
                    # A comment keeps the connection open through a proxy that
                    # would otherwise time it out on a long, quiet wait.
                    yield b": keepalive\n\n"
                    continue
                payload.setdefault("queue", store.capacity())
                yield _frame(payload)
                if payload.get("type") == "state" and not job.active():
                    yield _frame(
                        {"type": "final", "job": job.view(with_segments=True),
                         "queue": store.capacity()}
                    )
                    break
        finally:
            store.unsubscribe(job.id, queue)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={
            "Cache-Control": "no-cache",
            "Connection": "keep-alive",
            # nginx would otherwise hold the stream in a buffer and deliver it
            # in one piece at the end, which is the opposite of the point.
            "X-Accel-Buffering": "no",
        },
    )


def _frame(payload: Dict[str, Any]) -> bytes:
    return f"data: {json.dumps(payload)}\n\n".encode("utf-8")


# --- the page ---------------------------------------------------------------


@app.get("/healthz")
async def healthz() -> Dict[str, Any]:
    return {
        "ok": True,
        "engine": str(config.CLI_BINARY),
        "engine_present": config.CLI_BINARY.exists(),
        **store.capacity(),
    }


app.mount("/", StaticFiles(directory=str(FRONTEND_DIR), html=True), name="frontend")
