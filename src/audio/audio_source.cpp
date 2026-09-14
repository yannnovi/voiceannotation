#include "audio/audio_source.h"

#include <algorithm>
#include <cstdint>
#include <cstring>
#include <fstream>

#include "audio/mp3_decoder.h"
#include "audio/wav_reader.h"

namespace va {
namespace {

std::string lowerExtension(const std::string& path) {
    std::size_t dot = path.find_last_of('.');
    if (dot == std::string::npos) return std::string();
    std::string ext = path.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return ext;
}

enum class Container { Unknown, Mp3, Wav };

// Sniffing beats trusting the extension: files arrive renamed often enough,
// and an MP3 with an ID3 tag needs the tag skipped before the sync word shows.
Container sniff(const std::string& path) {
    std::ifstream f(path, std::ios::binary);
    if (!f) return Container::Unknown;
    std::uint8_t head[12] = {0};
    f.read(reinterpret_cast<char*>(head), sizeof(head));
    std::streamsize got = f.gcount();
    if (got >= 12 && std::memcmp(head, "RIFF", 4) == 0 && std::memcmp(head + 8, "WAVE", 4) == 0) {
        return Container::Wav;
    }
    if (got >= 3 && std::memcmp(head, "ID3", 3) == 0) return Container::Mp3;
    // MPEG audio frame sync: eleven set bits.
    if (got >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0) return Container::Mp3;
    return Container::Unknown;
}

}  // namespace

std::unique_ptr<AudioSource> openAudioFile(const std::string& path, std::string* error) {
    Container container = sniff(path);
    if (container == Container::Unknown) {
        std::string ext = lowerExtension(path);
        if (ext == "mp3") {
            container = Container::Mp3;
        } else if (ext == "wav" || ext == "wave") {
            container = Container::Wav;
        }
    }

    switch (container) {
        case Container::Mp3: {
            std::unique_ptr<Mp3Decoder> decoder(new Mp3Decoder);
            if (!decoder->open(path, error)) return nullptr;
            return decoder;
        }
        case Container::Wav: {
            std::unique_ptr<WavReader> reader(new WavReader);
            if (!reader->open(path, error)) return nullptr;
            return reader;
        }
        case Container::Unknown:
        default:
            if (error) {
                *error = "unrecognised audio format: " + path +
                         " (MP3 and WAV are supported; convert other formats first)";
            }
            return nullptr;
    }
}

}  // namespace va
