// Groups utterances by speaker from Vosk x-vectors.
//
// The speaker model turns each utterance into a 128-dimensional embedding.
// Embeddings of the same person sit close together under cosine similarity;
// different people sit far apart. Nobody tells us how many speakers there are,
// so the number of clusters has to fall out of a similarity threshold rather
// than being fixed up front.
//
// Two strategies live here, and they serve different moments:
//
//   assign()  - greedy, online, one utterance at a time. Used while the file
//               is still being transcribed so the UI can show labels as they
//               arrive. It can only see the past, so it sometimes splits one
//               speaker in two.
//   cluster() - agglomerative, over every embedding at once. Run when the file
//               finishes, and again whenever the user moves the threshold.
//               Because it re-labels from stored embeddings it costs no audio
//               work at all, which is what makes the slider feel instant.
#ifndef VA_STT_DIARIZER_H
#define VA_STT_DIARIZER_H

#include <cstddef>
#include <string>
#include <vector>

namespace va {

struct DiarizerConfig {
    // Cosine similarity above which two embeddings are called the same person.
    // Raising it splits speakers apart, lowering it merges them.
    //
    // The default is low because similarities are measured after the
    // recording's mean has been removed (see centerOnRecordingMean), which
    // spreads the scores out around zero instead of bunching them near one.
    // Measured on two recordings at opposite ends of the difficulty range -- a
    // clean two-voice interview and a four-voice podcast on a single mic --
    // anything from about -0.10 to 0.10 recovers the right speaker count on
    // both, and the count starts inflating above 0.15.
    double threshold = 0.05;

    // Embeddings computed from very little audio are noisy. Below this many
    // frames (one frame is 10 ms) a segment is labelled by nearest match but
    // never allowed to create or move a cluster.
    int minFrames = 40;

    // 0 means "as many as the audio suggests". Setting it forces the extra
    // clusters to merge into their nearest neighbour, which is useful when
    // you know the recording is a two-person interview.
    int maxSpeakers = 0;

    // Subtract the recording's own mean embedding before comparing voices.
    //
    // Every embedding from one recording carries a shared component from the
    // microphone, the room and the codec. It tells us nothing about who is
    // speaking, but it inflates every similarity score, so real differences
    // between voices end up squeezed into a narrow band near the top of the
    // range. Removing it spreads them back out. Only the offline pass can do
    // this -- the online one has not heard the whole recording yet.
    bool centerOnRecordingMean = true;
};

// Label assigned to a segment whose embedding is missing entirely.
constexpr int kUnknownSpeaker = -1;

class Diarizer {
public:
    void configure(const DiarizerConfig& config) { config_ = config; }
    const DiarizerConfig& config() const { return config_; }

    void reset();

    // Online assignment. Returns a 0-based speaker index, or kUnknownSpeaker
    // when `vector` is empty.
    int assign(const std::vector<float>& vector, int frames);

    int speakerCount() const { return static_cast<int>(centroids_.size()); }

    // Offline clustering over every embedding. `vectors[i]` may be empty, in
    // which case result[i] is kUnknownSpeaker. Labels are renumbered by first
    // appearance, so speaker 0 is whoever speaks first.
    static std::vector<int> cluster(const std::vector<std::vector<float>>& vectors,
                                    const std::vector<int>& frames,
                                    const DiarizerConfig& config);

    // Cosine similarity of two same-length vectors; 0 if either is degenerate.
    static double similarity(const std::vector<float>& a, const std::vector<float>& b);

private:
    DiarizerConfig config_;
    std::vector<std::vector<float>> centroids_;
    std::vector<double> weights_;  // total frames folded into each centroid
};

}  // namespace va

#endif  // VA_STT_DIARIZER_H
