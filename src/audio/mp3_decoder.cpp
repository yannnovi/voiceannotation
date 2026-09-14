#include "audio/mp3_decoder.h"

#include <algorithm>
#include <cstring>

// minimp3 emits float samples directly, which spares a conversion pass since
// everything upstream of the recogniser works in float.
#define MINIMP3_FLOAT_OUTPUT
#define MINIMP3_IMPLEMENTATION
#include "minimp3.h"

namespace va {
namespace {

// Enough for a maximum-size frame plus slack for the decoder to resynchronise
// after garbage or a tag it does not recognise.
constexpr std::size_t kWindowBytes = 64 * 1024;
constexpr std::size_t kRefillBytes = 256 * 1024;

// Returns the total size of an ID3v2 tag at the start of the file, or 0.
// Skipping it up front keeps `progress()` honest: a cover image can be a large
// share of the file and would otherwise show as instant early progress.
std::uint64_t id3v2Size(const std::uint8_t* p, std::size_t n) {
    if (n < 10 || std::memcmp(p, "ID3", 3) != 0) return 0;
    // Size is stored as four 7-bit big-endian bytes.
    std::uint64_t size = (static_cast<std::uint64_t>(p[6] & 0x7F) << 21) |
                         (static_cast<std::uint64_t>(p[7] & 0x7F) << 14) |
                         (static_cast<std::uint64_t>(p[8] & 0x7F) << 7) |
                         static_cast<std::uint64_t>(p[9] & 0x7F);
    std::uint64_t total = size + 10;
    if (p[5] & 0x10) total += 10;  // footer present
    return total;
}

}  // namespace

struct Mp3Decoder::Impl {
    mp3dec_t decoder;
    mp3d_sample_t pcm[MINIMP3_MAX_SAMPLES_PER_FRAME];
};

Mp3Decoder::Mp3Decoder() : impl_(new Impl) { mp3dec_init(&impl_->decoder); }

Mp3Decoder::~Mp3Decoder() = default;

bool Mp3Decoder::open(const std::string& path, std::string* error) {
    file_.open(path, std::ios::binary);
    if (!file_) {
        if (error) *error = "cannot open file: " + path;
        return false;
    }
    file_.seekg(0, std::ios::end);
    std::streamoff end = file_.tellg();
    fileSize_ = end > 0 ? static_cast<std::uint64_t>(end) : 0;
    file_.seekg(0, std::ios::beg);

    if (fileSize_ == 0) {
        if (error) *error = "file is empty: " + path;
        return false;
    }

    // Prime the window so the ID3 header (if any) can be measured and skipped.
    if (fill(kWindowBytes) == 0) {
        if (error) *error = "cannot read file: " + path;
        return false;
    }
    std::uint64_t tag = id3v2Size(buffer_.data() + bufferPos_, buffer_.size() - bufferPos_);
    if (tag > 0 && tag < fileSize_) {
        audioStart_ = tag;
        // Re-seek rather than skipping through the window: the tag is often
        // larger than the window itself.
        buffer_.clear();
        bufferPos_ = 0;
        eof_ = false;
        file_.clear();
        file_.seekg(static_cast<std::streamoff>(tag), std::ios::beg);
        bytesConsumed_ = tag;
    }
    return true;
}

std::size_t Mp3Decoder::fill(std::size_t wanted) {
    if (bufferPos_ > 0) {
        buffer_.erase(buffer_.begin(), buffer_.begin() + static_cast<std::ptrdiff_t>(bufferPos_));
        bufferPos_ = 0;
    }
    while (buffer_.size() < wanted && !eof_) {
        std::size_t oldSize = buffer_.size();
        buffer_.resize(oldSize + kRefillBytes);
        file_.read(reinterpret_cast<char*>(buffer_.data() + oldSize),
                   static_cast<std::streamsize>(kRefillBytes));
        std::streamsize got = file_.gcount();
        buffer_.resize(oldSize + static_cast<std::size_t>(got > 0 ? got : 0));
        if (got <= 0) eof_ = true;
    }
    return buffer_.size();
}

std::size_t Mp3Decoder::read(std::vector<float>* out, std::size_t maxFrames) {
    out->clear();
    if (maxFrames == 0) return 0;

    std::size_t framesProduced = 0;
    while (framesProduced < maxFrames) {
        std::size_t available = buffer_.size() - bufferPos_;
        if (available < kWindowBytes && !eof_) {
            available = fill(kWindowBytes);
        }
        if (available == 0) break;

        mp3dec_frame_info_t info;
        int samples = mp3dec_decode_frame(&impl_->decoder, buffer_.data() + bufferPos_,
                                          static_cast<int>(available), impl_->pcm, &info);

        if (info.frame_bytes == 0) {
            // The decoder needs more data than the window holds; if there is no
            // more data the stream is finished (or ends in garbage).
            if (eof_) break;
            // fill() both rewinds bufferPos_ and returns the bytes now
            // available, so the two sides are captured in separate statements:
            // reading buffer_.size() in the same expression as the call would
            // leave the order of evaluation up to the compiler.
            std::size_t before = buffer_.size() - bufferPos_;
            std::size_t after = fill(before + kRefillBytes);
            if (after <= before) break;  // nothing more is coming
            continue;
        }

        bufferPos_ += static_cast<std::size_t>(info.frame_bytes);
        bytesConsumed_ += static_cast<std::uint64_t>(info.frame_bytes);

        if (samples <= 0) continue;  // skipped a tag or a corrupt frame

        if (format_.sampleRate == 0) {
            format_.sampleRate = info.hz;
            format_.channels = info.channels;
            firstBitrateKbps_ = info.bitrate_kbps;
        } else if (info.hz != format_.sampleRate || info.channels != format_.channels) {
            // Mid-stream layout changes are rare and not worth resampling on
            // the fly; stopping is safer than silently corrupting the audio.
            break;
        }
        if (info.bitrate_kbps != firstBitrateKbps_) variableBitrate_ = true;
        bitrateSumKbps_ += info.bitrate_kbps;
        ++frameCount_;

        std::size_t frames = static_cast<std::size_t>(samples);
        std::size_t values = frames * static_cast<std::size_t>(info.channels);
        out->insert(out->end(), impl_->pcm, impl_->pcm + values);
        framesProduced += frames;
    }
    return framesProduced;
}

double Mp3Decoder::progress() const {
    if (fileSize_ == 0) return 0.0;
    double done = static_cast<double>(bytesConsumed_) / static_cast<double>(fileSize_);
    return done < 0.0 ? 0.0 : (done > 1.0 ? 1.0 : done);
}

double Mp3Decoder::estimatedDuration() const {
    if (frameCount_ == 0 || fileSize_ <= audioStart_) return 0.0;
    double avgKbps = bitrateSumKbps_ / static_cast<double>(frameCount_);
    if (avgKbps <= 0.0) return 0.0;
    double audioBytes = static_cast<double>(fileSize_ - audioStart_);
    return audioBytes * 8.0 / (avgKbps * 1000.0);
}

}  // namespace va
