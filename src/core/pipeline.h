// Runs decode -> resample -> recognise -> diarise on a worker thread and
// reports back through a polled event queue.
//
// The queue is the whole point. Tcl interpreters are not thread safe, and
// calling into one from a worker is the classic way to get a crash that only
// happens on someone else's machine. Instead the worker only ever appends to a
// mutex-protected vector, and the UI thread drains it from a timer. No Tcl
// threading extension, no platform event injection, nothing to port.
#ifndef VA_CORE_PIPELINE_H
#define VA_CORE_PIPELINE_H

#include <atomic>
#include <mutex>
#include <string>
#include <thread>
#include <vector>

#include "core/transcript.h"
#include "stt/diarizer.h"
#include "stt/vosk_engine.h"

namespace va {

enum class EventType {
    Status,    // human-readable note about what the worker is doing
    Progress,  // position within the file
    Segment,   // one recognised, speaker-tagged segment
    Finished,  // the run completed (possibly cancelled) -- see `cancelled`
    Failed,    // the run stopped on an error -- see `message`
};

struct Event {
    EventType type = EventType::Status;
    std::string message;

    // Progress
    double fraction = 0.0;       // 0..1
    double audioPosition = 0.0;  // seconds of audio consumed
    double duration = 0.0;       // seconds, 0 when unknown
    double elapsed = 0.0;        // wall-clock seconds since the run started
    double speed = 0.0;          // audio seconds processed per wall second

    // Segment
    Segment segment;
    int segmentIndex = 0;

    // Finished
    bool cancelled = false;
    bool relabelled = false;  // the final clustering changed speaker labels
};

struct PipelineConfig {
    std::string audioPath;
    std::string modelPath;
    std::string speakerModelPath;  // optional
    DiarizerConfig diarizer;
};

class Pipeline {
public:
    Pipeline() = default;
    ~Pipeline();

    Pipeline(const Pipeline&) = delete;
    Pipeline& operator=(const Pipeline&) = delete;

    // Spawns the worker. Fails immediately only on argument problems; anything
    // discovered later arrives as a Failed event.
    bool start(const PipelineConfig& config, std::string* error);

    // Asks the worker to stop at the next chunk boundary. Non-blocking; the
    // worker still emits Finished with `cancelled` set.
    void cancel();

    bool running() const { return running_.load(); }

    // Takes every event queued since the last call. Safe from the UI thread.
    std::vector<Event> drain();

    // Joins the worker. Call after Finished/Failed before touching transcript().
    void wait();

    // Valid once the run has finished.
    Transcript& transcript() { return transcript_; }
    const Transcript& transcript() const { return transcript_; }

    // Re-groups speakers from the stored embeddings with new settings.
    // Cheap: no audio is touched. Returns the resulting speaker count.
    int recluster(const DiarizerConfig& config);

private:
    std::thread worker_;
    std::atomic<bool> running_{false};
    std::atomic<bool> cancelRequested_{false};

    std::mutex queueMutex_;
    std::vector<Event> queue_;

    // Models are expensive to load, so the engine outlives a single run and is
    // reused when the next file asks for the same model directories.
    VoskEngine engine_;
    std::string loadedModel_;
    std::string loadedSpeakerModel_;

    Transcript transcript_;

    void push(Event event);
    void pushStatus(const std::string& message);
    void run(PipelineConfig config);
};

}  // namespace va

#endif  // VA_CORE_PIPELINE_H
