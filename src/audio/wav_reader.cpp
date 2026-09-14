#include "audio/wav_reader.h"

#include <cstring>

namespace va {
namespace {

// WAV is little-endian regardless of the host, so the fields are assembled
// byte by byte instead of being memcpy'd over an integer.
std::uint32_t le32(const std::uint8_t* p) {
    return static_cast<std::uint32_t>(p[0]) | (static_cast<std::uint32_t>(p[1]) << 8) |
           (static_cast<std::uint32_t>(p[2]) << 16) | (static_cast<std::uint32_t>(p[3]) << 24);
}

std::uint16_t le16(const std::uint8_t* p) {
    return static_cast<std::uint16_t>(static_cast<std::uint16_t>(p[0]) |
                                      (static_cast<std::uint16_t>(p[1]) << 8));
}

constexpr std::uint16_t kFormatPcm = 1;
constexpr std::uint16_t kFormatFloat = 3;
constexpr std::uint16_t kFormatExtensible = 0xFFFE;

}  // namespace

bool WavReader::open(const std::string& path, std::string* error) {
    file_.open(path, std::ios::binary);
    if (!file_) {
        if (error) *error = "cannot open file: " + path;
        return false;
    }

    std::uint8_t header[12];
    file_.read(reinterpret_cast<char*>(header), 12);
    if (file_.gcount() != 12 || std::memcmp(header, "RIFF", 4) != 0 ||
        std::memcmp(header + 8, "WAVE", 4) != 0) {
        if (error) *error = "not a RIFF/WAVE file: " + path;
        return false;
    }

    bool haveFormat = false;
    // Walk the chunk list. "fmt " and "data" can appear in either order and
    // other chunks (LIST, fact, cue) may sit between them.
    while (file_) {
        std::uint8_t chunk[8];
        file_.read(reinterpret_cast<char*>(chunk), 8);
        if (file_.gcount() != 8) break;
        std::uint32_t size = le32(chunk + 4);

        if (std::memcmp(chunk, "fmt ", 4) == 0) {
            std::vector<std::uint8_t> fmt(size < 16 ? 16 : size, 0);
            file_.read(reinterpret_cast<char*>(fmt.data()), static_cast<std::streamsize>(size));
            if (file_.gcount() < 16) {
                if (error) *error = "truncated fmt chunk";
                return false;
            }
            std::uint16_t tag = le16(fmt.data());
            format_.channels = le16(fmt.data() + 2);
            format_.sampleRate = static_cast<int>(le32(fmt.data() + 4));
            bitsPerSample_ = le16(fmt.data() + 14);
            if (tag == kFormatExtensible && size >= 40) {
                // The real format sits in the GUID's first two bytes.
                tag = le16(fmt.data() + 24);
            }
            isFloat_ = (tag == kFormatFloat);
            if (tag != kFormatPcm && tag != kFormatFloat) {
                if (error) {
                    *error = "unsupported WAV encoding (tag " + std::to_string(tag) +
                             "); only PCM and IEEE float are handled";
                }
                return false;
            }
            haveFormat = true;
        } else if (std::memcmp(chunk, "data", 4) == 0) {
            dataOffset_ = static_cast<std::uint64_t>(file_.tellg());
            dataBytes_ = size;
            break;
        } else {
            file_.seekg(static_cast<std::streamoff>(size), std::ios::cur);
        }
        if (size % 2 == 1) file_.seekg(1, std::ios::cur);  // chunks are word aligned
    }

    if (!haveFormat || dataOffset_ == 0) {
        if (error) *error = "WAV file has no fmt/data chunk pair";
        return false;
    }
    if (format_.channels <= 0 || format_.sampleRate <= 0) {
        if (error) *error = "WAV file declares an invalid channel count or sample rate";
        return false;
    }
    if (!(bitsPerSample_ == 8 || bitsPerSample_ == 16 || bitsPerSample_ == 24 ||
          bitsPerSample_ == 32 || bitsPerSample_ == 64)) {
        if (error) *error = "unsupported WAV sample width: " + std::to_string(bitsPerSample_);
        return false;
    }

    // A streamed WAV can declare size 0 or 0xFFFFFFFF; fall back to the file
    // length so such files still play to the end.
    file_.seekg(0, std::ios::end);
    std::uint64_t fileSize = static_cast<std::uint64_t>(file_.tellg());
    if (dataBytes_ == 0 || dataOffset_ + dataBytes_ > fileSize) {
        dataBytes_ = fileSize > dataOffset_ ? fileSize - dataOffset_ : 0;
    }
    file_.clear();
    file_.seekg(static_cast<std::streamoff>(dataOffset_), std::ios::beg);
    return true;
}

std::size_t WavReader::read(std::vector<float>* out, std::size_t maxFrames) {
    out->clear();
    std::size_t bytesPerSample = static_cast<std::size_t>(bitsPerSample_ / 8);
    std::size_t bytesPerFrame = bytesPerSample * static_cast<std::size_t>(format_.channels);
    if (bytesPerFrame == 0 || maxFrames == 0) return 0;

    std::uint64_t remaining = dataBytes_ > bytesRead_ ? dataBytes_ - bytesRead_ : 0;
    std::size_t wantBytes = maxFrames * bytesPerFrame;
    if (wantBytes > remaining) wantBytes = static_cast<std::size_t>(remaining);
    if (wantBytes == 0) return 0;

    raw_.resize(wantBytes);
    file_.read(reinterpret_cast<char*>(raw_.data()), static_cast<std::streamsize>(wantBytes));
    std::size_t got = static_cast<std::size_t>(file_.gcount() > 0 ? file_.gcount() : 0);
    bytesRead_ += got;
    std::size_t frames = got / bytesPerFrame;
    std::size_t values = frames * static_cast<std::size_t>(format_.channels);

    out->resize(values);
    const std::uint8_t* p = raw_.data();
    for (std::size_t i = 0; i < values; ++i, p += bytesPerSample) {
        float v = 0.0f;
        if (isFloat_) {
            if (bitsPerSample_ == 32) {
                std::uint32_t bits = le32(p);
                float f;
                std::memcpy(&f, &bits, sizeof(f));
                v = f;
            } else {  // 64-bit double
                std::uint64_t bits = 0;
                for (int b = 7; b >= 0; --b) bits = (bits << 8) | p[b];
                double d;
                std::memcpy(&d, &bits, sizeof(d));
                v = static_cast<float>(d);
            }
        } else {
            switch (bitsPerSample_) {
                case 8:  // 8-bit PCM is unsigned, everything wider is signed
                    v = (static_cast<float>(p[0]) - 128.0f) / 128.0f;
                    break;
                case 16: {
                    std::int16_t s = static_cast<std::int16_t>(le16(p));
                    v = static_cast<float>(s) / 32768.0f;
                    break;
                }
                case 24: {
                    std::int32_t s = (static_cast<std::int32_t>(p[0]) << 8) |
                                     (static_cast<std::int32_t>(p[1]) << 16) |
                                     (static_cast<std::int32_t>(p[2]) << 24);
                    v = static_cast<float>(s >> 8) / 8388608.0f;
                    break;
                }
                case 32: {
                    std::int32_t s = static_cast<std::int32_t>(le32(p));
                    v = static_cast<float>(s) / 2147483648.0f;
                    break;
                }
                default: break;
            }
        }
        out->at(i) = v;
    }
    return frames;
}

double WavReader::progress() const {
    if (dataBytes_ == 0) return 0.0;
    double done = static_cast<double>(bytesRead_) / static_cast<double>(dataBytes_);
    return done < 0.0 ? 0.0 : (done > 1.0 ? 1.0 : done);
}

double WavReader::estimatedDuration() const {
    std::size_t bytesPerFrame =
        static_cast<std::size_t>(bitsPerSample_ / 8) * static_cast<std::size_t>(format_.channels);
    if (bytesPerFrame == 0 || format_.sampleRate <= 0) return 0.0;
    return static_cast<double>(dataBytes_ / bytesPerFrame) / format_.sampleRate;
}

}  // namespace va
