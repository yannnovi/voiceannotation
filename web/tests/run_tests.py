"""Self-tests for the web backend.

No test framework, for the same reason the C++ side has none (see
tests/run_tests.cpp): the point of this project is that it builds and checks
itself with what is already there. Everything below runs on a bare Python 3.11
or newer, with nothing installed -- FastAPI is imported only by the one group
that needs it, and that group is skipped when it is absent.

    python3 web/tests/run_tests.py

The parity of the ports against the C++ core is checked separately, by
web/tests/parity.py against web/tests/parity_harness.cpp.
"""

from __future__ import annotations

import asyncio
import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

# Every path the backend writes to has to be a scratch one before config is
# imported: importing it is what fixes them.
_SCRATCH = tempfile.mkdtemp(prefix="voiceannotate-tests-")
os.environ.setdefault("VA_DATA_DIR", _SCRATCH)
os.environ.setdefault("VA_MODELS_DIR", str(Path(_SCRATCH) / "models"))

from backend import config  # noqa: E402
from backend import jobs as jobs_module  # noqa: E402
from backend.diarize import DiarizerConfig, cluster, similarity  # noqa: E402
from backend.transcript import (  # noqa: E402
    Segment,
    Transcript,
    Word,
    format_for_path,
    human_duration,
    number,
    timecode,
)

_checks = 0
_failures = 0


def group(name: str) -> None:
    print(f"\n{name}")


def ok(condition: bool, what: str) -> None:
    global _checks, _failures
    _checks += 1
    if condition:
        print(f"  ok    {what}")
    else:
        _failures += 1
        print(f"  FAIL  {what}")


def equals(actual, expected, what: str) -> None:
    global _checks, _failures
    _checks += 1
    if actual == expected:
        print(f"  ok    {what}")
    else:
        _failures += 1
        print(f"  FAIL  {what}\n        expected [{expected!r}]\n        actual   [{actual!r}]")


# ---------------------------------------------------------------------------
# Formatting
# ---------------------------------------------------------------------------


def test_numbers() -> None:
    group("number formatting")
    equals(number(0.0), "0.000", "zero")
    equals(number(1.5), "1.500", "one and a half")
    equals(number(-2.25), "-2.250", "negative")
    # The detail the hand-written port exists for: a value that rounds to zero
    # from below must not come back as "-0.000".
    equals(number(-0.0001), "0.000", "a negative that rounds to zero loses its sign")
    equals(number(0.0005), "0.001", "half rounds away from zero, as llround does")
    equals(number(2.5, 0), "3", "no decimals")
    equals(number(float("inf")), "0", "infinity is not a number to write out")

    group("timecodes")
    equals(timecode(0), "00:00:00.000", "zero")
    equals(timecode(3723.45), "01:02:03.450", "an hour, two minutes, three seconds")
    equals(timecode(3723.45, True), "01:02:03,450", "the SRT dialect uses a comma")
    equals(timecode(-5), "00:00:00.000", "a negative time is clamped")

    group("durations and extensions")
    equals(human_duration(42), "42 s", "seconds")
    equals(human_duration(192), "3 min 12 s", "minutes")
    equals(human_duration(7300), "2 h 1 min", "hours")
    equals(format_for_path("a/b.SRT"), "srt", "the extension decides, whatever its case")
    equals(format_for_path("a.b/c"), "txt", "a dot in a directory is not an extension")
    equals(format_for_path("notes"), "txt", "no extension at all")


# ---------------------------------------------------------------------------
# The transcript
# ---------------------------------------------------------------------------


def sample_transcript() -> Transcript:
    t = Transcript()
    t.source_path = "entretien.mp3"
    t.audio_duration = 12.0
    for index, (start, end, speaker, text) in enumerate(
        [
            (0.0, 2.0, 0, "bonjour"),
            (2.0, 4.5, 0, "merci d'etre venu"),
            (4.5, 7.0, 1, "merci a vous"),
            (7.0, 9.0, 0, "commencons"),
        ]
    ):
        t.segments.append(
            Segment(
                start=start,
                end=end,
                text=text,
                speaker=speaker,
                speaker_frames=50 + index,
                speaker_vector=[1.0 if speaker == 0 else -1.0, 0.5],
                words=[Word(text.split()[0], start, start + 0.3, 0.9)],
            )
        )
    return t


def test_transcript() -> None:
    group("speakers")
    t = sample_transcript()
    equals(t.speaker_count(), 2, "two speakers")
    equals(t.speaker_name(0), "Speaker 1", "the default name is one-based")
    equals(t.speaker_name(-1), "Unknown", "an untagged passage")
    t.set_speaker_name(0, "Alice")
    equals(t.speaker_name(0), "Alice", "a custom name")
    t.set_speaker_name(0, "")
    equals(t.speaker_name(0), "Speaker 1", "clearing a name restores the default")

    t.speaker_prefix = "Locuteur"
    equals(t.speaker_name(1), "Locuteur 2", "the prefix comes from the interface")
    t.speaker_prefix = "Speaker"

    equals([round(x, 2) for x in t.speaking_time()], [6.5, 2.5], "speech per speaker")
    equals(t.segment_counts(), [3, 1], "passages per speaker")

    group("reassignment")
    ok(t.set_segment_speaker(2, 0), "a passage can be moved to an existing speaker")
    equals(t.speaker_count(), 1, "the speaker it left is now empty")
    ok(t.set_segment_speaker(2, 1), "one past the end opens a new speaker")
    equals(t.speaker_count(), 2, "and the count follows")
    ok(not t.set_segment_speaker(2, 9), "a speaker far past the end is refused")
    ok(not t.set_segment_speaker(99, 0), "an unknown passage is refused")
    ok(t.set_segment_speaker(2, -1), "a passage may be marked unknown")
    t.set_segment_speaker(2, 1)

    group("relabelling")
    t.set_speaker_name(0, "Alice")
    t.relabel([1, 1, 0, 1])
    equals(t.names, {}, "custom names go: cluster 2 is no longer the same person")
    equals([s.speaker for s in t.segments], [1, 1, 0, 1], "labels applied")


def test_exports() -> None:
    group("exports")
    t = sample_transcript()
    t.set_speaker_name(0, "Alice")

    text = t.render("txt")
    ok(text.startswith("# entretien.mp3\n\n"), "the text export names its source")
    ok("[00:00:00.000] Alice:\n  bonjour\n" in text, "a turn opens with its timecode")
    # Consecutive passages by one speaker share a block, and a change starts a
    # new one -- that is what makes the file read as prose.
    equals(text.count("Alice:"), 2, "Alice speaks in two separate turns")
    equals(text.count("Speaker 2:"), 1, "and the other speaker in one")

    srt = t.render("srt")
    ok(srt.startswith("1\n00:00:00,000 --> 00:00:02,000\nAlice: bonjour\n\n"), "SRT")
    vtt = t.render("vtt")
    ok(vtt.startswith("WEBVTT\n\n"), "WebVTT announces itself")
    ok("<v Alice>bonjour" in vtt, "WebVTT names the voice with a cue tag")

    group("CSV quoting")
    t.segments[0].text = 'il a dit "bonjour", puis'
    csv = t.render("csv")
    ok(csv.startswith("index,start,end,duration,speaker,text\n"), "the header")
    ok('"il a dit ""bonjour"", puis"' in csv, "a comma and a quote are escaped")
    ok("1,0.000,2.000,2.000," in csv, "times are written to the millisecond")

    group("JSON round trip")
    t.segments[0].text = 'un "guillemet" et\tune tabulation'
    import json as json_module

    parsed = json_module.loads(t.render("json"))
    equals(parsed["source"], "entretien.mp3", "the source survives")
    equals(len(parsed["segments"]), 4, "every passage is there")
    equals(parsed["segments"][0]["speaker_name"], "Alice", "names are resolved in the export")
    equals(parsed["segments"][0]["text"], 'un "guillemet" et\tune tabulation', "escaping")
    equals(len(parsed["speakers"]), 2, "the speaker table")

    group("store round trip")
    stored = Transcript.from_store(t.to_store())
    equals(stored.render("txt"), t.render("txt"), "a saved transcript reloads unchanged")
    equals(
        stored.segments[0].speaker_vector,
        t.segments[0].speaker_vector,
        "the embeddings survive, or Regroup would stop working after a restart",
    )


# ---------------------------------------------------------------------------
# Clustering
# ---------------------------------------------------------------------------


def test_diarizer() -> None:
    group("similarity")
    equals(round(similarity([1.0, 0.0], [1.0, 0.0]), 6), 1.0, "a vector with itself")
    equals(round(similarity([1.0, 0.0], [-1.0, 0.0]), 6), -1.0, "and with its opposite")
    equals(similarity([], [1.0]), 0.0, "an empty vector is not similar to anything")
    equals(similarity([0.0, 0.0], [1.0, 0.0]), 0.0, "nor is a degenerate one")

    group("clustering")
    # Two tight groups, far apart.
    vectors = [[1.0, 0.1], [0.98, 0.12], [-1.0, 0.1], [-0.97, 0.08]]
    frames = [100, 100, 100, 100]
    labels = cluster(vectors, frames, DiarizerConfig())
    equals(len(set(labels)), 2, "two voices are found")
    equals(labels[0], labels[1], "the first two are the same person")
    equals(labels[2], labels[3], "and so are the last two")
    equals(labels[0], 0, "speaker 0 is whoever speaks first")

    labels = cluster(vectors, frames, DiarizerConfig(max_speakers=1))
    equals(len(set(labels)), 1, "a cap of one forces them together")

    # Raising the sensitivity splits voices apart and never merges them: that
    # is the promise the slider's label makes, and the one property of the
    # setting that has to hold whatever the recording is.
    counts = [
        len(set(cluster(vectors, frames, DiarizerConfig(threshold=t))))
        for t in (-0.2, -0.1, 0.0, 0.05, 0.2, 0.4, 0.8)
    ]
    ok(counts == sorted(counts), f"the count never falls as the threshold rises {counts}")
    equals(
        len(set(cluster(vectors, frames, DiarizerConfig(threshold=0.99999)))),
        4,
        "far enough right, every passage becomes its own voice",
    )

    # Centring is what makes one threshold work across recordings: the shared
    # component a microphone and a room put into every embedding is removed
    # before the voices are compared. Without it the same passages sit much
    # closer together, and the same setting groups them differently.
    plain = DiarizerConfig(threshold=0.05, center_on_recording_mean=False)
    ok(
        similarity(vectors[0], vectors[1]) > similarity(vectors[0], vectors[2]),
        "one voice is closer to itself than to another, centred or not",
    )
    equals(len(set(cluster(vectors, frames, plain))), 2, "uncentred, the two voices still part")

    group("clustering, edge cases")
    equals(cluster([], [], DiarizerConfig()), [], "nothing at all")
    equals(
        cluster([[], []], [0, 0], DiarizerConfig()),
        [-1, -1],
        "passages with no embedding stay unknown",
    )
    # A segment below min_frames may be labelled but never opens a speaker of
    # its own, however far it sits from everything else.
    #
    # Centring is off here on purpose. It is measured against the spread of a
    # whole recording, and three nearly identical vectors have no spread to
    # speak of, so what is left after the mean comes out is noise -- which is
    # not what this check is about.
    labels = cluster(
        [[1.0, 0.1], [0.96, 0.2], [0.9, 0.3], [-1.0, 0.0]],
        [100, 100, 100, 1],
        DiarizerConfig(min_frames=40, center_on_recording_mean=False),
    )
    equals(len(set(labels)), 1, "a fragment joins the nearest voice rather than making one")
    equals(labels[3], labels[0], "and it is the nearest one it joins")
    # And when nothing clears the bar, the fragments are clustered anyway
    # rather than the whole thing coming back unknown.
    labels = cluster([[1.0, 0.0], [-1.0, 0.0]], [1, 1], DiarizerConfig(min_frames=40))
    ok(all(label >= 0 for label in labels), "all-short input is still grouped")


# ---------------------------------------------------------------------------
# The two limits
# ---------------------------------------------------------------------------


class FakeRun:
    """Stands in for the CLI process, so the limits can be tested in a second.

    It reports one passage and finishes, or waits to be cancelled. What it
    does not do is load a model, which is the whole reason the real thing is
    slow enough to need a queue.
    """

    started = 0
    peak = 0
    live = 0

    def __init__(self, request, hold: asyncio.Event) -> None:
        self.request = request
        self.hold = hold
        self.cancelled = False

    async def events(self):
        FakeRun.started += 1
        FakeRun.live += 1
        FakeRun.peak = max(FakeRun.peak, FakeRun.live)
        try:
            yield {"event": "status", "message": "Loading models..."}
            await self.hold.wait()
            yield {
                "event": "segment",
                "index": 0,
                "start": 0.0,
                "end": 1.0,
                "speaker": 0,
                "text": "bonjour",
            }
            yield {
                "event": "finished",
                "cancelled": self.cancelled,
                "relabelled": False,
                "duration": 1.0,
                "elapsed": 0.1,
                "segments": 1,
            }
            # What the real run leaves behind for the store to read back.
            self.request.output.write_text(
                '{"source": "a.wav", "duration": 1.0, "segments": ['
                '{"start": 0.0, "end": 1.0, "speaker": 0, "text": "bonjour",'
                ' "speaker_frames": 50, "speaker_vector": [1.0, 0.0], "words": []}]}',
                encoding="utf-8",
            )
        finally:
            FakeRun.live -= 1

    def cancel(self) -> None:
        self.cancelled = True
        self.hold.set()

    async def kill(self) -> None:
        self.hold.set()


def test_limits() -> None:
    group("the two limits")

    async def scenario() -> None:
        from backend import catalogue as catalogue_module
        from backend import engine as engine_module

        hold = asyncio.Event()
        original_run = engine_module.Run
        original_resolve = catalogue_module.resolve_model
        # A model directory is not on this machine; the limits do not care.
        catalogue_module.resolve_model = lambda value, kind: "/models/fake"
        engine_module.Run = lambda request: FakeRun(request, hold)
        try:
            store = jobs_module.JobStore()
            # Four at once for the whole backend, whoever asks.
            store._slots = asyncio.Semaphore(4)

            submitted = []
            for index in range(9):
                # A different session each time, so the per-user rule is not
                # what is being measured here.
                job = jobs_module.new_job(f"session{index}", "a.wav", jobs_module.Settings())
                await store.submit(job)
                submitted.append(job)

            await asyncio.sleep(0.1)
            equals(len(store.running), 4, "four run at once")
            equals(len(store.queue), 5, "the other five wait")
            equals(store.capacity()["capacity"], config.MAX_CONCURRENT, "the limit is reported")
            positions = sorted(j.queue_position for j in submitted if j.state == "queued")
            equals(positions, [1, 2, 3, 4, 5], "a waiting job knows its place in the queue")

            hold.set()
            for _ in range(200):
                if all(not job.active() for job in submitted):
                    break
                await asyncio.sleep(0.02)
            equals([j.state for j in submitted].count("done"), 9, "all nine finish")
            equals(FakeRun.peak, 4, "never more than four ran at the same moment")
            ok(store.jobs[submitted[0].id].transcript is not None, "the transcript is kept")

            # And one at a time per user, whatever the backend still has free.
            hold.clear()
            FakeRun.peak = 0
            first = jobs_module.new_job("solo", "a.wav", jobs_module.Settings())
            await store.submit(first)
            await asyncio.sleep(0.05)
            second = jobs_module.new_job("solo", "b.wav", jobs_module.Settings())
            refused = False
            try:
                await store.submit(second)
            except PermissionError:
                refused = True
            ok(refused, "a second file from the same user is refused")
            equals(len(store.active_for("solo")), 1, "that user still has exactly one job")

            # Someone else is unaffected: the backend has slots free.
            other = jobs_module.new_job("other", "c.wav", jobs_module.Settings())
            await store.submit(other)
            await asyncio.sleep(0.05)
            equals(other.state, "running", "another user starts straight away")

            # Cancelling a queued job takes it out of the queue without ever
            # having spent a slot on it.
            hold.clear()
            store._slots = asyncio.Semaphore(1)
            blocker = jobs_module.new_job("q1", "a.wav", jobs_module.Settings())
            waiter = jobs_module.new_job("q2", "b.wav", jobs_module.Settings())
            await store.submit(blocker)
            await asyncio.sleep(0.05)
            await store.submit(waiter)
            await asyncio.sleep(0.05)
            equals(waiter.state, "queued", "the second waits behind the first")
            await store.cancel(waiter)
            equals(waiter.state, "cancelled", "and can be cancelled while it waits")
            ok(waiter.id not in store.queue, "it leaves the queue")
            hold.set()
            await asyncio.sleep(0.1)
        finally:
            engine_module.Run = original_run
            catalogue_module.resolve_model = original_resolve

    asyncio.run(scenario())


def test_settings() -> None:
    group("settings")
    s = jobs_module.Settings.from_dict({"threshold": 99, "minframes": -4, "maxspeakers": 999})
    equals(s.threshold, 0.6, "the sensitivity is clamped to the slider's range")
    equals(s.minframes, 1, "a minimum length below one is raised")
    equals(s.maxspeakers, 20, "the speaker cap is clamped")
    s = jobs_module.Settings.from_dict({"threshold": "not a number", "speaker_prefix": "  "})
    equals(s.threshold, 0.05, "nonsense falls back to the default")
    equals(s.speaker_prefix, "Speaker", "and so does an empty label")
    equals(
        jobs_module.Settings.from_dict({"speaker_prefix": "Locuteur"}).speaker_prefix,
        "Locuteur",
        "a real label is kept",
    )


def test_http() -> None:
    group("the HTTP surface")
    try:
        from fastapi.testclient import TestClient
    except ImportError:
        print("  skipped (fastapi is not installed)")
        return

    from backend.main import app, safe_filename
    from fastapi import HTTPException

    def refuses(name: str) -> bool:
        try:
            safe_filename(name)
            return False
        except HTTPException:
            return True

    ok(refuses("song.m4a"), "a format the engine cannot read is refused")
    ok(refuses("notes.txt"), "and so is anything that is not audio")
    equals(safe_filename("../../etc/passwd.wav"), "passwd.wav", "a path is reduced to its leaf")
    equals(safe_filename("entretien.MP3"), "entretien.mp3", "the extension is normalised")
    ok(safe_filename("réunion équipe.wav").endswith(".wav"), "accents are kept")

    with TestClient(app) as client:
        response = client.get("/api/state")
        equals(response.status_code, 200, "the state is served")
        body = response.json()
        ok("va_session" in response.cookies or "va_session" in client.cookies,
           "a session cookie is handed out")
        equals(body["queue"]["capacity"], config.MAX_CONCURRENT, "the capacity is published")
        equals(body["queue"]["per_user"], config.MAX_PER_USER, "and so is the per-user limit")

        equals(client.get("/healthz").status_code, 200, "the health check answers")

        settings = client.put("/api/settings", json={"threshold": 0.2, "minframes": 60}).json()
        equals(settings["threshold"], 0.2, "a setting is stored")
        equals(client.get("/api/state").json()["settings"]["minframes"], 60, "and read back")

        equals(client.get("/api/jobs/nope").status_code, 404, "an unknown job is not found")
        # Somebody else's job is not found either, rather than forbidden:
        # whose it is is not something to confirm to a stranger.
        equals(
            client.post("/api/jobs/nope/cancel").status_code, 404, "nor can it be cancelled"
        )

        page = client.get("/")
        equals(page.status_code, 200, "the page itself is served")
        ok("voiceannotate" in page.text, "and it is the right one")


def main() -> int:
    test_numbers()
    test_transcript()
    test_exports()
    test_diarizer()
    test_settings()
    test_limits()
    test_http()

    print(f"\n{_checks} checks, {_failures} failure(s)")
    return 1 if _failures else 0


if __name__ == "__main__":
    sys.exit(main())
