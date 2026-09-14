#include "stt/vosk_engine.h"

#include <vosk_api.h>

#include <algorithm>
#include <cstddef>

#include "util/json.h"

namespace va {
namespace {

// Vosk takes sample counts, but feeding it multi-megabyte blocks gains nothing
// and delays the utterance callbacks that drive the progress display.
constexpr std::size_t kMaxChunkSamples = 16000;  // one second at 16 kHz

}  // namespace

VoskEngine::~VoskEngine() { unload(); }

void VoskEngine::setLogLevel(int level) { vosk_set_log_level(level); }

bool VoskEngine::loadModel(const std::string& directory, std::string* error) {
    if (model_) {
        vosk_model_free(static_cast<VoskModel*>(model_));
        model_ = nullptr;
    }
    model_ = vosk_model_new(directory.c_str());
    if (!model_) {
        if (error) {
            *error = "Vosk could not load the model at: " + directory +
                     "\nCheck that the directory is the unpacked model itself "
                     "(it should contain am/, conf/, graph/ ...).";
        }
        return false;
    }
    return true;
}

bool VoskEngine::loadSpeakerModel(const std::string& directory, std::string* error) {
    if (spkModel_) {
        vosk_spk_model_free(static_cast<VoskSpkModel*>(spkModel_));
        spkModel_ = nullptr;
    }
    spkModel_ = vosk_spk_model_new(directory.c_str());
    if (!spkModel_) {
        if (error) {
            *error = "Vosk could not load the speaker model at: " + directory;
        }
        return false;
    }
    return true;
}

bool VoskEngine::startStream(float sampleRate, std::string* error) {
    if (!model_) {
        if (error) *error = "no recognition model is loaded";
        return false;
    }
    endStream();

    VoskRecognizer* rec = nullptr;
    if (spkModel_) {
        rec = vosk_recognizer_new_spk(static_cast<VoskModel*>(model_), sampleRate,
                                      static_cast<VoskSpkModel*>(spkModel_));
    } else {
        rec = vosk_recognizer_new(static_cast<VoskModel*>(model_), sampleRate);
    }
    if (!rec) {
        if (error) *error = "Vosk could not create a recogniser";
        return false;
    }
    // Word-level timings are what let the UI place a segment on a timeline.
    vosk_recognizer_set_words(rec, 1);
    recognizer_ = rec;
    return true;
}

std::size_t VoskEngine::accept(const std::int16_t* samples, std::size_t count,
                               std::vector<Utterance>* out) {
    if (!recognizer_ || !out) return 0;
    VoskRecognizer* rec = static_cast<VoskRecognizer*>(recognizer_);

    std::size_t appended = 0;
    std::size_t offset = 0;
    while (offset < count) {
        std::size_t chunk = std::min(kMaxChunkSamples, count - offset);
        int finished = vosk_recognizer_accept_waveform_s(rec, samples + offset,
                                                         static_cast<int>(chunk));
        offset += chunk;
        if (!finished) continue;

        Utterance utterance;
        if (parseResult(vosk_recognizer_result(rec), &utterance)) {
            out->push_back(std::move(utterance));
            ++appended;
        }
    }
    return appended;
}

bool VoskEngine::finish(Utterance* out) {
    if (!recognizer_) return false;
    VoskRecognizer* rec = static_cast<VoskRecognizer*>(recognizer_);
    return parseResult(vosk_recognizer_final_result(rec), out);
}

bool VoskEngine::parseResult(const char* json, Utterance* out) {
    if (!json || !out) return false;
    *out = Utterance();

    Json root = Json::parse(json);
    out->text = root["text"].asString();

    const Json& words = root["result"];
    if (words.isArray()) {
        out->words.reserve(words.size());
        for (const Json& w : words.items()) {
            WordTiming t;
            t.word = w["word"].asString();
            t.start = w["start"].asDouble();
            t.end = w["end"].asDouble();
            t.confidence = w["conf"].asDouble(1.0);
            out->words.push_back(std::move(t));
        }
    }
    if (!out->words.empty()) {
        out->start = out->words.front().start;
        out->end = out->words.back().end;
    }

    const Json& spk = root["spk"];
    if (spk.isArray() && spk.size() > 0) {
        out->speakerVector.reserve(spk.size());
        for (const Json& v : spk.items()) {
            out->speakerVector.push_back(static_cast<float>(v.asDouble()));
        }
        out->speakerFrames = root["spk_frames"].asInt();
    }

    // Results with no text are the normal outcome for a stretch of silence.
    return !out->text.empty();
}

void VoskEngine::endStream() {
    if (recognizer_) {
        vosk_recognizer_free(static_cast<VoskRecognizer*>(recognizer_));
        recognizer_ = nullptr;
    }
}

void VoskEngine::unload() {
    endStream();
    if (spkModel_) {
        vosk_spk_model_free(static_cast<VoskSpkModel*>(spkModel_));
        spkModel_ = nullptr;
    }
    if (model_) {
        vosk_model_free(static_cast<VoskModel*>(model_));
        model_ = nullptr;
    }
}

}  // namespace va
