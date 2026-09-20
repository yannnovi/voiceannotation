#!/bin/sh
#
# Builds the Windows installer: a single .exe that carries everything the
# application needs and installs on a machine with nothing on it.
#
# Two steps. First a self-contained tree is staged, with the Tcl/Tk runtime,
# the MinGW libraries the binaries import and the Vosk library beside them;
# then NSIS packs that tree into an installer. The staging step is the one that
# matters -- it is what decides whether the program runs somewhere else -- so
# it is kept separate and can be run on its own with --stage-only.
#
# Usage:
#   scripts/make-installer.sh                 stage, then build the installer
#   scripts/make-installer.sh --stage-only    stage only, and say where
#
# Environment, all with sane defaults (the Makefile passes its own):
#   VERSION           version string for the installer   (default 0.0.0)
#   MINGW_PREFIX      toolchain root, where the DLLs live (default: from pkg-config)
#   INSTALLER_MODELS  models to bundle, "" for none
#   OBJDUMP           the objdump to read imports with

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE="$ROOT/build/stage"
DIST="$ROOT/dist"
VENDOR="$ROOT/vendor/vosk"
MODELS_DIR="$ROOT/models"

VERSION="${VERSION:-0.0.0}"
OBJDUMP="${OBJDUMP:-objdump}"
# The two models "make models" fetches, so a fresh installation can transcribe
# straight away. An explicitly empty INSTALLER_MODELS ships none, hence the
# "-" rather than ":-" below.
INSTALLER_MODELS="${INSTALLER_MODELS-${VOSK_LANG_MODEL:-vosk-model-small-fr-0.22} ${VOSK_SPK_MODEL:-vosk-model-spk-0.4}}"
STAGE_ONLY=0
[ "${1:-}" = "--stage-only" ] && STAGE_ONLY=1

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

case "$(uname -s)" in
    MINGW*|MSYS*|CYGWIN*) ;;
    *) die "the Windows installer can only be built on Windows" ;;
esac

# --------------------------------------------------------------------------
# The toolchain, which is also where the redistributable DLLs come from
# --------------------------------------------------------------------------

if [ -z "${MINGW_PREFIX:-}" ]; then
    # The same pkg-config the build used, so the Tcl shipped is the Tcl linked
    # against. It answers with a "bin/.." suffix, hence the cd.
    MINGW_PREFIX=$(pkg-config --variable=prefix tcl 2>/dev/null || true)
    [ -n "$MINGW_PREFIX" ] || MINGW_PREFIX=$(dirname "$(dirname "$(command -v g++)")")
fi
MINGW_PREFIX=$(cd "$MINGW_PREFIX" && pwd)

[ -d "$MINGW_PREFIX/bin" ] || die "no toolchain at $MINGW_PREFIX"
command -v "$OBJDUMP" >/dev/null 2>&1 || die "$OBJDUMP is required to read the imports"

# --------------------------------------------------------------------------
# Staging
# --------------------------------------------------------------------------

# The layout is the one the program already knows how to be run from, so
# nothing has to be told where anything is:
#
#   bin/     the executables, and every DLL beside them -- where the Windows
#            loader looks, there being no rpath on this platform
#   lib/     the Tcl and Tk script libraries; Tcl finds these by looking at
#            ../lib relative to the DLL it was loaded from
#   share/   app.tcl, the third place locateScript looks
#   models/  bundled models, in the directory the program searches first
stage_tree() {
    say "staging into build/stage"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share/voiceannotate"

    for exe in voiceannotate.exe voiceannotate-cli.exe; do
        [ -f "$ROOT/bin/$exe" ] || die "$exe is not built; run make first"
        cp "$ROOT/bin/$exe" "$STAGE/bin/"
    done
    cp "$ROOT/tcl/app.tcl" "$STAGE/share/voiceannotate/"
    cp "$VENDOR/bin/libvosk.dll" "$STAGE/bin/"

    stage_dlls
    stage_tcl_library
    stage_models
    stage_documents
}

# Follows the import table from the executables outwards. A DLL that is not in
# the toolchain's bin directory is one Windows itself provides -- kernel32,
# comctl32 and the like -- so the search doubles as the filter, and nothing has
# to be listed by hand or kept up to date as the toolchain moves.
stage_dlls() {
    queue=$(ls "$STAGE/bin")
    seen=""

    while [ -n "$queue" ]; do
        current=$(printf '%s\n' "$queue" | sed -n 1p)
        queue=$(printf '%s\n' "$queue" | sed 1d)

        case "$current" in "") continue ;; esac
        printf '%s\n' "$seen" | grep -qxF "$current" && continue
        seen=$(printf '%s\n%s' "$seen" "$current")

        [ -f "$STAGE/bin/$current" ] || continue
        imports=$("$OBJDUMP" -p "$STAGE/bin/$current" \
            | sed -n 's/^[[:space:]]*DLL Name:[[:space:]]*//p')

        for dll in $imports; do
            [ -f "$STAGE/bin/$dll" ] && continue
            # Windows is case-insensitive about DLL names but a file system
            # search is not, so both spellings are tried.
            source=""
            for candidate in "$MINGW_PREFIX/bin/$dll" \
                             "$MINGW_PREFIX/bin/$(printf '%s' "$dll" | tr 'A-Z' 'a-z')"; do
                [ -f "$candidate" ] && { source="$candidate"; break; }
            done
            [ -n "$source" ] || continue   # provided by Windows
            cp "$source" "$STAGE/bin/$dll"
            say "  bundled $dll"
            queue=$(printf '%s\n%s' "$queue" "$dll")
        done
    done
}

# Tcl and Tk are half C and half script: without these directories the
# interpreter comes up and then fails on its own init.tcl.
stage_tcl_library() {
    for dir in tcl8.6 tk8.6 tcl8; do
        [ -d "$MINGW_PREFIX/lib/$dir" ] || die "$MINGW_PREFIX/lib/$dir is missing"
        cp -r "$MINGW_PREFIX/lib/$dir" "$STAGE/lib/"
    done
    # A megabyte of example programs nobody will run from here.
    rm -rf "$STAGE/lib/tk8.6/demos"
    say "  bundled the Tcl/Tk script library"
}

stage_models() {
    for name in ${INSTALLER_MODELS:-}; do
        if [ ! -d "$MODELS_DIR/$name" ]; then
            say "  skipped $name (not in models/; run 'make models' to bundle it)"
            continue
        fi
        mkdir -p "$STAGE/models"
        cp -r "$MODELS_DIR/$name" "$STAGE/models/"
        say "  bundled model $name"
    done
}

stage_documents() {
    for name in README.md LICENSE LICENSE.txt COPYING; do
        [ -f "$ROOT/$name" ] && cp "$ROOT/$name" "$STAGE/"
    done
    # Vosk is Apache-2.0 and ships its own notice; keep it with the DLL.
    for name in "$VENDOR"/*LICENSE* "$VENDOR"/*COPYING*; do
        [ -f "$name" ] && cp "$name" "$STAGE/"
    done
    return 0
}

# --------------------------------------------------------------------------
# Packing
# --------------------------------------------------------------------------

build_installer() {
    command -v makensis >/dev/null 2>&1 || die \
        "makensis is required to build the installer; install it with:
    pacman -S mingw-w64-x86_64-nsis
  or run the staging step alone with --stage-only"

    mkdir -p "$DIST"
    output="$DIST/voiceannotate-$VERSION-setup.exe"

    # The Windows version resource is four numbers and nothing else, whatever
    # the project calls its version.
    version4=$(printf '%s' "$VERSION" | tr -c '0-9.' ' ' | cut -d' ' -f1)
    while [ "$(printf '%s' "$version4" | tr -cd '.' | wc -c)" -lt 3 ]; do
        version4="$version4.0"
    done

    say "packing with NSIS"
    makensis -V2 \
        "-DVERSION=$VERSION" \
        "-DVERSION4=$version4" \
        "-DSTAGE_DIR=$(cygpath -w "$STAGE")" \
        "-DOUT_FILE=$(cygpath -w "$output")" \
        "$(cygpath -w "$ROOT/scripts/installer.nsi")" \
        || die "makensis failed"

    say "installer ready: dist/$(basename "$output") ($(du -h "$output" | cut -f1))"
}

stage_tree

if [ "$STAGE_ONLY" = 1 ]; then
    say "staged tree ready in build/stage ($(du -sh "$STAGE" | cut -f1))"
    say "run build/stage/bin/voiceannotate.exe to try it before packing"
    exit 0
fi

build_installer
