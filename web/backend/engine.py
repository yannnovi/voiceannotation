"""Driving voiceannotate-cli, one transcription per process.

The native application keeps the Vosk model loaded in its own process and
polls a queue the worker thread fills. Here the worker is a separate process:
it is started with --progress-json, reports the same events one JSON object
per line on its standard error, and exits when the file is done. Its memory --
a full model is one to two gigabytes -- goes with it.

That is the right shape for a service rather than a desktop program. Nothing
after the run needs a model: re-grouping the voices works from the embeddings
the run stored, which is why --embeddings is always passed.
"""

from __future__ import annotations

import asyncio
import json
import os
import signal
from dataclasses import dataclass
from pathlib import Path
from typing import AsyncIterator, Dict, List, Optional

from . import config


@dataclass
class RunRequest:
    audio: Path
    output: Path
    model: str
    speaker_model: str
    threshold: float
    min_frames: int
    max_speakers: int
    speaker_prefix: str


class Run:
    """A single CLI process, with a way to ask it to stop."""

    def __init__(self, request: RunRequest) -> None:
        self.request = request
        self.process: Optional[asyncio.subprocess.Process] = None
        self.stderr_tail: List[str] = []
        self.cancelled = False

    def command(self) -> List[str]:
        r = self.request
        command = [
            str(config.CLI_BINARY),
            "--model", r.model,
            "--format", "json",
            "--embeddings",
            "--progress-json",
            "--output", str(r.output),
            # Formatted rather than repr()'d: a very small value would come out
            # as 1e-05, which the C++ side's atof would read as 1.
            "--threshold", f"{r.threshold:.6f}",
            "--min-frames", str(r.min_frames),
            "--max-speakers", str(r.max_speakers),
            "--speaker-prefix", r.speaker_prefix,
        ]
        if r.speaker_model:
            command += ["--spk-model", r.speaker_model]
        command.append(str(r.audio))
        return command

    async def events(self) -> AsyncIterator[Dict]:
        """Yields the run's events until the process exits.

        A line that is not the JSON we asked for is Vosk's own chatter on the
        way through, and is kept only for a failure message.
        """
        if not config.CLI_BINARY.exists():
            yield {
                "event": "failed",
                "message": f"the transcription engine is missing: {config.CLI_BINARY}",
            }
            return

        environment = dict(os.environ)
        self.process = await asyncio.create_subprocess_exec(
            *self.command(),
            stdout=asyncio.subprocess.DEVNULL,
            stderr=asyncio.subprocess.PIPE,
            env=environment,
            # Its own process group, so cancelling signals the child alone and
            # never the server that started it.
            start_new_session=True,
        )

        assert self.process.stderr is not None
        saw_terminal_event = False
        while True:
            raw = await self.process.stderr.readline()
            if not raw:
                break
            line = raw.decode("utf-8", "replace").strip()
            if not line:
                continue
            if not (line.startswith("{") and line.endswith("}")):
                self.stderr_tail.append(line)
                del self.stderr_tail[:-20]
                continue
            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                self.stderr_tail.append(line)
                del self.stderr_tail[:-20]
                continue
            if event.get("event") in ("finished", "failed"):
                saw_terminal_event = True
            yield event

        code = await self.process.wait()
        if code != 0 and not saw_terminal_event:
            # Killed, or fell over before it could say anything: the tail of
            # what it printed is the only account of why.
            detail = "; ".join(self.stderr_tail[-3:]) or f"exit status {code}"
            yield {"event": "failed", "message": detail}

    def cancel(self) -> None:
        """Asks the run to stop at the next chunk, keeping what it has.

        SIGTERM rather than SIGKILL: the CLI catches it, cancels its pipeline
        and still writes out the passages recognised so far, which is the
        bargain the native application's Cancel button offers.
        """
        self.cancelled = True
        if self.process and self.process.returncode is None:
            try:
                self.process.send_signal(signal.SIGTERM)
            except ProcessLookupError:
                pass

    async def kill(self) -> None:
        if self.process and self.process.returncode is None:
            try:
                self.process.kill()
            except ProcessLookupError:
                pass
            await self.process.wait()
