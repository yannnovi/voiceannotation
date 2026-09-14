// RIFF/WAVE reader.
//
// Vosk models are trained on 16 kHz mono audio, and WAV is what people reach
// for when they have already converted a recording. Supporting it natively
// also gives the test suite a format it can synthesise without a codec.
#ifndef VA_AUDIO_WAV_READER_H
#define VA_AUDIO_WAV_READER_H

#include <cstdint>
#include <fstream>
#include <string>
#include <vector>

#include "audio/audio_source.h"

namespace va {

class WavReader : public AudioSource {
public:
    bool open(const std::string& path, std::string* error);

    std::size_t read(std::vector<float>* out, std::size_t maxFrames) override;
    AudioFormat format() const override { return format_; }
    double progress() const override;
    double estimatedDuration() const override;
    const char* formatName() const override { return "WAV"; }

private:
    std::ifstream file_;
    AudioFormat format_;
    int bitsPerSample_ = 0;
    bool isFloat_ = false;
    std::uint64_t dataOffset_ = 0;
    std::uint64_t dataBytes_ = 0;
    std::uint64_t bytesRead_ = 0;
    std::vector<std::uint8_t> raw_;
};

}  // namespace va

#endif  // VA_AUDIO_WAV_READER_H
