#include "stt/diarizer.h"

#include <algorithm>
#include <cmath>
#include <map>

namespace va {
namespace {

// Above this many embeddings the similarity matrix stops being worth its
// memory (n^2 floats), and clustering falls back to the online strategy. At
// roughly one utterance every few seconds this is several hours of audio.
constexpr std::size_t kMaxMatrixItems = 3000;

std::vector<float> normalized(const std::vector<float>& v) {
    double norm = 0.0;
    for (float x : v) norm += static_cast<double>(x) * x;
    norm = std::sqrt(norm);
    if (norm < 1e-12) return std::vector<float>(v.size(), 0.0f);
    std::vector<float> out(v.size());
    for (std::size_t i = 0; i < v.size(); ++i) {
        out[i] = static_cast<float>(v[i] / norm);
    }
    return out;
}

double dot(const std::vector<float>& a, const std::vector<float>& b) {
    std::size_t n = std::min(a.size(), b.size());
    double sum = 0.0;
    for (std::size_t i = 0; i < n; ++i) sum += static_cast<double>(a[i]) * b[i];
    return sum;
}

// Renumbers labels so that speaker 0 is the first to be heard. Without this
// the numbering would follow clustering order, which means nothing to a reader
// scanning the transcript top to bottom.
void renumberByFirstAppearance(std::vector<int>* labels) {
    std::map<int, int> mapping;
    int next = 0;
    for (int& label : *labels) {
        if (label == kUnknownSpeaker) continue;
        auto it = mapping.find(label);
        if (it == mapping.end()) {
            it = mapping.emplace(label, next++).first;
        }
        label = it->second;
    }
}

}  // namespace

void Diarizer::reset() {
    centroids_.clear();
    weights_.clear();
}

double Diarizer::similarity(const std::vector<float>& a, const std::vector<float>& b) {
    if (a.empty() || b.empty()) return 0.0;
    double na = std::sqrt(dot(a, a));
    double nb = std::sqrt(dot(b, b));
    if (na < 1e-12 || nb < 1e-12) return 0.0;
    return dot(a, b) / (na * nb);
}

int Diarizer::assign(const std::vector<float>& vector, int frames) {
    if (vector.empty()) return kUnknownSpeaker;
    std::vector<float> unit = normalized(vector);

    int best = -1;
    double bestSim = -2.0;
    for (std::size_t i = 0; i < centroids_.size(); ++i) {
        double sim = dot(unit, centroids_[i]);
        if (sim > bestSim) {
            bestSim = sim;
            best = static_cast<int>(i);
        }
    }

    bool reliable = frames >= config_.minFrames;
    bool atCapacity = config_.maxSpeakers > 0 &&
                      static_cast<int>(centroids_.size()) >= config_.maxSpeakers;

    // A short, noisy embedding gets the nearest label but is not allowed to
    // open a new speaker or drag an existing centroid around.
    if (best >= 0 && (bestSim >= config_.threshold || !reliable || atCapacity)) {
        if (reliable) {
            double w = static_cast<double>(frames);
            double total = weights_[static_cast<std::size_t>(best)] + w;
            std::vector<float>& c = centroids_[static_cast<std::size_t>(best)];
            for (std::size_t i = 0; i < c.size() && i < unit.size(); ++i) {
                c[i] = static_cast<float>(
                    (c[i] * weights_[static_cast<std::size_t>(best)] + unit[i] * w) / total);
            }
            centroids_[static_cast<std::size_t>(best)] = normalized(c);
            weights_[static_cast<std::size_t>(best)] = total;
        }
        return best;
    }

    if (!reliable) return best >= 0 ? best : kUnknownSpeaker;

    centroids_.push_back(unit);
    weights_.push_back(static_cast<double>(frames));
    return static_cast<int>(centroids_.size()) - 1;
}

std::vector<int> Diarizer::cluster(const std::vector<std::vector<float>>& vectors,
                                   const std::vector<int>& frames,
                                   const DiarizerConfig& config) {
    std::vector<int> labels(vectors.size(), kUnknownSpeaker);

    // Only embeddings backed by enough audio drive the clustering; the rest are
    // attached afterwards to whichever cluster they land nearest.
    std::vector<std::size_t> strong;
    std::vector<std::size_t> weak;
    for (std::size_t i = 0; i < vectors.size(); ++i) {
        if (vectors[i].empty()) continue;
        int f = i < frames.size() ? frames[i] : 0;
        if (f >= config.minFrames) {
            strong.push_back(i);
        } else {
            weak.push_back(i);
        }
    }
    // If nothing clears the bar, cluster on what there is rather than give up.
    if (strong.empty()) {
        strong.swap(weak);
    }
    if (strong.empty()) return labels;

    std::size_t n = strong.size();

    if (n > kMaxMatrixItems) {
        Diarizer online;
        online.configure(config);
        for (std::size_t i = 0; i < vectors.size(); ++i) {
            if (vectors[i].empty()) continue;
            labels[i] = online.assign(vectors[i], i < frames.size() ? frames[i] : 0);
        }
        renumberByFirstAppearance(&labels);
        return labels;
    }

    std::vector<std::vector<float>> centroids(n);
    std::vector<double> weights(n, 1.0);
    for (std::size_t i = 0; i < n; ++i) {
        centroids[i] = normalized(vectors[strong[i]]);
        std::size_t src = strong[i];
        weights[i] = src < frames.size() && frames[src] > 0 ? frames[src] : 1;
    }

    // See DiarizerConfig::centerOnRecordingMean. Computed over the strong
    // embeddings only, so a handful of noisy fragments cannot skew it, and
    // kept so the weak ones can be centred by the same offset below.
    std::vector<float> mean;
    if (config.centerOnRecordingMean && n > 1) {
        mean.assign(centroids[0].size(), 0.0f);
        for (const std::vector<float>& v : centroids) {
            for (std::size_t k = 0; k < mean.size() && k < v.size(); ++k) mean[k] += v[k];
        }
        for (float& m : mean) m /= static_cast<float>(n);
        for (std::vector<float>& v : centroids) {
            for (std::size_t k = 0; k < v.size() && k < mean.size(); ++k) v[k] -= mean[k];
        }
        for (std::vector<float>& v : centroids) v = normalized(v);
    }

    std::vector<char> active(n, 1);
    std::vector<int> cluster(n);
    for (std::size_t i = 0; i < n; ++i) cluster[i] = static_cast<int>(i);

    std::vector<float> sim(n * n, -1.0f);
    for (std::size_t i = 0; i < n; ++i) {
        for (std::size_t j = i + 1; j < n; ++j) {
            float s = static_cast<float>(dot(centroids[i], centroids[j]));
            sim[i * n + j] = s;
            sim[j * n + i] = s;
        }
    }

    std::size_t remaining = n;
    while (remaining > 1) {
        // Find the closest surviving pair.
        double bestSim = -2.0;
        std::size_t bestA = 0;
        std::size_t bestB = 0;
        for (std::size_t i = 0; i < n; ++i) {
            if (!active[i]) continue;
            for (std::size_t j = i + 1; j < n; ++j) {
                if (!active[j]) continue;
                double s = sim[i * n + j];
                if (s > bestSim) {
                    bestSim = s;
                    bestA = i;
                    bestB = j;
                }
            }
        }
        if (bestSim <= -2.0) break;

        bool overCapacity = config.maxSpeakers > 0 &&
                            remaining > static_cast<std::size_t>(config.maxSpeakers);
        // Stop at the threshold, unless a speaker cap still has to be met.
        if (bestSim < config.threshold && !overCapacity) break;

        double wa = weights[bestA];
        double wb = weights[bestB];
        double total = wa + wb;
        std::vector<float>& ca = centroids[bestA];
        const std::vector<float>& cb = centroids[bestB];
        for (std::size_t k = 0; k < ca.size() && k < cb.size(); ++k) {
            ca[k] = static_cast<float>((ca[k] * wa + cb[k] * wb) / total);
        }
        centroids[bestA] = normalized(ca);
        weights[bestA] = total;
        active[bestB] = 0;
        --remaining;

        for (std::size_t i = 0; i < n; ++i) {
            if (!active[i] || i == bestA) continue;
            float s = static_cast<float>(dot(centroids[bestA], centroids[i]));
            sim[bestA * n + i] = s;
            sim[i * n + bestA] = s;
        }
        for (std::size_t i = 0; i < n; ++i) {
            if (cluster[i] == static_cast<int>(bestB)) cluster[i] = static_cast<int>(bestA);
        }
    }

    for (std::size_t i = 0; i < n; ++i) {
        labels[strong[i]] = cluster[i];
    }

    // Attach the short segments to the nearest final centroid. They are
    // centred by the same mean, or the comparison would be against centroids
    // living in a different space.
    for (std::size_t idx : weak) {
        if (labels[idx] != kUnknownSpeaker) continue;
        std::vector<float> unit = normalized(vectors[idx]);
        if (!mean.empty()) {
            for (std::size_t k = 0; k < unit.size() && k < mean.size(); ++k) unit[k] -= mean[k];
            unit = normalized(unit);
        }
        double bestSim = -2.0;
        int best = kUnknownSpeaker;
        for (std::size_t i = 0; i < n; ++i) {
            if (!active[i]) continue;
            double s = dot(unit, centroids[i]);
            if (s > bestSim) {
                bestSim = s;
                best = static_cast<int>(i);
            }
        }
        labels[idx] = best;
    }

    renumberByFirstAppearance(&labels);
    return labels;
}

}  // namespace va
