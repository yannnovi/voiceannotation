"""Grouping utterances by speaker, from the stored x-vectors.

A port of `va::Diarizer::cluster` in src/stt/diarizer.cpp -- the offline,
agglomerative pass, which is the one the Regroup button runs. The online
`assign` is ported too, because the offline pass falls back to it above a
few thousand embeddings.

Nothing here touches audio: it works from the 128-number embeddings the
recognition run already produced and the transcript kept. That is what makes
re-grouping instant on a file of several hours, exactly as in the native
application.

Written against the standard library alone, no numpy. At the sizes involved --
a matrix is capped at 3000 x 3000 -- the cost is in the agglomeration loop
rather than the arithmetic, and the dependency would buy little.
"""

from __future__ import annotations

import math
from dataclasses import dataclass
from typing import List, Sequence

UNKNOWN_SPEAKER = -1

# Above this many embeddings the similarity matrix stops being worth its
# memory (n^2 floats), and clustering falls back to the online strategy. At
# roughly one utterance every few seconds this is several hours of audio.
MAX_MATRIX_ITEMS = 3000


@dataclass
class DiarizerConfig:
    # Cosine similarity above which two embeddings are called the same person.
    # Raising it splits speakers apart, lowering it merges them. The default is
    # low because similarities are measured after the recording's mean has been
    # removed, which spreads the scores around zero instead of near one.
    threshold: float = 0.05
    # Embeddings from very little audio are noisy. Below this many frames (one
    # frame is 10 ms) a segment is labelled by nearest match but never allowed
    # to create or move a cluster.
    min_frames: int = 40
    # 0 means "as many as the audio suggests".
    max_speakers: int = 0
    # Subtract the recording's own mean embedding before comparing voices: it
    # carries the microphone and the room, not who is speaking, and leaving it
    # in squeezes every real difference into a narrow band near the top of the
    # range.
    center_on_recording_mean: bool = True

    @classmethod
    def from_request(cls, data: dict) -> "DiarizerConfig":
        return cls(
            threshold=_clamp(float(data.get("threshold", 0.05)), -1.0, 1.0),
            min_frames=max(0, int(data.get("minframes", 40))),
            max_speakers=max(0, min(int(data.get("maxspeakers", 0)), 100)),
        )


def _clamp(value: float, low: float, high: float) -> float:
    return max(low, min(high, value))


def _normalized(v: Sequence[float]) -> List[float]:
    norm = math.sqrt(sum(float(x) * float(x) for x in v))
    if norm < 1e-12:
        return [0.0] * len(v)
    return [float(x) / norm for x in v]


def _dot(a: Sequence[float], b: Sequence[float]) -> float:
    return sum(float(x) * float(y) for x, y in zip(a, b))


def similarity(a: Sequence[float], b: Sequence[float]) -> float:
    """Cosine similarity; 0 if either vector is empty or degenerate."""
    if not a or not b:
        return 0.0
    na = math.sqrt(_dot(a, a))
    nb = math.sqrt(_dot(b, b))
    if na < 1e-12 or nb < 1e-12:
        return 0.0
    return _dot(a, b) / (na * nb)


def _renumber_by_first_appearance(labels: List[int]) -> None:
    """Speaker 0 becomes whoever speaks first.

    Without this the numbering follows clustering order, which means nothing to
    a reader going down the transcript.
    """
    mapping: dict = {}
    for i, label in enumerate(labels):
        if label == UNKNOWN_SPEAKER:
            continue
        if label not in mapping:
            mapping[label] = len(mapping)
        labels[i] = mapping[label]


class OnlineDiarizer:
    """Greedy, one utterance at a time -- the fallback for very long files."""

    def __init__(self, config: DiarizerConfig) -> None:
        self.config = config
        self.centroids: List[List[float]] = []
        self.weights: List[float] = []

    def assign(self, vector: Sequence[float], frames: int) -> int:
        if not vector:
            return UNKNOWN_SPEAKER
        unit = _normalized(vector)

        best = -1
        best_sim = -2.0
        for i, centroid in enumerate(self.centroids):
            sim = _dot(unit, centroid)
            if sim > best_sim:
                best_sim = sim
                best = i

        reliable = frames >= self.config.min_frames
        at_capacity = (
            self.config.max_speakers > 0
            and len(self.centroids) >= self.config.max_speakers
        )

        # A short, noisy embedding gets the nearest label but is not allowed to
        # open a new speaker or drag an existing centroid around.
        if best >= 0 and (best_sim >= self.config.threshold or not reliable or at_capacity):
            if reliable:
                w = float(frames)
                total = self.weights[best] + w
                c = self.centroids[best]
                merged = [
                    (c[k] * self.weights[best] + unit[k] * w) / total
                    for k in range(min(len(c), len(unit)))
                ]
                self.centroids[best] = _normalized(merged)
                self.weights[best] = total
            return best

        if not reliable:
            return best if best >= 0 else UNKNOWN_SPEAKER

        self.centroids.append(unit)
        self.weights.append(float(frames))
        return len(self.centroids) - 1


def cluster(
    vectors: Sequence[Sequence[float]],
    frames: Sequence[int],
    config: DiarizerConfig,
) -> List[int]:
    """Offline clustering over every embedding at once.

    `vectors[i]` may be empty, in which case result[i] is UNKNOWN_SPEAKER.
    """
    labels = [UNKNOWN_SPEAKER] * len(vectors)

    # Only embeddings backed by enough audio drive the clustering; the rest are
    # attached afterwards to whichever cluster they land nearest.
    strong: List[int] = []
    weak: List[int] = []
    for i, vector in enumerate(vectors):
        if not vector:
            continue
        f = frames[i] if i < len(frames) else 0
        (strong if f >= config.min_frames else weak).append(i)

    # If nothing clears the bar, cluster on what there is rather than give up.
    if not strong:
        strong, weak = weak, []
    if not strong:
        return labels

    n = len(strong)

    if n > MAX_MATRIX_ITEMS:
        online = OnlineDiarizer(config)
        for i, vector in enumerate(vectors):
            if not vector:
                continue
            labels[i] = online.assign(vector, frames[i] if i < len(frames) else 0)
        _renumber_by_first_appearance(labels)
        return labels

    centroids = [_normalized(vectors[src]) for src in strong]
    weights = [
        float(frames[src]) if src < len(frames) and frames[src] > 0 else 1.0
        for src in strong
    ]

    # See DiarizerConfig.center_on_recording_mean. Computed over the strong
    # embeddings only, so a handful of noisy fragments cannot skew it, and kept
    # so the weak ones can be centred by the same offset below.
    mean: List[float] = []
    if config.center_on_recording_mean and n > 1:
        width = len(centroids[0])
        mean = [0.0] * width
        for v in centroids:
            for k in range(min(width, len(v))):
                mean[k] += v[k]
        mean = [m / n for m in mean]
        shifted = []
        for v in centroids:
            limit = min(len(v), len(mean))
            shifted.append(_normalized([v[k] - mean[k] for k in range(limit)]))
        centroids = shifted

    active = [True] * n
    assignment = list(range(n))

    sim = [[-1.0] * n for _ in range(n)]
    for i in range(n):
        for j in range(i + 1, n):
            s = _dot(centroids[i], centroids[j])
            sim[i][j] = s
            sim[j][i] = s

    remaining = n
    while remaining > 1:
        # The closest surviving pair.
        best_sim = -2.0
        best_a = 0
        best_b = 0
        for i in range(n):
            if not active[i]:
                continue
            row = sim[i]
            for j in range(i + 1, n):
                if not active[j]:
                    continue
                if row[j] > best_sim:
                    best_sim = row[j]
                    best_a = i
                    best_b = j
        if best_sim <= -2.0:
            break

        over_capacity = config.max_speakers > 0 and remaining > config.max_speakers
        # Stop at the threshold, unless a speaker cap still has to be met.
        if best_sim < config.threshold and not over_capacity:
            break

        wa = weights[best_a]
        wb = weights[best_b]
        total = wa + wb
        ca = centroids[best_a]
        cb = centroids[best_b]
        limit = min(len(ca), len(cb))
        merged = list(ca)
        for k in range(limit):
            merged[k] = (ca[k] * wa + cb[k] * wb) / total
        centroids[best_a] = _normalized(merged)
        weights[best_a] = total
        active[best_b] = False
        remaining -= 1

        for i in range(n):
            if not active[i] or i == best_a:
                continue
            s = _dot(centroids[best_a], centroids[i])
            sim[best_a][i] = s
            sim[i][best_a] = s
        for i in range(n):
            if assignment[i] == best_b:
                assignment[i] = best_a

    for i in range(n):
        labels[strong[i]] = assignment[i]

    # Attach the short segments to the nearest final centroid. They are centred
    # by the same mean, or the comparison would be against centroids living in
    # a different space.
    for idx in weak:
        if labels[idx] != UNKNOWN_SPEAKER:
            continue
        unit = _normalized(vectors[idx])
        if mean:
            limit = min(len(unit), len(mean))
            unit = _normalized([unit[k] - mean[k] for k in range(limit)])
        best_sim = -2.0
        best = UNKNOWN_SPEAKER
        for i in range(n):
            if not active[i]:
                continue
            s = _dot(unit, centroids[i])
            if s > best_sim:
                best_sim = s
                best = i
        labels[idx] = best

    _renumber_by_first_appearance(labels)
    return labels
