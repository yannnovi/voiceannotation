#!/bin/sh
#
# Downloads everything the build and the app need that is not in the repo:
# the minimp3 header, the Vosk shared library, and the models.
#
# Plain POSIX sh with curl and a zip reader, so the same script serves MSYS2 on
# Windows, any Linux, and macOS. Nothing here is specific to a package manager.
#
# Usage:
#   scripts/fetch-deps.sh                 # minimp3 + vosk library
#   scripts/fetch-deps.sh all             # the above, plus the default models
#   scripts/fetch-deps.sh minimp3
#   scripts/fetch-deps.sh vosk
#   scripts/fetch-deps.sh models          # language model + speaker model
#   scripts/fetch-deps.sh model NAME      # one named model from the Vosk site
#   scripts/fetch-deps.sh tcltk           # macOS: Tcl/Tk built for arm64 + x86_64
#
# Environment:
#   VOSK_VERSION    Vosk release to fetch          (default 0.3.45)
#   VOSK_LANG_MODEL Language model name            (default vosk-model-small-fr-0.22)
#   VOSK_SPK_MODEL  Speaker model name             (default vosk-model-spk-0.4)
#   TCLTK_VERSION   Tcl/Tk release to build        (default 8.6.18)
#   MACOS_MIN       oldest macOS the Tcl/Tk build may require (default 11.0)

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
THIRD_PARTY="$ROOT/third_party"
TCLTK_VENDOR="$ROOT/vendor/tcltk"
MODELS="$ROOT/models"
CACHE="$ROOT/.cache"

# Which Windows build to fetch. The Makefile passes what the compiler on PATH
# targets; on its own the script serves the usual 64-bit case. uname is no help
# here -- under Git Bash it answers x86_64 whichever toolchain is in front.
VA_ARCH="${VA_ARCH:-x86_64}"
case "$VA_ARCH" in
    x86_32) VENDOR="$ROOT/vendor/vosk-x86_32" ;;
    *)      VENDOR="$ROOT/vendor/vosk" ;;
esac

VOSK_VERSION="${VOSK_VERSION:-0.3.45}"
# 32-bit Windows is pinned, and not by choice: 0.3.42 is the last release
# upstream published a win32 build of, and every one since is 64-bit only.
VOSK_VERSION_WIN32="${VOSK_VERSION_WIN32:-0.3.42}"
VOSK_LANG_MODEL="${VOSK_LANG_MODEL:-vosk-model-small-fr-0.22}"
VOSK_SPK_MODEL="${VOSK_SPK_MODEL:-vosk-model-spk-0.4}"
TCLTK_VERSION="${TCLTK_VERSION:-8.6.18}"
MACOS_MIN="${MACOS_MIN:-11.0}"

MINIMP3_URL="https://raw.githubusercontent.com/lieff/minimp3/master/minimp3.h"
MODEL_BASE="https://alphacephei.com/vosk/models"
RELEASE_BASE="https://github.com/alphacep/vosk-api/releases/download"
TCLTK_BASE="https://prdownloads.sourceforge.net/tcl"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

need() {
    command -v "$1" >/dev/null 2>&1 || die "$1 is required but not installed"
}

# Unpacking, without requiring unzip
#
# A stock Windows has no unzip, but it has had bsdtar as tar.exe since Windows
# 10 1803, and bsdtar reads zip. GNU tar -- what "tar" is on most Linux
# machines and in a Git installation -- cannot read one at all, so the version
# is asked for rather than the name trusted. The interface does the same when
# it downloads a model; see unpackers in tcl/app.tcl.
UNPACKER=""

find_unpacker() {
    [ -z "$UNPACKER" ] || return 0

    if command -v unzip >/dev/null 2>&1; then
        UNPACKER=unzip
        return 0
    fi

    candidates="tar bsdtar"
    if [ -n "${SYSTEMROOT:-}" ] && command -v cygpath >/dev/null 2>&1; then
        candidates="$(cygpath -u "$SYSTEMROOT")/System32/tar.exe $candidates"
    fi

    for candidate in $candidates; do
        case "$($candidate --version 2>/dev/null || true)" in
            *bsdtar*|*libarchive*) UNPACKER="$candidate"; return 0 ;;
        esac
    done

    die "unzip is required but not installed (bsdtar would do, and is not there either)"
}

extract_zip() {
    find_unpacker
    if [ "$UNPACKER" = unzip ]; then
        unzip -q -o "$1" -d "$2"
    else
        "$UNPACKER" -x -f "$1" -C "$2"
    fi
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
    find_unpacker
    platform=$(detect_platform)

    release="$VOSK_VERSION"
    case "$platform" in
        windows)
            if [ "$VA_ARCH" = x86_32 ]; then
                release="$VOSK_VERSION_WIN32"
                archive="vosk-win32-$release.zip"
            else
                archive="vosk-win64-$release.zip"
            fi
            ;;
        linux)   archive="vosk-linux-x86_64-$release.zip" ;;
        macos)
            # No standalone macOS archive is published; the universal2 Python
            # wheel is a zip and carries the same dylib.
            release="0.3.42"
            archive="vosk-$release-py3-none-macosx_10_6_universal2.whl"
            ;;
        *) die "unsupported platform: $(uname -s)" ;;
    esac

    url="$RELEASE_BASE/v$release/$archive"

    download "$url" "$CACHE/$archive"

    workdir="$CACHE/vosk-extract"
    rm -rf "$workdir"
    mkdir -p "$workdir"
    extract_zip "$CACHE/$archive" "$workdir"

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
                # The wheel ships the dylib with a bare install name
                # ("libvosk.dylib", no path), so the @rpath entries the
                # Makefile links with never match and the binaries fail to
                # load it at run time. Rewrite the id to @rpath/libvosk.dylib
                # so it resolves the same way libvosk.so does on Linux.
                command -v install_name_tool >/dev/null 2>&1 &&
                    install_name_tool -id "@rpath/libvosk.dylib" "$VENDOR/lib/libvosk.dylib"
                ;;
            *)
                cp "$lib" "$VENDOR/lib/libvosk.so"
                ;;
        esac
    done
    # Windows import libraries, when the archive provides one.
    implib=$(find "$workdir" -name 'libvosk.lib' -o -name 'vosk.lib' -print -quit 2>/dev/null || true)
    [ -n "$implib" ] && cp "$implib" "$VENDOR/lib/" 2>/dev/null || true

    # The runtime libvosk.dll was built against travels with it, and is kept
    # rather than taken from the toolchain: on 32-bit the two are different
    # flavours -- Vosk's libgcc is SJLJ where MinGW's is DWARF2 -- and its
    # libstdc++ has the same file name as MinGW's, of which Windows loads only
    # one per process. The installer looks here first for that reason.
    if [ "$platform" = windows ]; then
        for companion in "$workdir"/*/*.dll "$workdir"/*.dll; do
            [ -f "$companion" ] || continue
            case "$(basename "$companion")" in
                libvosk.dll) continue ;;
            esac
            cp "$companion" "$VENDOR/bin/"
            say "kept $(basename "$companion") from the Vosk archive"
        done
    fi

    [ "$found" = 1 ] || die "no Vosk library found inside $archive"

    rm -rf "$workdir"
    say "vosk $VOSK_VERSION ready in vendor/vosk"
}

fetch_model() {
    name="$1"
    need curl
    find_unpacker
    mkdir -p "$MODELS"
    if [ -d "$MODELS/$name" ]; then
        say "model already present: $name"
        return 0
    fi
    download "$MODEL_BASE/$name.zip" "$CACHE/$name.zip"
    say "unpacking $name"
    extract_zip "$CACHE/$name.zip" "$MODELS"
    [ -d "$MODELS/$name" ] || die "unpacking $name did not produce $MODELS/$name"
    say "model ready: models/$name"
}

fetch_models() {
    fetch_model "$VOSK_LANG_MODEL"
    fetch_model "$VOSK_SPK_MODEL"
    say "set VOSK_MODEL=$MODELS/$VOSK_LANG_MODEL"
    say "set VOSK_SPK_MODEL=$MODELS/$VOSK_SPK_MODEL"
}

# Tcl/Tk for a universal macOS binary
#
# A binary carrying both an arm64 and an x86_64 slice can only link against
# libraries that carry both too. The Vosk dylib does; the Tcl/Tk that Homebrew
# ships is built for the one architecture of the machine it was installed on.
# So a fat build gets a Tcl/Tk of its own, compiled from source with both
# -arch flags, which is the way the Tcl project itself documents fat builds.

# Runs one build step with its output kept in a log, and shows the end of that
# log when the step fails: configure and make say a great deal, none of it
# worth reading unless something went wrong.
build_step() {
    label="$1"
    shift
    say "$label"
    if ! "$@" >>"$CACHE/tcltk-build.log" 2>&1; then
        tail -n 30 "$CACHE/tcltk-build.log" >&2
        die "$label failed (full log: .cache/tcltk-build.log)"
    fi
}

# The oldest macOS a Mach-O file agrees to run on, as recorded in it.
min_macos_of() {
    otool -l "$1" 2>/dev/null | awk '/LC_BUILD_VERSION/{v=1} v && /minos/{print $2; exit}'
}

fetch_tcltk() {
    [ "$(detect_platform)" = macos ] || die "a universal Tcl/Tk is only built on macOS"
    need curl
    need make
    need install_name_tool
    need otool

    # Without a deployment target the compiler stamps the library with the
    # macOS it was built on, and it then refuses to load on anything older --
    # which, built on an Apple silicon machine, rules out every Intel Mac and
    # makes the x86_64 slice pointless. A library built for a different minimum
    # than asked for is rebuilt rather than trusted.
    export MACOSX_DEPLOYMENT_TARGET="$MACOS_MIN"

    if [ -f "$TCLTK_VENDOR/lib/libtk8.6.dylib" ]; then
        built_for=$(min_macos_of "$TCLTK_VENDOR/lib/libtk8.6.dylib")
        if [ "$built_for" = "$MACOS_MIN" ]; then
            say "universal Tcl/Tk already present (macOS $MACOS_MIN and later)"
            return 0
        fi
        say "the Tcl/Tk present requires macOS $built_for, not $MACOS_MIN; rebuilding it"
        rm -rf "$TCLTK_VENDOR"
    fi

    archs="-arch arm64 -arch x86_64"
    jobs=$(sysctl -n hw.ncpu 2>/dev/null || echo 4)
    workdir="$CACHE/tcltk-build"
    rm -rf "$workdir" "$CACHE/tcltk-build.log"
    mkdir -p "$workdir"

    for part in tcl tk; do
        tarball="$part$TCLTK_VERSION-src.tar.gz"
        download "$TCLTK_BASE/$tarball" "$CACHE/$tarball"
        tar -xzf "$CACHE/$tarball" -C "$workdir"
    done

    tcl_src="$workdir/tcl$TCLTK_VERSION/unix"
    tk_src="$workdir/tk$TCLTK_VERSION/unix"

    build_step "configuring Tcl $TCLTK_VERSION for arm64 and x86_64" \
        sh -c "cd '$tcl_src' && ./configure --prefix='$TCLTK_VENDOR' CFLAGS='$archs'"
    build_step "building Tcl (a few minutes)" \
        make -C "$tcl_src" -j"$jobs"
    build_step "installing Tcl into vendor/tcltk" \
        make -C "$tcl_src" install

    # --enable-aqua: without it Tk wants X11, which a Mac has only through
    # XQuartz. --with-tcl points at the tclConfig.sh just installed.
    build_step "configuring Tk $TCLTK_VERSION for arm64 and x86_64" \
        sh -c "cd '$tk_src' && ./configure --prefix='$TCLTK_VENDOR' --enable-aqua \
               --with-tcl='$TCLTK_VENDOR/lib' CFLAGS='$archs'"
    build_step "building Tk (a few minutes)" \
        make -C "$tk_src" -j"$jobs"
    build_step "installing Tk into vendor/tcltk" \
        make -C "$tk_src" install

    # Same treatment as the Vosk dylib: install names rewritten to @rpath, so
    # the binaries find these libraries relative to themselves and the tree
    # stays movable. Tk needs nothing more: it reaches Tcl through the stub
    # table rather than by linking libtcl, so it carries no path to rewrite.
    lib="$TCLTK_VENDOR/lib"
    install_name_tool -id "@rpath/libtcl8.6.dylib" "$lib/libtcl8.6.dylib"
    install_name_tool -id "@rpath/libtk8.6.dylib" "$lib/libtk8.6.dylib"

    rm -rf "$workdir"
    say "universal Tcl/Tk $TCLTK_VERSION ready in vendor/tcltk (macOS $MACOS_MIN and later)"
}

action="${1:-deps}"
case "$action" in
    deps)     fetch_minimp3; fetch_vosk ;;
    all)      fetch_minimp3; fetch_vosk; fetch_models ;;
    minimp3)  fetch_minimp3 ;;
    vosk)     fetch_vosk ;;
    models)   fetch_models ;;
    model)    [ $# -ge 2 ] || die "usage: $0 model NAME"; fetch_model "$2" ;;
    tcltk)    fetch_tcltk ;;
    *)        die "unknown action '$action' (deps, all, minimp3, vosk, models, model NAME, tcltk)" ;;
esac
