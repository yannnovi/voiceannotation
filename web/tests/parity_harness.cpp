// What the C++ core produces for a fixed, generated transcript: the speaker
// labels at a spread of settings, and all five export formats.
//
// web/tests/parity.py builds the same fixture from the same generator and
// prints the same report; the two outputs are diffed. See that file for why
// the numbers are multiples of 1/1024.
#include <cstdio>
#include <string>
#include <vector>
#include "core/transcript.h"
#include "stt/diarizer.h"

static unsigned long long g = 88172645463325252ULL;
static int rnd(int modulus) {
    g ^= g << 13; g ^= g >> 7; g ^= g << 17;
    return (int)(g % (unsigned long long)modulus);
}

int main() {
    const int kSpeakers = 3, kDim = 16, kSegments = 40;
    std::vector<std::vector<float>> bases(kSpeakers, std::vector<float>(kDim));
    for (int s = 0; s < kSpeakers; ++s)
        for (int d = 0; d < kDim; ++d) bases[s][d] = (float)(rnd(2049) - 1024) / 1024.0f;

    va::Transcript t;
    t.sourcePath = "entretien \"a\".mp3";
    t.modelPath = "models/m";
    t.speakerModelPath = "models/spk";
    t.audioDuration = 123.4567;
    t.sourceSampleRate = 44100;
    t.sourceChannels = 2;

    std::vector<std::vector<float>> vectors;
    std::vector<int> frames;
    for (int i = 0; i < kSegments; ++i) {
        va::Segment seg;
        seg.start = (double)(i * 3137) / 1000.0;
        seg.end = seg.start + 1.0 + (double)rnd(2000) / 1000.0;
        seg.text = (i % 7 == 0) ? "un \"mot\", et\tune virgule" : "bonjour et merci d'etre venu";
        int who = i % kSpeakers;
        seg.speakerVector.resize(kDim);
        for (int d = 0; d < kDim; ++d)
            seg.speakerVector[d] = bases[who][d] + (float)(rnd(513) - 256) / 1024.0f;
        seg.speakerFrames = (i % 9 == 0) ? 12 : 40 + i;
        va::WordTiming w;
        w.word = "bonjour"; w.start = seg.start; w.end = seg.start + 0.4; w.confidence = 0.87;
        seg.words.push_back(w);
        w.word = "merci"; w.start = seg.start + 0.5; w.end = seg.start + 0.9; w.confidence = 0.5;
        seg.words.push_back(w);
        t.add(seg);
        vectors.push_back(seg.speakerVector);
        frames.push_back(seg.speakerFrames);
    }

    const double thresholds[] = {-0.10, 0.0, 0.05, 0.20, 0.35};
    const int minFrames[] = {5, 40, 100};
    const int maxSpeakers[] = {0, 2, 4};
    for (double th : thresholds) for (int mf : minFrames) for (int ms : maxSpeakers) {
        va::DiarizerConfig c; c.threshold = th; c.minFrames = mf; c.maxSpeakers = ms;
        std::vector<int> labels = va::Diarizer::cluster(vectors, frames, c);
        std::printf("LABELS %.2f %d %d:", th, mf, ms);
        for (int l : labels) std::printf(" %d", l);
        std::printf("\n");
    }

    va::DiarizerConfig c;
    t.relabel(va::Diarizer::cluster(vectors, frames, c));
    t.setSpeakerName(0, "Alice \"la\" Brune");
    t.setSegmentSpeaker(3, t.speakerCount());

    const char* names[] = {"txt", "srt", "vtt", "csv", "json"};
    va::ExportFormat formats[] = {va::ExportFormat::Text, va::ExportFormat::Srt,
                                  va::ExportFormat::Vtt, va::ExportFormat::Csv,
                                  va::ExportFormat::Json};
    for (int i = 0; i < 5; ++i) {
        std::printf("===== %s =====\n", names[i]);
        std::string out = t.render(formats[i]);
        std::fwrite(out.data(), 1, out.size(), stdout);
    }
    std::printf("===== end =====\n");
    return 0;
}
