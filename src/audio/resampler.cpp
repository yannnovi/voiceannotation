#include "audio/resampler.h"

#include <algorithm>
#include <cmath>

namespace va {
namespace {

// Sinc zero crossings kept on each side of the centre. Eight is generous for
// speech: the stopband is well below the noise floor of any real recording,
// and the cost stays linear in this number.
constexpr int kZeroCrossings = 8;

// Filter samples stored per input sample. 128 plus linear interpolation puts
// the table's own error far below 16-bit quantisation.
constexpr int kTableDensity = 128;

constexpr double kPi = 3.14159265358979323846;

double sinc(double x) {
    if (std::fabs(x) < 1e-9) return 1.0;
    double t = kPi * x;
    return std::sin(t) / t;
}

// Blackman window; its ~-58 dB sidelobes are what keep aliasing inaudible.
double blackman(double x) {  // x in [0, 1], measured from the centre outwards
    double t = kPi * x;
    return 0.42 + 0.5 * std::cos(t) + 0.08 * std::cos(2.0 * t);
}

std::int16_t toPcm16(float v) {
    // Clamp before scaling: decoded MP3 can legitimately exceed +/-1.0.
    float scaled = v * 32767.0f;
    if (scaled > 32767.0f) return 32767;
    if (scaled < -32768.0f) return -32768;
    return static_cast<std::int16_t>(std::lround(scaled));
}

}  // namespace

void Resampler::reset(int inRate, int inChannels, int outRate) {
    inRate_ = inRate;
    inChannels_ = inChannels > 0 ? inChannels : 1;
    outRate_ = outRate;
    history_.clear();
    base_ = 0;
    inputCount_ = 0;
    outIndex_ = 0;
    samplesEmitted_ = 0;
    table_.clear();

    passthrough_ = (inRate_ == outRate_);
    if (passthrough_ || inRate_ <= 0 || outRate_ <= 0) return;

    ratio_ = static_cast<double>(outRate_) / static_cast<double>(inRate_);
    // Downsampling needs the filter to cut at the *output* Nyquist, which in
    // input-sample terms means stretching it by 1/ratio. Upsampling keeps the
    // input Nyquist, so the scale stays at 1.
    cutoffScale_ = std::min(1.0, ratio_);
    halfWidth_ = static_cast<int>(std::ceil(kZeroCrossings / cutoffScale_));
    buildTable();
}

void Resampler::buildTable() {
    std::size_t count = static_cast<std::size_t>(halfWidth_) * kTableDensity + 2;
    table_.resize(count);
    for (std::size_t i = 0; i < count; ++i) {
        double t = static_cast<double>(i) / kTableDensity;  // distance in input samples
        double w = t >= halfWidth_ ? 0.0 : blackman(t / halfWidth_);
        // The cutoffScale_ factor normalises the sum of taps to unity gain.
        table_[i] = static_cast<float>(sinc(cutoffScale_ * t) * cutoffScale_ * w);
    }
}

float Resampler::tap(double distance) const {
    double pos = distance * kTableDensity;
    std::size_t i = static_cast<std::size_t>(pos);
    if (i + 1 >= table_.size()) return 0.0f;
    float frac = static_cast<float>(pos - static_cast<double>(i));
    return table_[i] + (table_[i + 1] - table_[i]) * frac;
}

void Resampler::process(const float* interleaved, std::size_t frames,
                        std::vector<std::int16_t>* out) {
    if (frames == 0) return;

    if (passthrough_) {
        out->reserve(out->size() + frames);
        for (std::size_t f = 0; f < frames; ++f) {
            float sum = 0.0f;
            for (int c = 0; c < inChannels_; ++c) {
                sum += interleaved[f * static_cast<std::size_t>(inChannels_) +
                                   static_cast<std::size_t>(c)];
            }
            out->push_back(toPcm16(sum / static_cast<float>(inChannels_)));
        }
        samplesEmitted_ += frames;
        return;
    }

    history_.reserve(history_.size() + frames);
    for (std::size_t f = 0; f < frames; ++f) {
        float sum = 0.0f;
        for (int c = 0; c < inChannels_; ++c) {
            sum += interleaved[f * static_cast<std::size_t>(inChannels_) +
                               static_cast<std::size_t>(c)];
        }
        history_.push_back(sum / static_cast<float>(inChannels_));
    }
    inputCount_ += frames;

    emit(out, false);
    trimHistory();
}

void Resampler::emit(std::vector<std::int16_t>* out, bool draining) {
    if (history_.empty() && !draining) return;

    while (true) {
        // Input position, in absolute input samples, of this output sample.
        double x = static_cast<double>(outIndex_) / ratio_;
        double windowEnd = x + halfWidth_;
        if (!draining && windowEnd >= static_cast<double>(inputCount_)) break;
        if (draining && x >= static_cast<double>(inputCount_)) break;

        std::int64_t centre = static_cast<std::int64_t>(std::floor(x));
        std::int64_t first = centre - halfWidth_ + 1;
        std::int64_t last = centre + halfWidth_;

        float acc = 0.0f;
        for (std::int64_t i = first; i <= last; ++i) {
            if (i < static_cast<std::int64_t>(base_) ||
                i >= static_cast<std::int64_t>(inputCount_)) {
                continue;  // outside the stream: treated as silence
            }
            std::size_t idx = static_cast<std::size_t>(i - static_cast<std::int64_t>(base_));
            acc += history_[idx] * tap(std::fabs(static_cast<double>(i) - x));
        }
        out->push_back(toPcm16(acc));
        ++outIndex_;
        ++samplesEmitted_;
    }
}

void Resampler::trimHistory() {
    // Keep only what the next output sample's window can still reach back to.
    double nextX = static_cast<double>(outIndex_) / ratio_;
    std::int64_t keepFrom = static_cast<std::int64_t>(std::floor(nextX)) - halfWidth_;
    if (keepFrom <= static_cast<std::int64_t>(base_)) return;

    std::size_t drop = static_cast<std::size_t>(keepFrom - static_cast<std::int64_t>(base_));
    if (drop >= history_.size()) {
        base_ += history_.size();
        history_.clear();
        return;
    }
    history_.erase(history_.begin(), history_.begin() + static_cast<std::ptrdiff_t>(drop));
    base_ += drop;
}

void Resampler::flush(std::vector<std::int16_t>* out) {
    if (passthrough_) return;
    emit(out, true);
    history_.clear();
    base_ = inputCount_;
}

}  // namespace va
