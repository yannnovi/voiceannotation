"""The annotated transcript, and the five export formats.

A port of src/core/transcript.{h,cpp}. The C++ core owns the transcript while
the audio is being read; once the run is over the web backend owns it, because
everything that happens next -- re-grouping the voices, renaming a speaker,
moving a passage -- touches no audio and needs no model loaded. Keeping that
work here is what lets a finished job stay interactive without holding a
gigabyte of Vosk model resident per user.

The rendering is a deliberate transliteration of the C++, down to the number
formatting, so a file exported from the web interface is byte-for-byte what
the native application would have written.
"""

from __future__ import annotations

import csv
import io
import math
from dataclasses import dataclass, field
from typing import Any, Dict, Iterable, List, Optional

UNKNOWN_SPEAKER = -1

FORMATS = ("txt", "srt", "vtt", "json", "csv")

_EXTENSIONS = {
    "txt": ".txt",
    "srt": ".srt",
    "vtt": ".vtt",
    "json": ".json",
    "csv": ".csv",
}

_MEDIA_TYPES = {
    "txt": "text/plain; charset=utf-8",
    "srt": "application/x-subrip; charset=utf-8",
    "vtt": "text/vtt; charset=utf-8",
    "json": "application/json; charset=utf-8",
    "csv": "text/csv; charset=utf-8",
}


def extension_for(fmt: str) -> str:
    return _EXTENSIONS.get(fmt, ".txt")


def media_type_for(fmt: str) -> str:
    return _MEDIA_TYPES.get(fmt, "text/plain; charset=utf-8")


def format_for_path(path: str) -> str:
    """Picks a format from a file extension, defaulting to txt."""
    dot = path.rfind(".")
    slash = max(path.rfind("/"), path.rfind("\\"))
    if dot < 0 or (slash >= 0 and dot < slash):
        return "txt"
    ext = path[dot + 1 :].lower()
    return ext if ext in ("srt", "vtt", "json", "csv") else "txt"


def number(value: float, decimals: int = 3) -> str:
    """va::Json::number: fixed decimals, no locale, no exponent.

    Reproduced rather than replaced by format() because of one detail: a value
    that rounds to zero from below loses its minus sign, so -0.0001 renders as
    "0.000" and not "-0.000".
    """
    if value is None or not math.isfinite(value):
        return "0"
    decimals = min(max(decimals, 0), 9)
    negative = value < 0
    if negative:
        value = -value
    scale = 10**decimals
    # round-half-away-from-zero, like llround; Python's round() goes to even.
    scaled = int(math.floor(value * scale + 0.5))
    whole, frac = divmod(scaled, scale)

    out = "-" if negative and scaled != 0 else ""
    out += str(whole)
    if decimals > 0:
        out += "." + str(frac).rjust(decimals, "0")
    return out


def timecode(seconds: float, subtitle_style: bool = False) -> str:
    """"01:02:03.450", or "01:02:03,450" in the SRT dialect."""
    if not seconds or seconds < 0:
        seconds = 0.0
    millis = int(math.floor(seconds * 1000.0 + 0.5))
    ms = millis % 1000
    total = millis // 1000
    s = total % 60
    m = (total // 60) % 60
    h = total // 3600
    separator = "," if subtitle_style else "."
    return f"{h:02d}:{m:02d}:{s:02d}{separator}{ms:03d}"


def human_duration(seconds: float) -> str:
    """Readable duration: "3 min 12 s" rather than "192.4"."""
    seconds = int(round(seconds or 0))
    if seconds < 60:
        return f"{seconds} s"
    minutes, rest = divmod(seconds, 60)
    if minutes < 60:
        return f"{minutes} min {rest} s"
    hours, minutes = divmod(minutes, 60)
    return f"{hours} h {minutes} min"


@dataclass
class Word:
    word: str = ""
    start: float = 0.0
    end: float = 0.0
    conf: float = 0.0


@dataclass
class Segment:
    start: float = 0.0
    end: float = 0.0
    text: str = ""
    words: List[Word] = field(default_factory=list)
    # Kept for re-clustering: this is what makes Regroup instant.
    speaker_vector: List[float] = field(default_factory=list)
    speaker_frames: int = 0
    speaker: int = UNKNOWN_SPEAKER

    @property
    def duration(self) -> float:
        return self.end - self.start if self.end > self.start else 0.0


class Transcript:
    def __init__(self) -> None:
        self.segments: List[Segment] = []
        self.names: Dict[int, str] = {}
        self.speaker_prefix = "Speaker"
        self.unknown_label = "Unknown"

        self.source_path = ""
        self.source_name = ""
        self.model_path = ""
        self.speaker_model_path = ""
        self.audio_duration = 0.0
        self.sample_rate = 0
        self.channels = 0

    # --- speakers --------------------------------------------------------

    def speaker_count(self) -> int:
        highest = -1
        for s in self.segments:
            highest = max(highest, s.speaker)
        return highest + 1

    def speaker_name(self, speaker: int) -> str:
        if speaker < 0:
            return self.unknown_label
        name = self.names.get(speaker)
        return name if name else f"{self.speaker_prefix} {speaker + 1}"

    def set_speaker_name(self, speaker: int, name: str) -> None:
        if speaker < 0:
            return
        if name:
            self.names[speaker] = name
        else:
            self.names.pop(speaker, None)

    def speaking_time(self) -> List[float]:
        totals = [0.0] * max(0, self.speaker_count())
        for s in self.segments:
            if 0 <= s.speaker < len(totals):
                totals[s.speaker] += s.duration
        return totals

    def segment_counts(self) -> List[int]:
        counts = [0] * max(0, self.speaker_count())
        for s in self.segments:
            if 0 <= s.speaker < len(counts):
                counts[s.speaker] += 1
        return counts

    def speakers(self) -> List[Dict[str, Any]]:
        times = self.speaking_time()
        counts = self.segment_counts()
        return [
            {
                "id": i,
                "name": self.speaker_name(i),
                "time": times[i],
                "segments": counts[i],
            }
            for i in range(len(times))
        ]

    def relabel(self, labels: Iterable[int]) -> None:
        """Applies fresh labels, one per segment.

        Custom names go: after re-clustering, speaker 2 is not necessarily the
        person speaker 2 was, and a name kept here would land on the wrong one.
        """
        for segment, label in zip(self.segments, labels):
            segment.speaker = label
        self.names.clear()

    def set_segment_speaker(self, index: int, speaker: int) -> bool:
        if index < 0 or index >= len(self.segments):
            return False
        # One past the end is allowed on purpose: it is how a wrongly merged
        # speaker gets split into a new one.
        if speaker < UNKNOWN_SPEAKER or speaker > self.speaker_count():
            return False
        self.segments[index].speaker = speaker
        return True

    # --- the shape the front end reads ------------------------------------

    def segment_views(self) -> List[Dict[str, Any]]:
        return [
            {
                "index": i,
                "start": s.start,
                "end": s.end,
                "duration": s.duration,
                "speaker": s.speaker,
                "name": self.speaker_name(s.speaker),
                "text": s.text,
            }
            for i, s in enumerate(self.segments)
        ]

    # --- export ----------------------------------------------------------

    def render(self, fmt: str) -> str:
        if fmt == "srt":
            return self._render_srt()
        if fmt == "vtt":
            return self._render_vtt()
        if fmt == "csv":
            return self._render_csv()
        if fmt == "json":
            return self._render_json()
        return self._render_text()

    def _render_text(self) -> str:
        out = io.StringIO()
        if self.source_path:
            out.write(f"# {self.source_path}\n\n")
        previous = -2
        for s in self.segments:
            # A new block only when the speaker changes, so a long turn reads
            # as a paragraph instead of a list of fragments.
            if s.speaker != previous:
                if previous != -2:
                    out.write("\n")
                out.write(f"[{timecode(s.start)}] {self.speaker_name(s.speaker)}:\n")
                previous = s.speaker
            out.write(f"  {s.text}\n")
        return out.getvalue()

    def _render_srt(self) -> str:
        out = io.StringIO()
        for index, s in enumerate(self.segments, start=1):
            out.write(f"{index}\n")
            out.write(f"{timecode(s.start, True)} --> {timecode(s.end, True)}\n")
            out.write(f"{self.speaker_name(s.speaker)}: {s.text}\n\n")
        return out.getvalue()

    def _render_vtt(self) -> str:
        out = io.StringIO()
        out.write("WEBVTT\n\n")
        for s in self.segments:
            out.write(f"{timecode(s.start)} --> {timecode(s.end)}\n")
            # <v> is how WebVTT names a speaker; players that understand it can
            # style each voice differently.
            out.write(f"<v {self.speaker_name(s.speaker)}>{s.text}\n\n")
        return out.getvalue()

    def _render_csv(self) -> str:
        buffer = io.StringIO(newline="")
        # The C++ writes bare \n and quotes only when it has to; QUOTE_MINIMAL
        # with \n as the terminator is the same rule.
        writer = csv.writer(buffer, lineterminator="\n", quoting=csv.QUOTE_MINIMAL)
        writer.writerow(["index", "start", "end", "duration", "speaker", "text"])
        for index, s in enumerate(self.segments, start=1):
            writer.writerow(
                [
                    index,
                    number(s.start),
                    number(s.end),
                    number(s.duration),
                    self.speaker_name(s.speaker),
                    s.text,
                ]
            )
        return buffer.getvalue()

    def _render_json(self) -> str:
        # Hand-written for the same reason the C++ is: the exact layout is part
        # of the output, and json.dumps would renumber the floats.
        out = io.StringIO()
        out.write("{\n")
        out.write(f'  "source": "{_escape(self.source_path)}",\n')
        out.write(f'  "model": "{_escape(self.model_path)}",\n')
        out.write(f'  "speaker_model": "{_escape(self.speaker_model_path)}",\n')
        out.write(f'  "duration": {number(self.audio_duration)},\n')
        out.write(f'  "sample_rate": {int(self.sample_rate)},\n')
        out.write(f'  "channels": {int(self.channels)},\n')

        totals = self.speaking_time()
        out.write('  "speakers": [\n')
        for i, total in enumerate(totals):
            out.write(
                f'    {{"id": {i}, "name": "{_escape(self.speaker_name(i))}"'
                f', "speaking_time": {number(total)}}}'
            )
            out.write(",\n" if i + 1 < len(totals) else "\n")
        out.write("  ],\n")

        out.write('  "segments": [\n')
        for i, s in enumerate(self.segments):
            out.write("    {\n")
            out.write(f'      "start": {number(s.start)},\n')
            out.write(f'      "end": {number(s.end)},\n')
            out.write(f'      "speaker": {s.speaker},\n')
            out.write(f'      "speaker_name": "{_escape(self.speaker_name(s.speaker))}",\n')
            out.write(f'      "text": "{_escape(s.text)}",\n')
            out.write('      "words": [')
            for w, word in enumerate(s.words):
                out.write(
                    f'\n        {{"word": "{_escape(word.word)}"'
                    f', "start": {number(word.start)}'
                    f', "end": {number(word.end)}'
                    f', "conf": {number(word.conf)}}}'
                )
                if w + 1 < len(s.words):
                    out.write(",")
            out.write("]\n" if not s.words else "\n      ]\n")
            out.write("    }")
            out.write(",\n" if i + 1 < len(self.segments) else "\n")
        out.write("  ]\n}\n")
        return out.getvalue()

    # --- persistence ------------------------------------------------------
    #
    # A job survives a restart of the server, so the transcript is stored as
    # plain JSON with the embeddings kept -- the same thing the command-line
    # binary writes with --embeddings, which is also what it is loaded from.

    def to_store(self) -> Dict[str, Any]:
        return {
            "source": self.source_path,
            "source_name": self.source_name,
            "model": self.model_path,
            "speaker_model": self.speaker_model_path,
            "duration": self.audio_duration,
            "sample_rate": self.sample_rate,
            "channels": self.channels,
            "speaker_prefix": self.speaker_prefix,
            "names": {str(k): v for k, v in self.names.items()},
            "segments": [
                {
                    "start": s.start,
                    "end": s.end,
                    "text": s.text,
                    "speaker": s.speaker,
                    "speaker_frames": s.speaker_frames,
                    "speaker_vector": s.speaker_vector,
                    "words": [
                        {"word": w.word, "start": w.start, "end": w.end, "conf": w.conf}
                        for w in s.words
                    ],
                }
                for s in self.segments
            ],
        }

    @classmethod
    def from_store(cls, data: Dict[str, Any]) -> "Transcript":
        t = cls.from_cli_json(data)
        t.source_name = data.get("source_name", "") or t.source_name
        t.speaker_prefix = data.get("speaker_prefix", "Speaker") or "Speaker"
        t.names = {int(k): v for k, v in (data.get("names") or {}).items()}
        return t

    @classmethod
    def from_cli_json(cls, data: Dict[str, Any]) -> "Transcript":
        """Reads what `voiceannotate-cli --format json --embeddings` wrote."""
        t = cls()
        t.source_path = data.get("source", "") or ""
        t.source_name = t.source_path.rsplit("/", 1)[-1]
        t.model_path = data.get("model", "") or ""
        t.speaker_model_path = data.get("speaker_model", "") or ""
        t.audio_duration = float(data.get("duration", 0.0) or 0.0)
        t.sample_rate = int(data.get("sample_rate", 0) or 0)
        t.channels = int(data.get("channels", 0) or 0)

        for raw in data.get("segments", []) or []:
            segment = Segment(
                start=float(raw.get("start", 0.0) or 0.0),
                end=float(raw.get("end", 0.0) or 0.0),
                text=raw.get("text", "") or "",
                speaker=int(raw.get("speaker", UNKNOWN_SPEAKER)),
                speaker_frames=int(raw.get("speaker_frames", 0) or 0),
                speaker_vector=[float(x) for x in (raw.get("speaker_vector") or [])],
                words=[
                    Word(
                        word=w.get("word", "") or "",
                        start=float(w.get("start", 0.0) or 0.0),
                        end=float(w.get("end", 0.0) or 0.0),
                        conf=float(w.get("conf", 0.0) or 0.0),
                    )
                    for w in (raw.get("words") or [])
                ],
            )
            t.segments.append(segment)
        return t


def _escape(s: Optional[str]) -> str:
    """va::Json::escape. UTF-8 passes through; only the controls are escaped."""
    if not s:
        return ""
    out = []
    for c in s:
        if c == '"':
            out.append('\\"')
        elif c == "\\":
            out.append("\\\\")
        elif c == "\n":
            out.append("\\n")
        elif c == "\r":
            out.append("\\r")
        elif c == "\t":
            out.append("\\t")
        elif c == "\b":
            out.append("\\b")
        elif c == "\f":
            out.append("\\f")
        elif ord(c) < 0x20:
            out.append(f"\\u{ord(c):04x}")
        else:
            out.append(c)
    return "".join(out)
