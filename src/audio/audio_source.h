// A pull-style audio source that yields interleaved float frames.
//
// Everything downstream (resampling, recognition) only ever sees this
// interface, so adding a container format means adding one implementation and
// nothing else. No platform-specific audio API is involved anywhere: files are
// decoded in-process, which is what keeps the project portable.
#ifndef VA_AUDIO_AUDIO_SOURCE_H
#define VA_AUDIO_AUDIO_SOURCE_H

#include <cstddef>
#include <memory>
#include <string>
#include <vector>

namespace va {

struct AudioFormat {
    int sampleRate = 0;
    int channels = 0;
};

class AudioSource {
public:
    virtual ~AudioSource() = default;

    // Reads up to `maxFrames` interleaved frames, appending nothing on EOF.
    // `out` is resized to framesRead * channels. Returns the frame count.
    virtual std::size_t read(std::vector<float>* out, std::size_t maxFrames) = 0;

    // Valid only once the first read() has returned data: compressed formats
    // do not know their layout until the first frame header is decoded.
    virtual AudioFormat format() const = 0;

    // Fraction of the input consumed, in [0, 1]. Used to drive the progress
    // bar; it is byte-based for formats without a reliable duration header.
    virtual double progress() const = 0;

    // Best-known duration in seconds, or 0 when the format cannot tell.
    virtual double estimatedDuration() const = 0;

    virtual const char* formatName() const = 0;
};

// Opens `path`, sniffing the container from its leading bytes (the extension
// is only a fallback). Returns nullptr and sets `error` on failure.
std::unique_ptr<AudioSource> openAudioFile(const std::string& path, std::string* error);

}  // namespace va

#endif  // VA_AUDIO_AUDIO_SOURCE_H
