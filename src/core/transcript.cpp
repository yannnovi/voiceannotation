#include "core/transcript.h"

#include <algorithm>
#include <cmath>
#include <fstream>

#include "stt/diarizer.h"
#include "util/json.h"

namespace va {
namespace {

std::string pad2(int v) {
    std::string s = std::to_string(v);
    return s.size() < 2 ? "0" + s : s;
}

std::string pad3(int v) {
    std::string s = std::to_string(v);
    while (s.size() < 3) s.insert(s.begin(), '0');
    return s;
}

std::string lowerExtension(const std::string& path) {
    std::size_t dot = path.find_last_of('.');
    std::size_t slash = path.find_last_of("/\\");
    if (dot == std::string::npos) return std::string();
    if (slash != std::string::npos && dot < slash) return std::string();
    std::string ext = path.substr(dot + 1);
    std::transform(ext.begin(), ext.end(), ext.begin(),
                   [](unsigned char c) { return static_cast<char>(std::tolower(c)); });
    return ext;
}

std::string csvField(const std::string& value) {
    bool needsQuotes = value.find_first_of(",\"\n\r") != std::string::npos;
    if (!needsQuotes) return value;
    std::string out = "\"";
    for (char c : value) {
        if (c == '"') out += "\"\"";
        else out.push_back(c);
    }
    out += "\"";
    return out;
}

}  // namespace

void Transcript::clear() {
    segments_.clear();
    names_.clear();
    sourcePath.clear();
    modelPath.clear();
    speakerModelPath.clear();
    audioDuration = 0.0;
    sourceSampleRate = 0;
    sourceChannels = 0;
}

int Transcript::speakerCount() const {
    int highest = -1;
    for (const Segment& s : segments_) highest = std::max(highest, s.speaker);
    return highest + 1;
}

std::string Transcript::speakerName(int speaker) const {
    if (speaker < 0) return unknownLabel_;
    auto it = names_.find(speaker);
    if (it != names_.end() && !it->second.empty()) return it->second;
    return speakerPrefix_ + " " + std::to_string(speaker + 1);
}

void Transcript::setSpeakerName(int speaker, const std::string& name) {
    if (speaker < 0) return;
    if (name.empty()) {
        names_.erase(speaker);
    } else {
        names_[speaker] = name;
    }
}

std::vector<double> Transcript::speakingTime() const {
    std::vector<double> totals(static_cast<std::size_t>(std::max(0, speakerCount())), 0.0);
    for (const Segment& s : segments_) {
        if (s.speaker < 0 || static_cast<std::size_t>(s.speaker) >= totals.size()) continue;
        totals[static_cast<std::size_t>(s.speaker)] += s.duration();
    }
    return totals;
}

void Transcript::relabel(const std::vector<int>& labels) {
    std::size_t count = std::min(labels.size(), segments_.size());
    for (std::size_t i = 0; i < count; ++i) {
        segments_[i].speaker = labels[i];
    }
    // Cluster identities are not stable across runs, so a name kept here would
    // silently end up on the wrong person.
    names_.clear();
}

bool Transcript::setSegmentSpeaker(int segmentIndex, int speaker) {
    if (segmentIndex < 0 || static_cast<std::size_t>(segmentIndex) >= segments_.size()) {
        return false;
    }
    // One past the end is allowed on purpose: it is how the user splits a
    // wrongly merged speaker into a new one.
    if (speaker < kUnknownSpeaker || speaker > speakerCount()) return false;
    segments_[static_cast<std::size_t>(segmentIndex)].speaker = speaker;
    return true;
}

std::string Transcript::timecode(double seconds, bool subtitleStyle) {
    if (!(seconds > 0.0)) seconds = 0.0;
    long long millis = static_cast<long long>(std::llround(seconds * 1000.0));
    int ms = static_cast<int>(millis % 1000);
    long long total = millis / 1000;
    int s = static_cast<int>(total % 60);
    int m = static_cast<int>((total / 60) % 60);
    int h = static_cast<int>(total / 3600);

    if (subtitleStyle) {
        return pad2(h) + ":" + pad2(m) + ":" + pad2(s) + "," + pad3(ms);
    }
    return pad2(h) + ":" + pad2(m) + ":" + pad2(s) + "." + pad3(ms);
}

ExportFormat Transcript::formatForPath(const std::string& path) {
    std::string ext = lowerExtension(path);
    if (ext == "srt") return ExportFormat::Srt;
    if (ext == "vtt") return ExportFormat::Vtt;
    if (ext == "json") return ExportFormat::Json;
    if (ext == "csv") return ExportFormat::Csv;
    return ExportFormat::Text;
}

std::string Transcript::render(ExportFormat format) const {
    std::string out;
    out.reserve(segments_.size() * 96);

    switch (format) {
        case ExportFormat::Text: {
            if (!sourcePath.empty()) out += "# " + sourcePath + "\n\n";
            int previousSpeaker = -2;
            for (const Segment& s : segments_) {
                // Start a new block only when the speaker changes, so a long
                // turn reads as a paragraph instead of a list of fragments.
                if (s.speaker != previousSpeaker) {
                    if (previousSpeaker != -2) out += "\n";
                    out += "[" + timecode(s.start, false) + "] " + speakerName(s.speaker) + ":\n";
                    previousSpeaker = s.speaker;
                }
                out += "  " + s.text + "\n";
            }
            break;
        }

        case ExportFormat::Srt: {
            int index = 1;
            for (const Segment& s : segments_) {
                out += std::to_string(index++) + "\n";
                out += timecode(s.start, true) + " --> " + timecode(s.end, true) + "\n";
                out += speakerName(s.speaker) + ": " + s.text + "\n\n";
            }
            break;
        }

        case ExportFormat::Vtt: {
            out += "WEBVTT\n\n";
            for (const Segment& s : segments_) {
                out += timecode(s.start, false) + " --> " + timecode(s.end, false) + "\n";
                // The <v> cue tag is how WebVTT names a speaker; players that
                // understand it can style each voice differently.
                out += "<v " + speakerName(s.speaker) + ">" + s.text + "\n\n";
            }
            break;
        }

        case ExportFormat::Csv: {
            out += "index,start,end,duration,speaker,text\n";
            int index = 1;
            for (const Segment& s : segments_) {
                out += std::to_string(index++) + ",";
                out += Json::number(s.start, 3) + ",";
                out += Json::number(s.end, 3) + ",";
                out += Json::number(s.duration(), 3) + ",";
                out += csvField(speakerName(s.speaker)) + ",";
                out += csvField(s.text) + "\n";
            }
            break;
        }

        case ExportFormat::Json: {
            out += "{\n";
            out += "  \"source\": \"" + Json::escape(sourcePath) + "\",\n";
            out += "  \"model\": \"" + Json::escape(modelPath) + "\",\n";
            out += "  \"speaker_model\": \"" + Json::escape(speakerModelPath) + "\",\n";
            out += "  \"duration\": " + Json::number(audioDuration, 3) + ",\n";
            out += "  \"sample_rate\": " + std::to_string(sourceSampleRate) + ",\n";
            out += "  \"channels\": " + std::to_string(sourceChannels) + ",\n";

            out += "  \"speakers\": [\n";
            std::vector<double> totals = speakingTime();
            for (std::size_t i = 0; i < totals.size(); ++i) {
                out += "    {\"id\": " + std::to_string(i) + ", \"name\": \"" +
                       Json::escape(speakerName(static_cast<int>(i))) +
                       "\", \"speaking_time\": " + Json::number(totals[i], 3) + "}";
                out += (i + 1 < totals.size()) ? ",\n" : "\n";
            }
            out += "  ],\n";

            out += "  \"segments\": [\n";
            for (std::size_t i = 0; i < segments_.size(); ++i) {
                const Segment& s = segments_[i];
                out += "    {\n";
                out += "      \"start\": " + Json::number(s.start, 3) + ",\n";
                out += "      \"end\": " + Json::number(s.end, 3) + ",\n";
                out += "      \"speaker\": " + std::to_string(s.speaker) + ",\n";
                out += "      \"speaker_name\": \"" + Json::escape(speakerName(s.speaker)) +
                       "\",\n";
                out += "      \"text\": \"" + Json::escape(s.text) + "\",\n";
                out += "      \"words\": [";
                for (std::size_t w = 0; w < s.words.size(); ++w) {
                    const WordTiming& t = s.words[w];
                    out += "\n        {\"word\": \"" + Json::escape(t.word) +
                           "\", \"start\": " + Json::number(t.start, 3) +
                           ", \"end\": " + Json::number(t.end, 3) +
                           ", \"conf\": " + Json::number(t.confidence, 3) + "}";
                    if (w + 1 < s.words.size()) out += ",";
                }
                out += s.words.empty() ? "]\n" : "\n      ]\n";
                out += "    }";
                out += (i + 1 < segments_.size()) ? ",\n" : "\n";
            }
            out += "  ]\n}\n";
            break;
        }
    }
    return out;
}

bool Transcript::save(const std::string& path, ExportFormat format, std::string* error) const {
    // Binary mode keeps line endings identical on every platform: SRT and VTT
    // readers are picky, and a file written on Windows should open unchanged
    // on Linux.
    std::ofstream file(path, std::ios::binary);
    if (!file) {
        if (error) *error = "cannot write to: " + path;
        return false;
    }
    std::string content = render(format);
    file.write(content.data(), static_cast<std::streamsize>(content.size()));
    if (!file) {
        if (error) *error = "write failed: " + path;
        return false;
    }
    return true;
}

}  // namespace va
