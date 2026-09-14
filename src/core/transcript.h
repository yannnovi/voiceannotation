// The annotated transcript: what the recogniser heard, when, and from whom.
//
// Segments keep their speaker embedding after recognition finishes. That is
// deliberate -- it is what lets the user move the sensitivity slider and get a
// new speaker grouping instantly, without touching the audio again.
#ifndef VA_CORE_TRANSCRIPT_H
#define VA_CORE_TRANSCRIPT_H

#include <map>
#include <string>
#include <vector>

#include "stt/vosk_engine.h"

namespace va {

struct Segment {
    double start = 0.0;
    double end = 0.0;
    std::string text;
    std::vector<WordTiming> words;

    std::vector<float> speakerVector;  // kept for re-clustering
    int speakerFrames = 0;
    int speaker = -1;  // index into the speaker table, or -1 when unknown

    double duration() const { return end > start ? end - start : 0.0; }
};

enum class ExportFormat { Text, Srt, Vtt, Json, Csv };

class Transcript {
public:
    void clear();

    void add(const Segment& segment) { segments_.push_back(segment); }
    const std::vector<Segment>& segments() const { return segments_; }
    std::vector<Segment>& segments() { return segments_; }
    bool empty() const { return segments_.empty(); }

    // --- speakers --------------------------------------------------------
    int speakerCount() const;

    // Display name: the user's own label if they set one, otherwise
    // "<prefix> N". The prefix is injected by the UI so the C++ core carries no
    // user-facing wording of its own.
    std::string speakerName(int speaker) const;
    void setSpeakerName(int speaker, const std::string& name);
    void setSpeakerPrefix(const std::string& prefix) { speakerPrefix_ = prefix; }
    const std::string& speakerPrefix() const { return speakerPrefix_; }
    void setUnknownLabel(const std::string& label) { unknownLabel_ = label; }

    // How much speech each speaker accounts for, indexed by speaker.
    std::vector<double> speakingTime() const;

    // Applies fresh labels (one per segment). Custom names are dropped: after
    // re-clustering, speaker 2 is not necessarily the person speaker 2 was.
    void relabel(const std::vector<int>& labels);

    // Manual correction of a single segment. `speaker` may be one past the
    // current highest index, which opens a new speaker. Returns false when the
    // segment index or the speaker index is out of range.
    bool setSegmentSpeaker(int segmentIndex, int speaker);

    // --- metadata --------------------------------------------------------
    std::string sourcePath;
    std::string modelPath;
    std::string speakerModelPath;
    double audioDuration = 0.0;   // seconds, 0 when unknown
    int sourceSampleRate = 0;
    int sourceChannels = 0;

    // --- export ----------------------------------------------------------
    std::string render(ExportFormat format) const;
    bool save(const std::string& path, ExportFormat format, std::string* error) const;

    // Picks a format from a file extension, defaulting to Text.
    static ExportFormat formatForPath(const std::string& path);

    // "1:02:03.450" (or "01:02:03,450" in the SRT dialect).
    static std::string timecode(double seconds, bool subtitleStyle);

private:
    std::vector<Segment> segments_;
    std::map<int, std::string> names_;
    std::string speakerPrefix_ = "Speaker";
    std::string unknownLabel_ = "Unknown";
};

}  // namespace va

#endif  // VA_CORE_TRANSCRIPT_H
