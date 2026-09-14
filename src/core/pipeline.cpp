#include "core/pipeline.h"

#include <chrono>
#include <utility>

#include "audio/audio_source.h"
#include "audio/resampler.h"

namespace va {
namespace {

// Vosk models are trained at 16 kHz; feeding anything else degrades accuracy
// badly even though the API accepts it.
constexpr int kTargetSampleRate = 16000;

// Decode granularity. Large enough that per-call overhead disappears, small
// enough that cancelling feels immediate.
constexpr std::size_t kDecodeFrames = 16384;

// How often progress is reported, in wall-clock seconds.
constexpr double kProgressInterval = 0.25;

double secondsSince(const std::chrono::steady_clock::time_point& start) {
    return std::chrono::duration<double>(std::chrono::steady_clock::now() - start).count();
}

}  // namespace

Pipeline::~Pipeline() {
    cancel();
    wait();
}

void Pipeline::push(Event event) {
    std::lock_guard<std::mutex> lock(queueMutex_);
    queue_.push_back(std::move(event));
}

void Pipeline::pushStatus(const std::string& message) {
    Event e;
    e.type = EventType::Status;
    e.message = message;
    push(std::move(e));
}

std::vector<Event> Pipeline::drain() {
    std::vector<Event> out;
    std::lock_guard<std::mutex> lock(queueMutex_);
    out.swap(queue_);
    return out;
}

void Pipeline::cancel() { cancelRequested_.store(true); }

void Pipeline::wait() {
    if (worker_.joinable()) worker_.join();
}

bool Pipeline::start(const PipelineConfig& config, std::string* error) {
    if (running_.load()) {
        if (error) *error = "a transcription is already running";
        return false;
    }
    if (config.audioPath.empty()) {
        if (error) *error = "no audio file given";
        return false;
    }
    if (config.modelPath.empty()) {
        if (error) *error = "no recognition model given";
        return false;
    }

    wait();  // reap a previous worker before starting another
    {
        std::lock_guard<std::mutex> lock(queueMutex_);
        queue_.clear();
    }
    cancelRequested_.store(false);
    running_.store(true);
    worker_ = std::thread(&Pipeline::run, this, config);
    return true;
}

void Pipeline::run(PipelineConfig config) {
    auto fail = [this](const std::string& message) {
        Event e;
        e.type = EventType::Failed;
        e.message = message;
        push(std::move(e));
        running_.store(false);
    };

    auto startTime = std::chrono::steady_clock::now();

    transcript_.clear();
    transcript_.sourcePath = config.audioPath;
    transcript_.modelPath = config.modelPath;
    transcript_.speakerModelPath = config.speakerModelPath;

    std::string error;

    // --- models ----------------------------------------------------------
    if (config.modelPath != loadedModel_) {
        pushStatus("Loading recognition model...");
        if (!engine_.loadModel(config.modelPath, &error)) {
            loadedModel_.clear();
            fail(error);
            return;
        }
        loadedModel_ = config.modelPath;
    }
    if (config.speakerModelPath != loadedSpeakerModel_) {
        if (config.speakerModelPath.empty()) {
            // Vosk has no API to detach a speaker model from a loaded model,
            // so the engine is rebuilt without one.
            engine_.unload();
            loadedModel_.clear();
            pushStatus("Loading recognition model...");
            if (!engine_.loadModel(config.modelPath, &error)) {
                fail(error);
                return;
            }
            loadedModel_ = config.modelPath;
        } else {
            pushStatus("Loading speaker model...");
            if (!engine_.loadSpeakerModel(config.speakerModelPath, &error)) {
                loadedSpeakerModel_.clear();
                fail(error);
                return;
            }
        }
        loadedSpeakerModel_ = config.speakerModelPath;
    }

    if (cancelRequested_.load()) {
        Event e;
        e.type = EventType::Finished;
        e.cancelled = true;
        push(std::move(e));
        running_.store(false);
        return;
    }

    // --- audio -----------------------------------------------------------
    std::unique_ptr<AudioSource> source = openAudioFile(config.audioPath, &error);
    if (!source) {
        fail(error);
        return;
    }

    if (!engine_.startStream(static_cast<float>(kTargetSampleRate), &error)) {
        fail(error);
        return;
    }

    Diarizer diarizer;
    diarizer.configure(config.diarizer);

    Resampler resampler;
    bool resamplerReady = false;

    std::vector<float> decoded;
    std::vector<std::int16_t> pcm;
    std::vector<Utterance> utterances;
    Utterance utterance;
    double lastProgress = -1.0;
    bool cancelled = false;

    pushStatus("Transcribing...");

    auto emitSegment = [&](const Utterance& u) {
        if (u.empty()) return;
        Segment segment;
        segment.start = u.start;
        segment.end = u.end;
        segment.text = u.text;
        segment.words = u.words;
        segment.speakerVector = u.speakerVector;
        segment.speakerFrames = u.speakerFrames;
        segment.speaker = diarizer.assign(u.speakerVector, u.speakerFrames);

        transcript_.add(segment);

        Event e;
        e.type = EventType::Segment;
        e.segment = segment;
        e.segmentIndex = static_cast<int>(transcript_.segments().size()) - 1;
        push(std::move(e));
    };

    while (true) {
        if (cancelRequested_.load()) {
            cancelled = true;
            break;
        }

        std::size_t frames = source->read(&decoded, kDecodeFrames);
        if (frames == 0) break;

        if (!resamplerReady) {
            AudioFormat format = source->format();
            if (format.sampleRate <= 0 || format.channels <= 0) {
                fail("the audio stream has no usable format header");
                return;
            }
            transcript_.sourceSampleRate = format.sampleRate;
            transcript_.sourceChannels = format.channels;
            resampler.reset(format.sampleRate, format.channels, kTargetSampleRate);
            resamplerReady = true;
            pushStatus("Audio: " + std::string(source->formatName()) + ", " +
                       std::to_string(format.sampleRate) + " Hz, " +
                       std::to_string(format.channels) + " ch -> " +
                       std::to_string(kTargetSampleRate) + " Hz mono");
        }

        pcm.clear();
        resampler.process(decoded.data(), frames, &pcm);
        if (!pcm.empty()) {
            utterances.clear();
            engine_.accept(pcm.data(), pcm.size(), &utterances);
            for (const Utterance& completed : utterances) emitSegment(completed);
        }

        double elapsed = secondsSince(startTime);
        if (elapsed - lastProgress >= kProgressInterval) {
            lastProgress = elapsed;
            double audioPosition =
                static_cast<double>(resampler.samplesEmitted()) / kTargetSampleRate;
            Event e;
            e.type = EventType::Progress;
            e.fraction = source->progress();
            e.audioPosition = audioPosition;
            e.duration = source->estimatedDuration();
            e.elapsed = elapsed;
            e.speed = elapsed > 0.0 ? audioPosition / elapsed : 0.0;
            push(std::move(e));
        }
    }

    if (resamplerReady && !cancelled) {
        pcm.clear();
        resampler.flush(&pcm);
        if (!pcm.empty()) {
            utterances.clear();
            engine_.accept(pcm.data(), pcm.size(), &utterances);
            for (const Utterance& completed : utterances) emitSegment(completed);
        }
    }

    // Even a cancelled run flushes: the partial transcript is worth keeping.
    if (engine_.finish(&utterance)) {
        emitSegment(utterance);
    }
    engine_.endStream();

    transcript_.audioDuration =
        static_cast<double>(resampler.samplesEmitted()) / kTargetSampleRate;

    // Final pass over every embedding at once. The online labels shown during
    // the run only ever saw the past; this sees the whole recording and is
    // what the exported transcript is built from.
    bool relabelled = false;
    if (!transcript_.empty() && engine_.hasSpeakerModel()) {
        pushStatus("Grouping speakers...");
        std::vector<std::vector<float>> vectors;
        std::vector<int> frames;
        std::vector<int> before;
        vectors.reserve(transcript_.segments().size());
        frames.reserve(transcript_.segments().size());
        before.reserve(transcript_.segments().size());
        for (const Segment& s : transcript_.segments()) {
            vectors.push_back(s.speakerVector);
            frames.push_back(s.speakerFrames);
            before.push_back(s.speaker);
        }
        std::vector<int> labels = Diarizer::cluster(vectors, frames, config.diarizer);
        relabelled = labels != before;
        transcript_.relabel(labels);
    }

    Event done;
    done.type = EventType::Finished;
    done.cancelled = cancelled;
    done.relabelled = relabelled;
    done.elapsed = secondsSince(startTime);
    done.audioPosition = transcript_.audioDuration;
    done.duration = transcript_.audioDuration;
    done.speed = done.elapsed > 0.0 ? done.audioPosition / done.elapsed : 0.0;
    done.fraction = 1.0;
    push(std::move(done));
    running_.store(false);
}

int Pipeline::recluster(const DiarizerConfig& config) {
    if (running_.load()) return transcript_.speakerCount();

    std::vector<std::vector<float>> vectors;
    std::vector<int> frames;
    vectors.reserve(transcript_.segments().size());
    frames.reserve(transcript_.segments().size());
    for (const Segment& s : transcript_.segments()) {
        vectors.push_back(s.speakerVector);
        frames.push_back(s.speakerFrames);
    }
    std::vector<int> labels = Diarizer::cluster(vectors, frames, config);
    transcript_.relabel(labels);
    return transcript_.speakerCount();
}

}  // namespace va
