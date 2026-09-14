// MP3 decoding built on minimp3 (third_party/minimp3), a single-header,
// dependency-free decoder. The file is streamed through a sliding window
// rather than loaded whole, so a multi-hour recording costs a fixed amount of
// memory.
#ifndef VA_AUDIO_MP3_DECODER_H
#define VA_AUDIO_MP3_DECODER_H

#include <cstdint>
#include <fstream>
#include <memory>
#include <string>
#include <vector>

#include "audio/audio_source.h"

namespace va {

class Mp3Decoder : public AudioSource {
public:
    Mp3Decoder();
    ~Mp3Decoder() override;

    bool open(const std::string& path, std::string* error);

    std::size_t read(std::vector<float>* out, std::size_t maxFrames) override;
    AudioFormat format() const override { return format_; }
    double progress() const override;
    double estimatedDuration() const override;
    const char* formatName() const override { return "MP3"; }

    // True when the stream advertised more than one bitrate, i.e. the duration
    // guessed from the average so far is only approximate.
    bool isVariableBitrate() const { return variableBitrate_; }

private:
    struct Impl;  // hides the minimp3 types from every other translation unit
    std::unique_ptr<Impl> impl_;

    std::ifstream file_;
    std::uint64_t fileSize_ = 0;
    std::uint64_t bytesConsumed_ = 0;
    std::uint64_t audioStart_ = 0;  // first byte after any ID3v2 tag

    std::vector<std::uint8_t> buffer_;
    std::size_t bufferPos_ = 0;
    bool eof_ = false;

    AudioFormat format_;
    int firstBitrateKbps_ = 0;
    double bitrateSumKbps_ = 0.0;
    std::uint64_t frameCount_ = 0;
    bool variableBitrate_ = false;

    // Tops the sliding window up so at least `wanted` bytes are available,
    // discarding what the decoder has already consumed. Returns bytes available.
    std::size_t fill(std::size_t wanted);
};

}  // namespace va

#endif  // VA_AUDIO_MP3_DECODER_H
