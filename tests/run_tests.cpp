// Self-tests for the parts of voiceannotate that can be checked without a
// model, a sound card or a screen: JSON handling, resampling, WAV decoding,
// transcript rendering and speaker clustering.
//
// No test framework, on purpose. The whole point of this project's build is
// that `make` works on three platforms with nothing installed beyond a
// compiler and Tcl/Tk; a test dependency would undo that.
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <fstream>
#include <string>
#include <vector>

#include "audio/audio_source.h"
#include "audio/resampler.h"
#include "audio/wav_reader.h"
#include "core/transcript.h"
#include "stt/diarizer.h"
#include "util/json.h"

namespace {

int gChecks = 0;
int gFailures = 0;
const char* gGroup = "";

void group(const char* name) {
    gGroup = name;
    std::printf("\n%s\n", name);
}

void ok(bool condition, const std::string& what) {
    ++gChecks;
    if (condition) {
        std::printf("  ok    %s\n", what.c_str());
    } else {
        ++gFailures;
        std::printf("  FAIL  %s\n", what.c_str());
    }
}

void equals(const std::string& actual, const std::string& expected, const std::string& what) {
    ++gChecks;
    if (actual == expected) {
        std::printf("  ok    %s\n", what.c_str());
    } else {
        ++gFailures;
        std::printf("  FAIL  %s\n        expected [%s]\n        actual   [%s]\n", what.c_str(),
                    expected.c_str(), actual.c_str());
    }
}

void near(double actual, double expected, double tolerance, const std::string& what) {
    ++gChecks;
    if (std::fabs(actual - expected) <= tolerance) {
        std::printf("  ok    %s\n", what.c_str());
    } else {
        ++gFailures;
        std::printf("  FAIL  %s\n        expected %.6f +/- %.6f, actual %.6f\n", what.c_str(),
                    expected, tolerance, actual);
    }
}

// ---------------------------------------------------------------------------

void testJson() {
    group("JSON");

    // Shaped like what Vosk actually returns, speaker vector included.
    const char* sample =
        "{\"result\":["
        "{\"conf\":0.98,\"end\":1.2,\"start\":0.31,\"word\":\"bonjour\"},"
        "{\"conf\":1.0,\"end\":1.9,\"start\":1.25,\"word\":\"\\u00e9coute\"}],"
        "\"spk\":[0.5,-1.25,3e-2],\"spk_frames\":143,\"text\":\"bonjour \\u00e9coute\"}";

    std::string error;
    va::Json root = va::Json::parse(sample, &error);
    ok(error.empty(), "a Vosk result parses without error");
    equals(root["text"].asString(), "bonjour \xc3\xa9""coute", "\\u escapes decode to UTF-8");
    ok(root["result"].isArray() && root["result"].size() == 2, "the word list has two entries");
    equals(root["result"][0]["word"].asString(), "bonjour", "the first word is readable");
    near(root["result"][1]["start"].asDouble(), 1.25, 1e-9, "word timings survive parsing");
    ok(root["spk"].size() == 3, "the speaker vector keeps its length");
    near(root["spk"][1].asDouble(), -1.25, 1e-9, "negative values parse");
    near(root["spk"][2].asDouble(), 0.03, 1e-9, "exponent notation parses");
    ok(root["spk_frames"].asInt() == 143, "spk_frames reads as an integer");

    // Missing keys must not throw or crash; they read as empty.
    ok(root["nope"].isNull(), "an absent key is null");
    equals(root["nope"]["deeper"].asString("fallback"), "fallback",
           "chaining through an absent key is safe");
    ok(root["result"][99].isNull(), "an out-of-range index is null");

    ok(va::Json::parse("{\"a\":", &error).isNull() && !error.empty(),
       "truncated input reports an error");

    equals(va::Json::escape("a\"b\\c\nd"), "a\\\"b\\\\c\\nd", "escaping covers quote, slash, LF");
    equals(va::Json::escape("caf\xc3\xa9"), "caf\xc3\xa9", "UTF-8 passes through escaping intact");

    // Rendering must not depend on the C locale: a French locale would print
    // "1,500" with printf("%f") and silently corrupt every export.
    equals(va::Json::number(1.5, 3), "1.500", "numbers always use a dot");
    equals(va::Json::number(-0.0004, 3), "0.000", "a value rounding to zero loses its sign");
    equals(va::Json::number(12.0, 0), "12", "zero decimals prints no separator");
    equals(va::Json::number(-3.14159, 2), "-3.14", "negative values round correctly");
}

// ---------------------------------------------------------------------------

void testResampler() {
    group("Resampler");

    // Constant input must come out constant: unity gain is the property the
    // whole filter design hangs on.
    {
        va::Resampler resampler;
        resampler.reset(48000, 1, 16000);
        std::vector<float> input(48000, 0.5f);
        std::vector<std::int16_t> output;
        resampler.process(input.data(), input.size(), &output);
        resampler.flush(&output);

        ok(output.size() > 15000 && output.size() < 17000,
           "48 kHz -> 16 kHz gives about a third of the samples (" +
               std::to_string(output.size()) + ")");
        double sum = 0.0;
        std::size_t from = output.size() / 4;
        std::size_t to = output.size() * 3 / 4;
        for (std::size_t i = from; i < to; ++i) sum += output[i];
        near(sum / static_cast<double>(to - from) / 32767.0, 0.5, 0.002,
             "steady input keeps its level");
    }

    // A 440 Hz tone is well below the 8 kHz output Nyquist, so its energy must
    // survive the conversion.
    {
        va::Resampler resampler;
        resampler.reset(44100, 1, 16000);
        std::vector<float> input(44100);
        for (std::size_t i = 0; i < input.size(); ++i) {
            input[i] = static_cast<float>(0.8 * std::sin(2.0 * 3.14159265358979 * 440.0 *
                                                         static_cast<double>(i) / 44100.0));
        }
        std::vector<std::int16_t> output;
        resampler.process(input.data(), input.size(), &output);
        resampler.flush(&output);

        near(static_cast<double>(output.size()), 16000.0, 200.0,
             "one second in gives one second out");
        double energy = 0.0;
        std::size_t from = output.size() / 8;
        std::size_t to = output.size() * 7 / 8;
        for (std::size_t i = from; i < to; ++i) {
            double v = output[i] / 32767.0;
            energy += v * v;
        }
        double rms = std::sqrt(energy / static_cast<double>(to - from));
        near(rms, 0.8 / std::sqrt(2.0), 0.02, "a 440 Hz tone keeps its RMS level");
    }

    // Stereo must be mixed down, and opposite channels must cancel.
    {
        va::Resampler resampler;
        resampler.reset(16000, 2, 16000);
        std::vector<float> input(2000);
        for (std::size_t f = 0; f < input.size() / 2; ++f) {
            input[f * 2] = 0.7f;
            input[f * 2 + 1] = -0.7f;
        }
        std::vector<std::int16_t> output;
        resampler.process(input.data(), input.size() / 2, &output);
        ok(output.size() == 1000, "stereo collapses to one sample per frame");
        bool silent = true;
        for (std::int16_t s : output) {
            if (std::abs(static_cast<int>(s)) > 2) silent = false;
        }
        ok(silent, "out-of-phase channels cancel to silence");
    }

    // Feeding the same audio in odd-sized pieces must give the same result as
    // one big call, or streaming a real file would differ from a test.
    {
        std::vector<float> input(30000);
        for (std::size_t i = 0; i < input.size(); ++i) {
            input[i] = static_cast<float>(std::sin(static_cast<double>(i) * 0.01));
        }

        va::Resampler whole;
        whole.reset(44100, 1, 16000);
        std::vector<std::int16_t> a;
        whole.process(input.data(), input.size(), &a);
        whole.flush(&a);

        va::Resampler pieces;
        pieces.reset(44100, 1, 16000);
        std::vector<std::int16_t> b;
        std::size_t offset = 0;
        std::size_t chunk = 997;  // deliberately not a round number
        while (offset < input.size()) {
            std::size_t n = std::min(chunk, input.size() - offset);
            pieces.process(input.data() + offset, n, &b);
            offset += n;
        }
        pieces.flush(&b);

        ok(a.size() == b.size(), "chunked input yields the same sample count");
        bool identical = a.size() == b.size();
        for (std::size_t i = 0; identical && i < a.size(); ++i) {
            if (std::abs(static_cast<int>(a[i]) - static_cast<int>(b[i])) > 1) identical = false;
        }
        ok(identical, "chunked input yields the same samples");
    }

    // Values beyond full scale must clamp rather than wrap; a wrapped sample is
    // a loud click, which decoded MP3 would produce regularly.
    {
        va::Resampler resampler;
        resampler.reset(16000, 1, 16000);
        std::vector<float> input(64, 4.0f);
        input[10] = -4.0f;
        std::vector<std::int16_t> output;
        resampler.process(input.data(), input.size(), &output);
        ok(output[0] == 32767, "positive overshoot clamps to the maximum");
        ok(output[10] == -32768, "negative overshoot clamps to the minimum");
    }
}

// ---------------------------------------------------------------------------

void writeUint32(std::ofstream& file, std::uint32_t value) {
    unsigned char bytes[4] = {static_cast<unsigned char>(value & 0xFF),
                              static_cast<unsigned char>((value >> 8) & 0xFF),
                              static_cast<unsigned char>((value >> 16) & 0xFF),
                              static_cast<unsigned char>((value >> 24) & 0xFF)};
    file.write(reinterpret_cast<char*>(bytes), 4);
}

void writeUint16(std::ofstream& file, std::uint16_t value) {
    unsigned char bytes[2] = {static_cast<unsigned char>(value & 0xFF),
                              static_cast<unsigned char>((value >> 8) & 0xFF)};
    file.write(reinterpret_cast<char*>(bytes), 2);
}

// Writes a 16-bit PCM WAV with an extra chunk before "data", which is what
// real recorders produce and a naive reader trips over.
bool writeTestWav(const std::string& path, int sampleRate, int channels,
                  const std::vector<std::int16_t>& samples) {
    std::ofstream file(path, std::ios::binary);
    if (!file) return false;

    std::uint32_t dataBytes = static_cast<std::uint32_t>(samples.size() * 2);
    std::uint32_t listBytes = 12;
    std::uint32_t riffBytes = 4 + (8 + 16) + (8 + listBytes) + (8 + dataBytes);

    file.write("RIFF", 4);
    writeUint32(file, riffBytes);
    file.write("WAVE", 4);

    file.write("fmt ", 4);
    writeUint32(file, 16);
    writeUint16(file, 1);  // PCM
    writeUint16(file, static_cast<std::uint16_t>(channels));
    writeUint32(file, static_cast<std::uint32_t>(sampleRate));
    writeUint32(file, static_cast<std::uint32_t>(sampleRate * channels * 2));
    writeUint16(file, static_cast<std::uint16_t>(channels * 2));
    writeUint16(file, 16);

    file.write("LIST", 4);
    writeUint32(file, listBytes);
    file.write("INFOISFT", 8);
    writeUint32(file, 0);

    file.write("data", 4);
    writeUint32(file, dataBytes);
    for (std::int16_t s : samples) writeUint16(file, static_cast<std::uint16_t>(s));
    return static_cast<bool>(file);
}

void testWav() {
    group("WAV reader");

    const std::string path = "build/test-tone.wav";
    std::vector<std::int16_t> samples(8000 * 2);
    for (std::size_t f = 0; f < 8000; ++f) {
        samples[f * 2] = static_cast<std::int16_t>(1000);
        samples[f * 2 + 1] = static_cast<std::int16_t>(-1000);
    }
    if (!writeTestWav(path, 8000, 2, samples)) {
        ok(false, "the test WAV could be written (is build/ present?)");
        return;
    }

    std::string error;
    std::unique_ptr<va::AudioSource> source = va::openAudioFile(path, &error);
    ok(source != nullptr, "openAudioFile recognises a WAV by its header: " + error);
    if (!source) return;

    equals(source->formatName(), "WAV", "the container is reported as WAV");

    std::vector<float> block;
    std::size_t total = 0;
    std::size_t frames = 0;
    double firstSample = 0.0;
    while ((frames = source->read(&block, 1024)) > 0) {
        if (total == 0 && !block.empty()) firstSample = block[0];
        total += frames;
    }
    ok(total == 8000, "every frame is read back (" + std::to_string(total) + ")");
    ok(source->format().sampleRate == 8000, "the sample rate comes from the fmt chunk");
    ok(source->format().channels == 2, "the channel count comes from the fmt chunk");
    near(firstSample, 1000.0 / 32768.0, 1e-4, "16-bit samples scale into -1..1");
    near(source->estimatedDuration(), 1.0, 0.01, "the duration is one second");
    near(source->progress(), 1.0, 1e-6, "progress reaches 1 at the end");

    std::remove(path.c_str());

    std::unique_ptr<va::AudioSource> missing = va::openAudioFile("build/not-here.xyz", &error);
    ok(missing == nullptr && !error.empty(), "an unknown format is refused with a message");
}

// ---------------------------------------------------------------------------

void testTranscript() {
    group("Transcript");

    equals(va::Transcript::timecode(0.0, false), "00:00:00.000", "zero formats fully padded");
    equals(va::Transcript::timecode(3723.456, false), "01:02:03.456", "hours, minutes, millis");
    equals(va::Transcript::timecode(3723.456, true), "01:02:03,456", "SRT uses a comma");
    equals(va::Transcript::timecode(-5.0, false), "00:00:00.000", "negative time clamps to zero");

    va::Transcript transcript;
    transcript.setSpeakerPrefix("Locuteur");
    transcript.setUnknownLabel("Inconnu");
    transcript.sourcePath = "entretien.mp3";

    va::Segment first;
    first.start = 0.5;
    first.end = 2.5;
    first.text = "bonjour, merci d'etre la";
    first.speaker = 0;
    transcript.add(first);

    va::Segment second;
    second.start = 2.8;
    second.end = 5.0;
    second.text = "avec plaisir";
    second.speaker = 1;
    transcript.add(second);

    va::Segment third;
    third.start = 5.2;
    third.end = 6.0;
    third.text = "commencons";
    third.speaker = -1;
    transcript.add(third);

    equals(transcript.speakerName(0), "Locuteur 1", "speakers are numbered from one for readers");
    equals(transcript.speakerName(-1), "Inconnu", "an unassigned segment has its own label");
    ok(transcript.speakerCount() == 2, "the speaker count ignores unassigned segments");

    transcript.setSpeakerName(1, "Marie");
    equals(transcript.speakerName(1), "Marie", "a custom name wins over the default");
    transcript.setSpeakerName(1, "");
    equals(transcript.speakerName(1), "Locuteur 2", "clearing a name restores the default");
    transcript.setSpeakerName(1, "Marie");

    std::vector<double> totals = transcript.speakingTime();
    near(totals[0], 2.0, 1e-9, "speaking time adds up per speaker");

    std::string srt = transcript.render(va::ExportFormat::Srt);
    ok(srt.find("00:00:00,500 --> 00:00:02,500") != std::string::npos,
       "SRT carries comma timecodes");
    ok(srt.find("Marie: avec plaisir") != std::string::npos, "SRT prefixes the speaker name");
    ok(srt.find("Inconnu: commencons") != std::string::npos, "SRT labels unknown speakers");

    std::string vtt = transcript.render(va::ExportFormat::Vtt);
    ok(vtt.compare(0, 6, "WEBVTT") == 0, "VTT starts with its signature");
    ok(vtt.find("<v Marie>") != std::string::npos, "VTT uses the voice cue tag");

    std::string csv = transcript.render(va::ExportFormat::Csv);
    ok(csv.find("index,start,end,duration,speaker,text") == 0, "CSV has a header row");
    ok(csv.find("1,0.500,2.500,2.000,Locuteur 1,\"bonjour, merci d'etre la\"") !=
           std::string::npos,
       "a text containing a comma is quoted");

    std::string json = transcript.render(va::ExportFormat::Json);
    std::string error;
    va::Json parsed = va::Json::parse(json, &error);
    ok(error.empty(), "the JSON export re-parses cleanly: " + error);
    ok(parsed["segments"].size() == 3, "every segment is exported");
    equals(parsed["segments"][1]["speaker_name"].asString(), "Marie",
           "the JSON export carries the speaker name");
    equals(parsed["source"].asString(), "entretien.mp3", "the source file is recorded");

    std::string text = transcript.render(va::ExportFormat::Text);
    ok(text.find("[00:00:00.500] Locuteur 1:") != std::string::npos,
       "the text export heads each turn with a timecode");

    ok(transcript.setSegmentSpeaker(2, 1), "a segment can be reassigned by hand");
    ok(transcript.segments()[2].speaker == 1, "the reassignment sticks");
    ok(transcript.setSegmentSpeaker(0, transcript.speakerCount()),
       "assigning one past the end opens a new speaker");
    ok(!transcript.setSegmentSpeaker(99, 0), "an out-of-range segment is refused");
    ok(!transcript.setSegmentSpeaker(0, 99), "an out-of-range speaker is refused");

    equals(std::to_string(static_cast<int>(va::Transcript::formatForPath("a/b.srt"))),
           std::to_string(static_cast<int>(va::ExportFormat::Srt)),
           "the format is taken from the extension");
    equals(std::to_string(static_cast<int>(va::Transcript::formatForPath("a.dir/b"))),
           std::to_string(static_cast<int>(va::ExportFormat::Text)),
           "a dot in a directory name is not an extension");
}

// ---------------------------------------------------------------------------

// Builds a 128-dimension embedding around `axis`, with a repeatable wobble so
// the test never flickers.
std::vector<float> embedding(int axis, double wobble, int seed) {
    std::vector<float> v(128, 0.0f);
    v[static_cast<std::size_t>(axis)] = 1.0f;
    for (int i = 0; i < 128; ++i) {
        double noise = std::sin(static_cast<double>(seed * 7 + i * 13)) * wobble;
        v[static_cast<std::size_t>(i)] += static_cast<float>(noise);
    }
    return v;
}

void testDiarizer() {
    group("Diarizer");

    near(va::Diarizer::similarity({1.0f, 0.0f}, {1.0f, 0.0f}), 1.0, 1e-6,
         "identical vectors score 1");
    near(va::Diarizer::similarity({1.0f, 0.0f}, {0.0f, 1.0f}), 0.0, 1e-6,
         "orthogonal vectors score 0");
    near(va::Diarizer::similarity({1.0f, 0.0f}, {}), 0.0, 1e-9, "an empty vector scores 0");
    near(va::Diarizer::similarity({0.0f, 0.0f}, {1.0f, 0.0f}), 0.0, 1e-9,
         "a zero vector scores 0 rather than dividing by zero");

    // Two people alternating, six turns each.
    std::vector<std::vector<float>> vectors;
    std::vector<int> frames;
    for (int i = 0; i < 12; ++i) {
        vectors.push_back(embedding(i % 2, 0.05, i));
        frames.push_back(120);
    }

    va::DiarizerConfig config;
    config.threshold = 0.55;
    config.minFrames = 40;

    std::vector<int> labels = va::Diarizer::cluster(vectors, frames, config);
    int distinct = 0;
    for (int label : labels) distinct = std::max(distinct, label + 1);
    ok(distinct == 2, "two alternating voices cluster into two speakers (" +
                          std::to_string(distinct) + ")");
    ok(labels[0] == 0, "the first voice heard becomes speaker 0");
    ok(labels[1] == 1, "the second voice heard becomes speaker 1");
    bool consistent = true;
    for (std::size_t i = 0; i < labels.size(); ++i) {
        if (labels[i] != labels[i % 2]) consistent = false;
    }
    ok(consistent, "every turn lands with the right speaker");

    // A threshold of 1 can never be met, so nothing merges.
    va::DiarizerConfig strict = config;
    strict.threshold = 1.01;
    std::vector<int> split = va::Diarizer::cluster(vectors, frames, strict);
    int splitCount = 0;
    for (int label : split) splitCount = std::max(splitCount, label + 1);
    ok(splitCount == 12, "an unreachable threshold leaves every segment on its own");

    // A cap must be honoured even when the threshold would stop earlier.
    va::DiarizerConfig capped = strict;
    capped.maxSpeakers = 3;
    std::vector<int> limited = va::Diarizer::cluster(vectors, frames, capped);
    int limitedCount = 0;
    for (int label : limited) limitedCount = std::max(limitedCount, label + 1);
    ok(limitedCount <= 3, "the speaker cap overrides the threshold (" +
                              std::to_string(limitedCount) + ")");

    // Segments with no embedding stay unknown; short ones get attached.
    std::vector<std::vector<float>> mixed = vectors;
    std::vector<int> mixedFrames = frames;
    mixed.push_back({});
    mixedFrames.push_back(0);
    mixed.push_back(embedding(0, 0.05, 99));
    mixedFrames.push_back(5);  // below minFrames

    std::vector<int> mixedLabels = va::Diarizer::cluster(mixed, mixedFrames, config);
    ok(mixedLabels[12] == va::kUnknownSpeaker, "a segment with no embedding stays unknown");
    ok(mixedLabels[13] == 0, "a short segment is attached to its nearest speaker");

    // The online path has to agree with the offline one on easy material,
    // because that is what the user watches during a run.
    va::Diarizer online;
    online.configure(config);
    std::vector<int> live;
    for (std::size_t i = 0; i < vectors.size(); ++i) {
        live.push_back(online.assign(vectors[i], frames[i]));
    }
    ok(online.speakerCount() == 2, "online clustering also finds two speakers");
    ok(live[0] != live[1], "online clustering separates the two voices");
    ok(live[0] == live[2] && live[1] == live[3], "online labels stay stable across turns");

    va::Diarizer empty;
    empty.configure(config);
    ok(empty.assign({}, 100) == va::kUnknownSpeaker, "an empty embedding yields no speaker");

    // Centring on the recording mean: two voices buried under a large shared
    // component, which is what a microphone and a room contribute to every
    // embedding in a recording. Without removing it the two look nearly
    // identical and merge; with it removed they separate cleanly.
    {
        std::vector<std::vector<float>> biased;
        std::vector<int> biasedFrames;
        for (int i = 0; i < 8; ++i) {
            std::vector<float> v(128, 0.35f);  // the shared channel component
            v[static_cast<std::size_t>(i % 2)] += 0.30f;
            for (int k = 0; k < 128; ++k) {
                v[static_cast<std::size_t>(k)] +=
                    static_cast<float>(std::sin(static_cast<double>(i * 11 + k * 5)) * 0.01);
            }
            biased.push_back(v);
            biasedFrames.push_back(150);
        }

        va::DiarizerConfig centred;
        centred.threshold = 0.55;
        centred.minFrames = 40;
        centred.centerOnRecordingMean = true;

        va::DiarizerConfig raw = centred;
        raw.centerOnRecordingMean = false;

        auto countSpeakers = [](const std::vector<int>& labels) {
            int highest = 0;
            for (int label : labels) highest = std::max(highest, label + 1);
            return highest;
        };

        int withCentring = countSpeakers(va::Diarizer::cluster(biased, biasedFrames, centred));
        int without = countSpeakers(va::Diarizer::cluster(biased, biasedFrames, raw));

        ok(without == 1, "a shared channel component hides the two voices (" +
                             std::to_string(without) + " found)");
        ok(withCentring == 2, "centring on the recording mean recovers them (" +
                                  std::to_string(withCentring) + " found)");
    }
}

}  // namespace

int main() {
    std::printf("voiceannotate self-tests\n");

    testJson();
    testResampler();
    testWav();
    testTranscript();
    testDiarizer();

    std::printf("\n%d checks, %d failure(s)\n", gChecks, gFailures);
    return gFailures == 0 ? 0 : 1;
}
