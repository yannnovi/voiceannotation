"""Jobs, and the two limits on them.

Two separate rules, asked for separately and enforced separately:

  * The backend transcribes at most VA_MAX_CONCURRENT files at once -- four by
    default -- whoever asks for them. A fifth waits in a queue. This is a
    property of the machine: each run holds a Vosk model and a core, and a
    fifth would only make the other four slower.

  * One user may have at most VA_MAX_PER_USER transcriptions in flight -- one
    by default. This is a fairness rule, not a capacity one: without it a
    single person could fill all four slots and everyone else would wait
    behind them.

The queue is visible. A waiting job knows its position and how many slots are
busy, and the front end shows both, so a wait is something the user can see
rather than a button that stopped working.

The front end also refuses to start a second file for the same user, but that
refusal is a courtesy -- this module is what actually holds the line, because
a browser is not a place to enforce anything.
"""

from __future__ import annotations

import asyncio
import json
import shutil
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any, Dict, List, Optional

from . import config, engine
from .diarize import DiarizerConfig, cluster
from .transcript import Transcript, human_duration

QUEUED = "queued"
RUNNING = "running"
DONE = "done"
FAILED = "failed"
CANCELLED = "cancelled"

TERMINAL = (DONE, FAILED, CANCELLED)


@dataclass
class Settings:
    """The grouping and model settings, as the sidebar holds them."""

    model: str = ""
    spkmodel: str = ""
    threshold: float = 0.05
    minframes: int = 40
    maxspeakers: int = 0
    speaker_prefix: str = "Speaker"

    def to_dict(self) -> Dict[str, Any]:
        return {
            "model": self.model,
            "spkmodel": self.spkmodel,
            "threshold": self.threshold,
            "minframes": self.minframes,
            "maxspeakers": self.maxspeakers,
            "speaker_prefix": self.speaker_prefix,
        }

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Settings":
        base = cls()
        return cls(
            model=str(data.get("model", base.model) or ""),
            spkmodel=str(data.get("spkmodel", base.spkmodel) or ""),
            threshold=_clamp(_float(data.get("threshold"), base.threshold), -0.2, 0.6),
            minframes=int(_clamp(_float(data.get("minframes"), base.minframes), 1, 300)),
            maxspeakers=int(_clamp(_float(data.get("maxspeakers"), base.maxspeakers), 0, 20)),
            speaker_prefix=(str(data.get("speaker_prefix") or base.speaker_prefix)).strip()[:40]
            or base.speaker_prefix,
        )


def _float(value: Any, fallback: float) -> float:
    try:
        return float(value)
    except (TypeError, ValueError):
        return fallback


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


@dataclass
class Job:
    id: str
    session: str
    filename: str
    directory: Path
    settings: Settings
    created: float = field(default_factory=time.time)

    state: str = QUEUED
    message: str = ""
    # Progress, as the status bar shows it.
    fraction: float = 0.0
    position: float = 0.0
    duration: float = 0.0
    elapsed: float = 0.0
    speed: float = 0.0
    segment_count: int = 0
    queue_position: int = 0

    transcript: Optional[Transcript] = None
    run: Optional[engine.Run] = None
    cancel_requested: bool = False
    # Segments seen while the run is going, so the table fills as they arrive.
    live_segments: List[Dict[str, Any]] = field(default_factory=list)

    @property
    def audio_path(self) -> Path:
        return self.directory / "audio" / self.filename

    @property
    def result_path(self) -> Path:
        return self.directory / "transcript.json"

    @property
    def record_path(self) -> Path:
        return self.directory / "job.json"

    def active(self) -> bool:
        return self.state in (QUEUED, RUNNING)

    def status_line(self) -> str:
        """The sentence the status bar shows, worded as in the native app."""
        if self.state == QUEUED:
            if self.queue_position > 0:
                return f"Waiting: number {self.queue_position} in the queue."
            return "Waiting for a free slot..."
        if self.state == RUNNING:
            return self.message or "Transcribing..."
        if self.state == FAILED:
            return f"Failed: {self.message}"
        speakers = self.transcript.speaker_count() if self.transcript else 0
        if self.state == CANCELLED:
            return f"Interrupted: {self.segment_count} segments kept."
        return (
            f"Done: {self.segment_count} segments, {speakers} speaker(s), "
            f"{human_duration(self.duration)} of audio in {human_duration(self.elapsed)}."
        )

    def view(self, with_segments: bool = False) -> Dict[str, Any]:
        out: Dict[str, Any] = {
            "id": self.id,
            "filename": self.filename,
            "state": self.state,
            "message": self.message,
            "status": self.status_line(),
            "created": self.created,
            "fraction": self.fraction,
            "position": self.position,
            "duration": self.duration,
            "elapsed": self.elapsed,
            "speed": self.speed,
            "segment_count": self.segment_count,
            "queue_position": self.queue_position,
            "settings": self.settings.to_dict(),
            "speakers": self.transcript.speakers() if self.transcript else [],
            "speaker_count": self.transcript.speaker_count() if self.transcript else 0,
        }
        if with_segments:
            out["segments"] = (
                self.transcript.segment_views() if self.transcript else self.live_segments
            )
        return out


class JobStore:
    """Every job, the queue in front of them, and the settings per session."""

    def __init__(self) -> None:
        self.jobs: Dict[str, Job] = {}
        self.settings: Dict[str, Settings] = {}
        self.queue: List[str] = []
        self.running: Dict[str, Job] = {}
        self._lock = asyncio.Lock()
        self._subscribers: Dict[str, List[asyncio.Queue]] = {}
        self._slots = asyncio.Semaphore(config.MAX_CONCURRENT)

    # --- settings ---------------------------------------------------------

    def settings_for(self, session: str) -> Settings:
        if session not in self.settings:
            self.settings[session] = Settings()
        return self.settings[session]

    def set_settings(self, session: str, settings: Settings) -> None:
        self.settings[session] = settings
        self._save_sessions()

    def _save_sessions(self) -> None:
        try:
            config.SESSIONS_FILE.parent.mkdir(parents=True, exist_ok=True)
            payload = {
                # A version number, as the native application's config file
                # carries: a setting written when it meant something else must
                # be discarded rather than quietly misapplied.
                "version": 2,
                "sessions": {k: v.to_dict() for k, v in self.settings.items()},
            }
            config.SESSIONS_FILE.write_text(json.dumps(payload), encoding="utf-8")
        except OSError:
            pass

    def load_sessions(self) -> None:
        try:
            payload = json.loads(config.SESSIONS_FILE.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError):
            return
        if payload.get("version") != 2:
            return
        for key, value in (payload.get("sessions") or {}).items():
            self.settings[key] = Settings.from_dict(value)

    # --- the queue --------------------------------------------------------

    def active_for(self, session: str) -> List[Job]:
        return [j for j in self.jobs.values() if j.session == session and j.active()]

    def jobs_for(self, session: str) -> List[Job]:
        return sorted(
            (j for j in self.jobs.values() if j.session == session),
            key=lambda j: j.created,
            reverse=True,
        )

    def capacity(self) -> Dict[str, Any]:
        return {
            "running": len(self.running),
            "capacity": config.MAX_CONCURRENT,
            "queued": len(self.queue),
            "per_user": config.MAX_PER_USER,
        }

    def _renumber_queue(self) -> None:
        for index, job_id in enumerate(self.queue, start=1):
            job = self.jobs.get(job_id)
            if job:
                job.queue_position = index

    async def submit(self, job: Job) -> None:
        async with self._lock:
            mine = [j for j in self.active_for(job.session) if j.id != job.id]
            if len(mine) >= config.MAX_PER_USER:
                raise PermissionError(
                    "one transcription at a time per user: "
                    f"{mine[0].filename} is still going."
                )
            self.jobs[job.id] = job
            self.queue.append(job.id)
            self._renumber_queue()
        self._write_record(job)
        await self.broadcast_queue()
        asyncio.create_task(self._run(job))

    async def _run(self, job: Job) -> None:
        # Waiting on the semaphore is the whole of the four-at-a-time rule.
        # Everything else -- the position, the count of busy slots -- is there
        # only so the wait is visible.
        try:
            async with self._slots:
                async with self._lock:
                    if job.id in self.queue:
                        self.queue.remove(job.id)
                    self._renumber_queue()
                    if job.cancel_requested:
                        job.state = CANCELLED
                        job.message = "Cancelled before it started."
                        await self._publish(job, {"type": "state"})
                        return
                    job.state = RUNNING
                    job.queue_position = 0
                    self.running[job.id] = job
                await self.broadcast_queue()
                await self._transcribe(job)
        except asyncio.CancelledError:
            job.state = CANCELLED
            raise
        except Exception as error:  # noqa: BLE001 -- surfaced to the user
            job.state = FAILED
            job.message = str(error) or error.__class__.__name__
        finally:
            self.running.pop(job.id, None)
            job.run = None
            self._write_record(job)
            await self._publish(job, {"type": "state"})
            await self.broadcast_queue()
            self._prune(job.session)

    async def _transcribe(self, job: Job) -> None:
        from . import catalogue  # late: it reads the disk, and this is startup-cheap

        model = catalogue.resolve_model(job.settings.model, "recognition")
        if not model:
            job.state = FAILED
            job.message = (
                "No recognition model. Choose one in the panel on the right, "
                "or download one."
            )
            return
        speaker_model = catalogue.resolve_model(job.settings.spkmodel, "speaker") or ""

        request = engine.RunRequest(
            audio=job.audio_path,
            output=job.result_path,
            model=model,
            speaker_model=speaker_model,
            threshold=job.settings.threshold,
            min_frames=job.settings.minframes,
            max_speakers=job.settings.maxspeakers,
            speaker_prefix=job.settings.speaker_prefix,
        )
        run = engine.Run(request)
        job.run = run
        if job.cancel_requested:
            run.cancel()

        failure = ""
        async for event in run.events():
            kind = event.get("event")
            if kind == "status":
                job.message = str(event.get("message", ""))
                await self._publish(job, {"type": "status", "message": job.message})
            elif kind == "progress":
                job.fraction = float(event.get("fraction", 0.0) or 0.0)
                job.position = float(event.get("position", 0.0) or 0.0)
                job.duration = float(event.get("duration", 0.0) or 0.0)
                job.elapsed = float(event.get("elapsed", 0.0) or 0.0)
                job.speed = float(event.get("speed", 0.0) or 0.0)
                job.segment_count = int(event.get("segments", 0) or 0)
                await self._publish(
                    job,
                    {
                        "type": "progress",
                        "fraction": job.fraction,
                        "position": job.position,
                        "duration": job.duration,
                        "elapsed": job.elapsed,
                        "speed": job.speed,
                        "segments": job.segment_count,
                    },
                )
            elif kind == "segment":
                row = {
                    "index": int(event.get("index", 0) or 0),
                    "start": float(event.get("start", 0.0) or 0.0),
                    "end": float(event.get("end", 0.0) or 0.0),
                    "duration": max(
                        0.0,
                        float(event.get("end", 0.0) or 0.0)
                        - float(event.get("start", 0.0) or 0.0),
                    ),
                    "speaker": int(event.get("speaker", -1)),
                    "name": _provisional_name(
                        int(event.get("speaker", -1)), job.settings.speaker_prefix
                    ),
                    "text": str(event.get("text", "")),
                }
                job.live_segments.append(row)
                await self._publish(job, {"type": "segment", "segment": row})
            elif kind == "finished":
                job.duration = float(event.get("duration", 0.0) or 0.0)
                job.elapsed = float(event.get("elapsed", 0.0) or 0.0)
                job.fraction = 1.0
                job.state = CANCELLED if event.get("cancelled") else DONE
            elif kind == "failed":
                failure = str(event.get("message", "the run stopped"))

        if failure:
            job.state = FAILED
            job.message = failure
            return
        if job.state not in (DONE, CANCELLED):
            # The process ended without saying how. Treat a cancel we asked
            # for as one; anything else is a failure.
            job.state = CANCELLED if job.cancel_requested else FAILED
            if job.state == FAILED:
                job.message = "the transcription engine stopped unexpectedly"
                return

        try:
            data = json.loads(job.result_path.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            job.state = FAILED
            job.message = f"the transcript could not be read back: {error}"
            return

        transcript = Transcript.from_cli_json(data)
        transcript.speaker_prefix = job.settings.speaker_prefix
        transcript.source_name = job.filename
        # The paths on the server mean nothing to whoever uploaded the file,
        # and are nobody else's business either; the names do, and are what
        # belongs in an export.
        transcript.source_path = job.filename
        transcript.model_path = Path(transcript.model_path).name
        transcript.speaker_model_path = Path(transcript.speaker_model_path).name
        job.transcript = transcript
        job.segment_count = len(transcript.segments)
        job.live_segments = []
        self._save_transcript(job)
        # The text saved beside the audio, as the native application does when
        # a run finishes -- here, beside the upload, for downloading.
        self._save_beside_audio(job)

    # --- what happens after a run ----------------------------------------

    def recluster(self, job: Job, settings: Settings) -> int:
        """Re-groups from the stored embeddings. No audio is touched."""
        if not job.transcript:
            raise LookupError("nothing to regroup")
        transcript = job.transcript
        labels = cluster(
            [s.speaker_vector for s in transcript.segments],
            [s.speaker_frames for s in transcript.segments],
            DiarizerConfig(
                threshold=settings.threshold,
                min_frames=settings.minframes,
                max_speakers=settings.maxspeakers,
            ),
        )
        transcript.relabel(labels)
        job.settings.threshold = settings.threshold
        job.settings.minframes = settings.minframes
        job.settings.maxspeakers = settings.maxspeakers
        self._after_edit(job)
        return transcript.speaker_count()

    def rename_speaker(self, job: Job, speaker: int, name: str) -> None:
        if not job.transcript:
            raise LookupError("nothing to rename")
        if speaker < 0 or speaker >= job.transcript.speaker_count():
            raise LookupError("no such speaker")
        job.transcript.set_speaker_name(speaker, name.strip()[:80])
        self._after_edit(job)

    def assign_segment(self, job: Job, index: int, speaker: int) -> None:
        if not job.transcript:
            raise LookupError("nothing to reassign")
        if not job.transcript.set_segment_speaker(index, speaker):
            raise LookupError("no such segment or speaker")
        self._after_edit(job)

    def _after_edit(self, job: Job) -> None:
        self._save_transcript(job)
        # The saved file is rewritten on every change that alters the text, so
        # it is never a stale copy of what is on screen.
        self._save_beside_audio(job)

    def _save_transcript(self, job: Job) -> None:
        if not job.transcript:
            return
        try:
            job.directory.mkdir(parents=True, exist_ok=True)
            (job.directory / "state.json").write_text(
                json.dumps(job.transcript.to_store()), encoding="utf-8"
            )
        except OSError:
            pass

    def _save_beside_audio(self, job: Job) -> None:
        if not job.transcript:
            return
        try:
            target = job.audio_path.with_suffix(".txt")
            target.write_text(job.transcript.render("txt"), encoding="utf-8")
        except OSError:
            pass

    # --- cancelling -------------------------------------------------------

    async def cancel(self, job: Job) -> None:
        job.cancel_requested = True
        if job.state == QUEUED:
            async with self._lock:
                if job.id in self.queue:
                    self.queue.remove(job.id)
                    self._renumber_queue()
            job.state = CANCELLED
            job.message = "Cancelled before it started."
            self._write_record(job)
            await self._publish(job, {"type": "state"})
            await self.broadcast_queue()
            return
        if job.run:
            job.message = "Cancelling..."
            job.run.cancel()
            await self._publish(job, {"type": "status", "message": job.message})

    async def remove(self, job: Job) -> None:
        if job.active():
            await self.cancel(job)
            if job.run:
                await job.run.kill()
        self.jobs.pop(job.id, None)
        shutil.rmtree(job.directory, ignore_errors=True)
        await self.broadcast_queue()

    def _prune(self, session: str) -> None:
        """Keeps a session's newest jobs and drops the rest, audio and all."""
        finished = [j for j in self.jobs_for(session) if not j.active()]
        for job in finished[config.MAX_JOBS_PER_USER :]:
            self.jobs.pop(job.id, None)
            shutil.rmtree(job.directory, ignore_errors=True)

    # --- the event stream -------------------------------------------------

    def subscribe(self, job_id: str) -> asyncio.Queue:
        queue: asyncio.Queue = asyncio.Queue(maxsize=512)
        self._subscribers.setdefault(job_id, []).append(queue)
        return queue

    def unsubscribe(self, job_id: str, queue: asyncio.Queue) -> None:
        listeners = self._subscribers.get(job_id)
        if not listeners:
            return
        if queue in listeners:
            listeners.remove(queue)
        if not listeners:
            self._subscribers.pop(job_id, None)

    async def _publish(self, job: Job, payload: Dict[str, Any]) -> None:
        payload = dict(payload)
        payload["job"] = job.view()
        for queue in list(self._subscribers.get(job.id, [])):
            try:
                queue.put_nowait(payload)
            except asyncio.QueueFull:
                # A browser that has stopped reading must not hold the run up.
                pass

    async def broadcast_queue(self) -> None:
        """Tells every waiting job where it now stands.

        Without this a queued job would learn it had moved up only when it
        started, and the front end could not honestly say how long the wait is.
        """
        snapshot = self.capacity()
        for job_id in list(self._subscribers):
            job = self.jobs.get(job_id)
            if not job:
                continue
            payload = {"type": "queue", "queue": snapshot, "job": job.view()}
            for queue in list(self._subscribers.get(job_id, [])):
                try:
                    queue.put_nowait(payload)
                except asyncio.QueueFull:
                    pass

    # --- jobs that outlive a restart --------------------------------------

    def _write_record(self, job: Job) -> None:
        try:
            job.directory.mkdir(parents=True, exist_ok=True)
            job.record_path.write_text(
                json.dumps(
                    {
                        "id": job.id,
                        "session": job.session,
                        "filename": job.filename,
                        "created": job.created,
                        "state": job.state if job.state in TERMINAL else FAILED,
                        "message": job.message
                        if job.state in TERMINAL
                        else "interrupted by a restart of the server",
                        "duration": job.duration,
                        "elapsed": job.elapsed,
                        "settings": job.settings.to_dict(),
                    }
                ),
                encoding="utf-8",
            )
        except OSError:
            pass

    def load_jobs(self) -> None:
        """Reads back what finished before the last restart.

        A job that was still running is not resumed: its process is gone and
        the audio it had read is not recoverable. It comes back marked failed,
        which is the truth, and the user can start it again.
        """
        if not config.JOBS_DIR.is_dir():
            return
        for directory in sorted(config.JOBS_DIR.iterdir()):
            record = directory / "job.json"
            if not record.is_file():
                continue
            try:
                data = json.loads(record.read_text(encoding="utf-8"))
            except (OSError, json.JSONDecodeError):
                continue
            job = Job(
                id=str(data.get("id") or directory.name),
                session=str(data.get("session") or ""),
                filename=str(data.get("filename") or "audio"),
                directory=directory,
                settings=Settings.from_dict(data.get("settings") or {}),
                created=float(data.get("created") or 0.0),
            )
            job.state = str(data.get("state") or FAILED)
            job.message = str(data.get("message") or "")
            job.duration = float(data.get("duration") or 0.0)
            job.elapsed = float(data.get("elapsed") or 0.0)

            state_file = directory / "state.json"
            if state_file.is_file():
                try:
                    job.transcript = Transcript.from_store(
                        json.loads(state_file.read_text(encoding="utf-8"))
                    )
                    job.segment_count = len(job.transcript.segments)
                except (OSError, json.JSONDecodeError):
                    job.transcript = None
            self.jobs[job.id] = job


def _provisional_name(speaker: int, prefix: str) -> str:
    """The label shown while the run is going.

    The final grouping sees the whole file and may renumber everything, which
    is why these are replaced wholesale when the run ends.
    """
    return f"{prefix} {speaker + 1}" if speaker >= 0 else "Unknown"


def new_job(session: str, filename: str, settings: Settings) -> Job:
    job_id = uuid.uuid4().hex
    directory = config.JOBS_DIR / job_id
    (directory / "audio").mkdir(parents=True, exist_ok=True)
    return Job(
        id=job_id,
        session=session,
        filename=filename,
        directory=directory,
        settings=settings,
    )
