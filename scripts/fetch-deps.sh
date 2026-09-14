#!/bin/sh
#
# Downloads everything the build and the app need that is not in the repo:
# the minimp3 header, the Vosk shared library, and the models.
#
# Plain POSIX sh with curl and unzip, so the same script serves MSYS2 on
# Windows, any Linux, and macOS. Nothing here is specific to a package manager.
#
# Usage:
#   scripts/fetch-deps.sh                 # minimp3 + vosk library
#   scripts/fetch-deps.sh all             # the above, plus the default models
#   scripts/fetch-deps.sh minimp3
#   scripts/fetch-deps.sh vosk
#   scripts/fetch-deps.sh models          # language model + speaker model
#   scripts/fetch-deps.sh model NAME      # one named model from the Vosk site
#
# Environment:
#   VOSK_VERSION    Vosk release to fetch          (default 0.3.45)
#   VOSK_LANG_MODEL Language model name            (default vosk-model-small-fr-0.22)
#   VOSK_SPK_MODEL  Speaker model name             (default vosk-model-spk-0.4)

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
THIRD_PARTY="$ROOT/third_party"
VENDOR="$ROOT/vendor/vosk"
MODELS="$ROOT/models"
CACHE="$ROOT/.cache"

VOSK_VERSION="${VOSK_VERSION:-0.3.45}"
VOSK_LANG_MODEL="${VOSK_LANG_MODEL:-vosk-model-small-fr-0.22}"
VOSK_SPK_MODEL="${VOSK_SPK_MODEL:-vosk-model-spk-0.4}"

MINIMP3_URL="https://raw.githubusercontent.com/lieff/minimp3/master/minimp3.h"
MODEL_BASE="https://alphacephei.com/vosk/models"
RELEASE_BASE="https://github.com/alphacep/vosk-api/releases/download"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

# Detects the platform the same way the Makefile does, so the two never
# disagree about which Vosk archive belongs to this machine.
detect_platform() {
    case "$(uname -s)" in
        MINGW*|MSYS*|CYGWIN*) echo windows ;;
        Darwin)               echo macos ;;
        Linux)                echo linux ;;
        *)                    echo unknown ;;
    esac
}

download() {
    url="$1"
    dest="$2"
    if [ -f "$dest" ]; then
        say "already downloaded: $(basename "$dest")"
        return 0
    fi
    say "downloading $(basename "$dest")"
    mkdir -p "$(dirname "$dest")"
    # Download beside the target and move on success, so an interrupted run
    # never leaves a half file that the next run would trust.
    curl -fL --progress-bar -o "$dest.part" "$url" || die "download failed: $url"
    mv "$dest.part" "$dest"
}

fetch_minimp3() {
    need curl
    mkdir -p "$THIRD_PARTY/minimp3"
    if [ -f "$THIRD_PARTY/minimp3/minimp3.h" ]; then
        say "minimp3 already present"
        return 0
    fi
    download "$MINIMP3_URL" "$THIRD_PARTY/minimp3/minimp3.h"
    say "minimp3 ready"
}

fetch_vosk() {
    need curl
    need unzip
    platform=$(detect_platform)

    case "$platform" in
        windows) archive="vosk-win64-$VOSK_VERSION.zip" ;;
        linux)   archive="vosk-linux-x86_64-$VOSK_VERSION.zip" ;;
        macos)
            # No standalone macOS archive is published; the universal2 Python
            # wheel is a zip and carries the same dylib.
            archive="vosk-0.3.42-py3-none-macosx_10_6_universal2.whl"
            ;;
        *) die "unsupported platform: $(uname -s)" ;;
    esac

    if [ "$platform" = macos ]; then
        url="$RELEASE_BASE/v0.3.42/$archive"
    else
        url="$RELEASE_BASE/v$VOSK_VERSION/$archive"
    fi

    download "$url" "$CACHE/$archive"

    workdir="$CACHE/vosk-extract"
    rm -rf "$workdir"
    mkdir -p "$workdir"
    unzip -q -o "$CACHE/$archive" -d "$workdir"

    mkdir -p "$VENDOR/include" "$VENDOR/lib" "$VENDOR/bin"

    header=$(find "$workdir" -name 'vosk_api.h' -print -quit 2>/dev/null || true)
    if [ -n "$header" ]; then
        cp "$header" "$VENDOR/include/vosk_api.h"
    elif [ ! -f "$VENDOR/include/vosk_api.h" ]; then
        # The wheel ships no header; the API is stable, so write the subset the
        # project uses rather than fail.
        say "no vosk_api.h in the archive, writing the declarations we use"
        cat > "$VENDOR/include/vosk_api.h" <<'HEADER'
/* Subset of the Vosk C API used by voiceannotate.
   Reproduced here because the macOS distribution ships no header.
   Upstream: https://github.com/alphacep/vosk-api (Apache-2.0) */
#ifndef VOSK_API_H
#define VOSK_API_H

#ifdef __cplusplus
extern "C" {
#endif

typedef struct VoskModel VoskModel;
typedef struct VoskSpkModel VoskSpkModel;
typedef struct VoskRecognizer VoskRecognizer;

VoskModel *vosk_model_new(const char *model_path);
void vosk_model_free(VoskModel *model);

VoskSpkModel *vosk_spk_model_new(const char *model_path);
void vosk_spk_model_free(VoskSpkModel *model);

VoskRecognizer *vosk_recognizer_new(VoskModel *model, float sample_rate);
VoskRecognizer *vosk_recognizer_new_spk(VoskModel *model, float sample_rate,
                                        VoskSpkModel *spk_model);
void vosk_recognizer_set_spk_model(VoskRecognizer *recognizer, VoskSpkModel *spk_model);
void vosk_recognizer_set_words(VoskRecognizer *recognizer, int words);
int vosk_recognizer_accept_waveform_s(VoskRecognizer *recognizer, const short *data, int length);
const char *vosk_recognizer_result(VoskRecognizer *recognizer);
const char *vosk_recognizer_partial_result(VoskRecognizer *recognizer);
const char *vosk_recognizer_final_result(VoskRecognizer *recognizer);
void vosk_recognizer_reset(VoskRecognizer *recognizer);
void vosk_recognizer_free(VoskRecognizer *recognizer);
void vosk_set_log_level(int log_level);

#ifdef __cplusplus
}
#endif

#endif /* VOSK_API_H */
HEADER
    fi

    found=0
    for pattern in 'libvosk.dll' 'libvosk.so' 'libvosk.dylib' 'libvosk.dyld' 'vosk.dll'; do
        lib=$(find "$workdir" -name "$pattern" -print -quit 2>/dev/null || true)
        [ -n "$lib" ] || continue
        found=1
        case "$pattern" in
            *.dll)
                # On Windows the loader looks next to the executable, not in a
                # lib directory, so the DLL is staged into bin/ by the Makefile.
                cp "$lib" "$VENDOR/bin/libvosk.dll"
                cp "$lib" "$VENDOR/lib/libvosk.dll"
                ;;
            libvosk.dyld|libvosk.dylib)
                cp "$lib" "$VENDOR/lib/libvosk.dylib"
                ;;
            *)
                cp "$lib" "$VENDOR/lib/libvosk.so"
                ;;
        esac
    done
    # Windows import libraries, when the archive provides one.
    implib=$(find "$workdir" -name 'libvosk.lib' -o -name 'vosk.lib' -print -quit 2>/dev/null || true)
    [ -n "$implib" ] && cp "$implib" "$VENDOR/lib/" 2>/dev/null || true

    [ "$found" = 1 ] || die "no Vosk library found inside $archive"

    rm -rf "$workdir"
    say "vosk $VOSK_VERSION ready in vendor/vosk"
}

fetch_model() {
    name="$1"
    need curl
    need unzip
    mkdir -p "$MODELS"
    if [ -d "$MODELS/$name" ]; then
        say "model already present: $name"
        return 0
    fi
    download "$MODEL_BASE/$name.zip" "$CACHE/$name.zip"
    say "unpacking $name"
    unzip -q -o "$CACHE/$name.zip" -d "$MODELS"
    [ -d "$MODELS/$name" ] || die "unpacking $name did not produce $MODELS/$name"
    say "model ready: models/$name"
}

fetch_models() {
    fetch_model "$VOSK_LANG_MODEL"
    fetch_model "$VOSK_SPK_MODEL"
    say "set VOSK_MODEL=$MODELS/$VOSK_LANG_MODEL"
    say "set VOSK_SPK_MODEL=$MODELS/$VOSK_SPK_MODEL"
}

action="${1:-deps}"
case "$action" in
    deps)     fetch_minimp3; fetch_vosk ;;
    all)      fetch_minimp3; fetch_vosk; fetch_models ;;
    minimp3)  fetch_minimp3 ;;
    vosk)     fetch_vosk ;;
    models)   fetch_models ;;
    model)    [ $# -ge 2 ] || die "usage: $0 model NAME"; fetch_model "$2" ;;
    *)        die "unknown action '$action' (deps, all, minimp3, vosk, models, model NAME)" ;;
esac
