// Thin RAII wrapper over the Vosk C API.
//
// Vosk returns one JSON result per utterance -- it decides where an utterance
// ends from the silence in the audio -- and, when a speaker model is loaded,
// tags each result with an x-vector. That pairing is what makes diarisation
// possible without a second pass over the audio: a segment and its speaker
// embedding arrive together.
#ifndef VA_STT_VOSK_ENGINE_H
#define VA_STT_VOSK_ENGINE_H

#include <cstdint>
#include <string>
#include <vector>

namespace va {

struct WordTiming {
    std::string word;
    double start = 0.0;
    double end = 0.0;
    double confidence = 0.0;
};

struct Utterance {
    std::string text;
    std::vector<WordTiming> words;
    std::vector<float> speakerVector;  // empty when no speaker model is loaded
    int speakerFrames = 0;             // frames that fed the x-vector
    double start = 0.0;
    double end = 0.0;

    bool empty() const { return text.empty(); }
};

class VoskEngine {
public:
    VoskEngine() = default;
    ~VoskEngine();

    VoskEngine(const VoskEngine&) = delete;
    VoskEngine& operator=(const VoskEngine&) = delete;

    // 0 silences Vosk's own logging, -1 silences it including warnings.
    static void setLogLevel(int level);

    // Loads the acoustic/language model directory (the unpacked vosk-model-*).
    bool loadModel(const std::string& directory, std::string* error);

    // Optional. Without it recognition still works, but every segment is
    // attributed to a single unnamed speaker.
    bool loadSpeakerModel(const std::string& directory, std::string* error);

    bool hasSpeakerModel() const { return spkModel_ != nullptr; }

    // Creates the recogniser. Call once per file, after the models are loaded.
    bool startStream(float sampleRate, std::string* error);

    // Feeds mono 16-bit samples, appending every utterance Vosk closed while
    // consuming them, and returns how many were appended. A block of audio can
    // close more than one utterance when the speech in it is short, so this
    // takes a vector rather than a single slot -- returning only the last one
    // would quietly drop text.
    std::size_t accept(const std::int16_t* samples, std::size_t count,
                       std::vector<Utterance>* out);

    // Flushes whatever is still buffered at end of stream.
    bool finish(Utterance* out);

    // Releases the recogniser but keeps the models loaded, so the next file
    // does not pay the model load again.
    void endStream();

    void unload();

private:
    void* model_ = nullptr;       // VoskModel*
    void* spkModel_ = nullptr;    // VoskSpkModel*
    void* recognizer_ = nullptr;  // VoskRecognizer*

    static bool parseResult(const char* json, Utterance* out);
};

}  // namespace va

#endif  // VA_STT_VOSK_ENGINE_H
