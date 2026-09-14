// Converts arbitrary interleaved float audio to the 16 kHz mono int16 stream
// Vosk models expect.
//
// Two things happen here: channels are mixed down, and the sample rate is
// converted with a windowed-sinc filter. Linear interpolation would be far
// cheaper but aliases badly going from 44.1 kHz to 16 kHz, and the aliased
// energy lands right in the formant range the acoustic model keys on.
#ifndef VA_AUDIO_RESAMPLER_H
#define VA_AUDIO_RESAMPLER_H

#include <cstddef>
#include <cstdint>
#include <vector>

namespace va {

class Resampler {
public:
    // Prepares a conversion from `inRate`/`inChannels` to mono at `outRate`.
    // Safe to call again to restart on a new file.
    void reset(int inRate, int inChannels, int outRate);

    // Consumes `frames` interleaved frames and appends the converted samples.
    // Output is appended, never cleared, so callers can batch.
    void process(const float* interleaved, std::size_t frames, std::vector<std::int16_t>* out);

    // Drains the filter tail once the input is exhausted.
    void flush(std::vector<std::int16_t>* out);

    int outputRate() const { return outRate_; }

    // Total mono samples emitted since the last reset(); the caller turns this
    // into a timestamp without having to track it separately.
    std::uint64_t samplesEmitted() const { return samplesEmitted_; }

private:
    int inRate_ = 0;
    int inChannels_ = 0;
    int outRate_ = 0;
    bool passthrough_ = false;

    // Filter geometry, in input samples.
    double ratio_ = 1.0;       // outRate / inRate
    double cutoffScale_ = 1.0; // min(1, ratio): how far the filter is stretched
    int halfWidth_ = 0;        // taps on each side
    std::vector<float> table_; // h(t) sampled every 1/kTableDensity input samples

    // Sliding mono input history. history_[0] is absolute input index base_.
    std::vector<float> history_;
    std::uint64_t base_ = 0;
    std::uint64_t inputCount_ = 0;   // absolute count of mono samples pushed in
    std::uint64_t outIndex_ = 0;     // next output sample to produce
    std::uint64_t samplesEmitted_ = 0;

    void buildTable();
    float tap(double distance) const;
    // Emits every output sample whose filter window fits in the history.
    // When `draining`, the window may run past the end (treated as silence).
    void emit(std::vector<std::int16_t>* out, bool draining);
    void trimHistory();
};

}  // namespace va

#endif  // VA_AUDIO_RESAMPLER_H
