"""Checks the Python port against the C++ core it was ported from.

web/backend/transcript.py and web/backend/diarize.py restate two pieces of
src/ in another language. A restatement that quietly drifts is worse than no
restatement at all: a transcript exported from the browser would stop matching
one exported from the desktop application, and the Regroup slider would
behave differently at the same setting.

So both sides build the same fixture from the same generator and print the
same report, and the two are diffed. Run the C++ side with:

    tests/parity_harness.cpp   (compiled against src/core and src/stt)

and this file with:

    python3 web/tests/parity.py > python.txt

The numbers in the fixture are multiples of 1/1024 on purpose. A C++ embedding
is a vector of float; a Python one is a list of float, which is double. Feeding
both sides values that are exact in single and double precision alike means the
two start from identical inputs, and any difference in the report comes from
the algorithm rather than from the fixture.

The intermediate arithmetic still differs -- the C++ rounds each centroid back
to float after every merge and this does not -- so the labels are compared for
agreement, not for bit-equality. On this fixture they agree at every setting;
if a future change makes them disagree, that is worth looking at rather than
worth pinning.
"""

from __future__ import annotations

import sys
from pathlib import Path

# web/ on the path, so the imports read the way they do inside the container,
# where backend/ is what sits beside the frontend.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from backend.diarize import DiarizerConfig, cluster  # noqa: E402
from backend.transcript import Segment, Transcript, Word  # noqa: E402

MASK = (1 << 64) - 1
_state = 88172645463325252


def rnd(modulus: int) -> int:
    """The xorshift64 the C++ harness uses, to the bit."""
    global _state
    _state ^= (_state << 13) & MASK
    _state ^= _state >> 7
    _state ^= (_state << 17) & MASK
    return _state % modulus


def build() -> tuple[Transcript, list, list]:
    speakers, dim, count = 3, 16, 40
    bases = [[(rnd(2049) - 1024) / 1024.0 for _ in range(dim)] for _ in range(speakers)]

    t = Transcript()
    t.source_path = 'entretien "a".mp3'
    t.model_path = "models/m"
    t.speaker_model_path = "models/spk"
    t.audio_duration = 123.4567
    t.sample_rate = 44100
    t.channels = 2

    vectors: list = []
    frames: list = []
    for i in range(count):
        start = (i * 3137) / 1000.0
        segment = Segment(
            start=start,
            end=start + 1.0 + rnd(2000) / 1000.0,
            text='un "mot", et\tune virgule' if i % 7 == 0 else "bonjour et merci d'etre venu",
        )
        who = i % speakers
        segment.speaker_vector = [
            bases[who][d] + (rnd(513) - 256) / 1024.0 for d in range(dim)
        ]
        segment.speaker_frames = 12 if i % 9 == 0 else 40 + i
        segment.words = [
            Word("bonjour", start, start + 0.4, 0.87),
            Word("merci", start + 0.5, start + 0.9, 0.5),
        ]
        t.segments.append(segment)
        vectors.append(segment.speaker_vector)
        frames.append(segment.speaker_frames)
    return t, vectors, frames


def main() -> None:
    t, vectors, frames = build()

    out = sys.stdout
    for threshold in (-0.10, 0.0, 0.05, 0.20, 0.35):
        for min_frames in (5, 40, 100):
            for max_speakers in (0, 2, 4):
                labels = cluster(
                    vectors,
                    frames,
                    DiarizerConfig(
                        threshold=threshold,
                        min_frames=min_frames,
                        max_speakers=max_speakers,
                    ),
                )
                out.write(
                    f"LABELS {threshold:.2f} {min_frames} {max_speakers}:"
                    + "".join(f" {label}" for label in labels)
                    + "\n"
                )

    t.relabel(cluster(vectors, frames, DiarizerConfig()))
    t.set_speaker_name(0, 'Alice "la" Brune')
    t.set_segment_speaker(3, t.speaker_count())

    for name in ("txt", "srt", "vtt", "csv", "json"):
        out.write(f"===== {name} =====\n")
        out.write(t.render(name))
    out.write("===== end =====\n")


if __name__ == "__main__":
    main()
