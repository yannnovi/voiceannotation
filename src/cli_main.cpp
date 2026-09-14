// Command-line front end: same pipeline, no Tcl and no Tk.
//
// It exists so the engine can be exercised on a headless machine -- a CI
// runner, a server, an SSH session -- and so a bug can be pinned to the core
// or to the GUI without guessing.
#include <chrono>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <thread>
#include <vector>

#include "core/pipeline.h"
#include "core/transcript.h"
#include "stt/vosk_engine.h"

namespace {

void usage(const char* program) {
    std::printf(
        "Usage: %s [options] <audio-file>\n"
        "\n"
        "Transcribes an MP3 or WAV file and annotates who is speaking.\n"
        "\n"
        "Options:\n"
        "  -m, --model DIR         recognition model directory (required)\n"
        "  -s, --spk-model DIR     speaker model directory; without it every\n"
        "                          segment is attributed to one speaker\n"
        "  -o, --output FILE       write here instead of standard output\n"
        "  -f, --format FMT        txt (default), srt, vtt, json or csv\n"
        "  -t, --threshold F       speaker similarity cutoff (default 0.05)\n"
        "                          higher splits speakers, lower merges them;\n"
        "                          the useful range is about -0.2 to 0.4\n"
        "      --min-frames N      frames an embedding needs to define a\n"
        "                          speaker, 1 frame = 10 ms (default 40)\n"
        "      --max-speakers N    force at most N speakers (default: no limit)\n"
        "      --speaker-prefix S  label for unnamed speakers (default Speaker)\n"
        "  -v, --verbose           show Vosk's own log output\n"
        "  -q, --quiet             no progress reporting\n"
        "  -h, --help              this text\n"
        "\n"
        "Environment:\n"
        "  VOSK_MODEL, VOSK_SPK_MODEL supply the defaults for --model/--spk-model.\n",
        program);
}

bool needsValue(int i, int argc, const char* option) {
    if (i + 1 < argc) return true;
    std::fprintf(stderr, "error: %s needs a value\n", option);
    return false;
}

std::string environmentOr(const char* name, const std::string& fallback) {
    const char* value = std::getenv(name);
    return value && *value ? std::string(value) : fallback;
}

const char* formatName(va::ExportFormat format) {
    switch (format) {
        case va::ExportFormat::Srt: return "srt";
        case va::ExportFormat::Vtt: return "vtt";
        case va::ExportFormat::Json: return "json";
        case va::ExportFormat::Csv: return "csv";
        case va::ExportFormat::Text: break;
    }
    return "txt";
}

}  // namespace

int main(int argc, char** argv) {
    va::PipelineConfig config;
    std::string outputPath;
    std::string speakerPrefix = "Speaker";
    va::ExportFormat format = va::ExportFormat::Text;
    bool formatGiven = false;
    bool quiet = false;
    bool verbose = false;

    config.modelPath = environmentOr("VOSK_MODEL", "");
    config.speakerModelPath = environmentOr("VOSK_SPK_MODEL", "");

    for (int i = 1; i < argc; ++i) {
        std::string arg = argv[i];
        auto is = [&arg](const char* shortName, const char* longName) {
            return arg == shortName || arg == longName;
        };

        if (is("-h", "--help")) {
            usage(argv[0]);
            return 0;
        } else if (is("-m", "--model")) {
            if (!needsValue(i, argc, argv[i])) return 2;
            config.modelPath = argv[++i];
        } else if (is("-s", "--spk-model")) {
            if (!needsValue(i, argc, argv[i])) return 2;
            config.speakerModelPath = argv[++i];
        } else if (is("-o", "--output")) {
            if (!needsValue(i, argc, argv[i])) return 2;
            outputPath = argv[++i];
        } else if (is("-f", "--format")) {
            if (!needsValue(i, argc, argv[i])) return 2;
            std::string name = argv[++i];
            if (name == "txt" || name == "text") format = va::ExportFormat::Text;
            else if (name == "srt") format = va::ExportFormat::Srt;
            else if (name == "vtt") format = va::ExportFormat::Vtt;
            else if (name == "json") format = va::ExportFormat::Json;
            else if (name == "csv") format = va::ExportFormat::Csv;
            else {
                std::fprintf(stderr, "error: unknown format '%s'\n", name.c_str());
                return 2;
            }
            formatGiven = true;
        } else if (is("-t", "--threshold")) {
            if (!needsValue(i, argc, argv[i])) return 2;
            config.diarizer.threshold = std::atof(argv[++i]);
        } else if (arg == "--min-frames") {
            if (!needsValue(i, argc, argv[i])) return 2;
            config.diarizer.minFrames = std::atoi(argv[++i]);
        } else if (arg == "--max-speakers") {
            if (!needsValue(i, argc, argv[i])) return 2;
            config.diarizer.maxSpeakers = std::atoi(argv[++i]);
        } else if (arg == "--speaker-prefix") {
            if (!needsValue(i, argc, argv[i])) return 2;
            speakerPrefix = argv[++i];
        } else if (is("-q", "--quiet")) {
            quiet = true;
        } else if (is("-v", "--verbose")) {
            verbose = true;
        } else if (!arg.empty() && arg[0] == '-' && arg != "-") {
            std::fprintf(stderr, "error: unknown option '%s'\n", arg.c_str());
            return 2;
        } else {
            if (!config.audioPath.empty()) {
                std::fprintf(stderr, "error: only one audio file at a time\n");
                return 2;
            }
            config.audioPath = arg;
        }
    }

    if (config.audioPath.empty()) {
        usage(argv[0]);
        return 2;
    }
    if (config.modelPath.empty()) {
        std::fprintf(stderr,
                     "error: no recognition model. Pass --model DIR or set VOSK_MODEL.\n"
                     "       'make models' downloads one into ./models.\n");
        return 2;
    }
    if (!formatGiven && !outputPath.empty()) {
        format = va::Transcript::formatForPath(outputPath);
    }

    // Vosk is chatty at its default level and would drown the progress line.
    va::VoskEngine::setLogLevel(verbose ? 0 : -1);

    va::Pipeline pipeline;
    pipeline.transcript().setSpeakerPrefix(speakerPrefix);

    std::string error;
    if (!pipeline.start(config, &error)) {
        std::fprintf(stderr, "error: %s\n", error.c_str());
        return 1;
    }

    bool failed = false;
    bool finished = false;
    int segments = 0;
    while (!finished) {
        std::vector<va::Event> events = pipeline.drain();
        if (events.empty()) {
            std::this_thread::sleep_for(std::chrono::milliseconds(40));
            continue;
        }
        for (const va::Event& e : events) {
            switch (e.type) {
                case va::EventType::Status:
                    if (!quiet) std::fprintf(stderr, "%s\n", e.message.c_str());
                    break;
                case va::EventType::Segment:
                    ++segments;
                    break;
                case va::EventType::Progress:
                    if (!quiet) {
                        // \r keeps the progress on one line; the newline comes
                        // when the run ends.
                        std::fprintf(stderr, "\r  %5.1f%%  %s  %d segments  %.1fx realtime   ",
                                     e.fraction * 100.0,
                                     va::Transcript::timecode(e.audioPosition, false).c_str(),
                                     segments, e.speed);
                        std::fflush(stderr);
                    }
                    break;
                case va::EventType::Failed:
                    if (!quiet) std::fprintf(stderr, "\n");
                    std::fprintf(stderr, "error: %s\n", e.message.c_str());
                    failed = true;
                    finished = true;
                    break;
                case va::EventType::Finished:
                    if (!quiet) {
                        std::fprintf(stderr, "\r  %5.1f%%  %s  %d segments  %.1fx realtime   \n",
                                     100.0,
                                     va::Transcript::timecode(e.audioPosition, false).c_str(),
                                     segments, e.speed);
                        std::fprintf(stderr, "%d speaker(s) over %d segment(s) in %.1fs\n",
                                     pipeline.transcript().speakerCount(), segments, e.elapsed);
                    }
                    finished = true;
                    break;
            }
        }
    }
    pipeline.wait();

    if (failed) return 1;

    if (outputPath.empty()) {
        std::string rendered = pipeline.transcript().render(format);
        std::fwrite(rendered.data(), 1, rendered.size(), stdout);
    } else if (!pipeline.transcript().save(outputPath, format, &error)) {
        std::fprintf(stderr, "error: %s\n", error.c_str());
        return 1;
    } else if (!quiet) {
        std::fprintf(stderr, "wrote %s (%s)\n", outputPath.c_str(), formatName(format));
    }
    return 0;
}
