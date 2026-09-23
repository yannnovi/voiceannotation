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
DIST="$ROOT/dist"
MODELS_DIR="$ROOT/models"

# Which build to pack. The Makefile passes the directories it used, since a
# 32-bit and a 64-bit build sit side by side in the tree; the defaults are the
# 64-bit ones, for a run by hand.
VA_ARCH="${VA_ARCH:-x86_64}"
STAGE="$ROOT/${VA_STAGE_DIR:-build/stage}"
VENDOR="$ROOT/${VA_VENDOR_DIR:-vendor/vosk}"
BIN="$ROOT/${VA_BIN_DIR:-bin}"

# What goes in the installer's file name. The two spellings are the ones asked
# for, and Windows file names are case-insensitive anyway.
case "$VA_ARCH" in
    x86_32) ARCH_TAG="x86_32" ;;
    *)      ARCH_TAG="X86_64" ;;
esac

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
    say "staging $VA_ARCH into ${VA_STAGE_DIR:-build/stage}"
    rm -rf "$STAGE"
    mkdir -p "$STAGE/bin" "$STAGE/lib" "$STAGE/share/voiceannotate"

    for exe in voiceannotate.exe voiceannotate-cli.exe; do
        [ -f "$BIN/$exe" ] || die "$exe is not built; run make first"
        cp "$BIN/$exe" "$STAGE/bin/"
    done
    cp "$ROOT/tcl/app.tcl" "$STAGE/share/voiceannotate/"
    cp "$VENDOR/bin/libvosk.dll" "$STAGE/bin/"

    stage_dlls
    stage_tcl_library
    stage_models
    stage_documents
}

# Follows the import table from the binaries outwards. A DLL found in neither
# the Vosk archive nor the toolchain is one Windows itself provides --
# kernel32, comctl32 and the like -- so the search doubles as the filter, and
# nothing has to be listed by hand or kept up to date as the toolchain moves.
#
# Two passes, because two runtimes meet in this directory. Our executables were
# compiled by the toolchain on PATH and need its DLLs: Vosk's copies are years
# older, and its libwinpthread is missing symbols they import -- a 32-bit
# binary given that one dies at load with no message at all. libvosk.dll, the
# other way about, wants the runtime it shipped with, which on 32-bit is a
# different exception flavour from MinGW's current one under the very same file
# name. So each side is resolved from its own, ours first; nothing already
# staged is ever replaced, and that is what settles a shared name in favour of
# the toolchain -- the newer libwinpthread serves Vosk too, being compatible
# backwards, where the reverse was not true.
stage_dlls() {
    stage_imports_of "$MINGW_PREFIX/bin" "$VENDOR/bin" \
        voiceannotate.exe voiceannotate-cli.exe
    stage_imports_of "$VENDOR/bin" "$MINGW_PREFIX/bin" libvosk.dll
}

# $1, $2: where to look, in order. The rest: what to start from.
stage_imports_of() {
    first="$1"
    second="$2"
    shift 2
    queue=$(printf '%s\n' "$@")
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
            # Already staged, and not descended into: libvosk.dll is staged
            # before either pass and imported by both executables, so without
            # this the first pass would walk it and resolve its runtime from
            # the toolchain -- the very thing the second pass exists to avoid.
            [ -f "$STAGE/bin/$dll" ] && continue
            # Windows is case-insensitive about DLL names but a file system
            # search is not, so both spellings are tried.
            lower=$(printf '%s' "$dll" | tr 'A-Z' 'a-z')
            source=""
            for candidate in "$first/$dll" "$first/$lower" \
                             "$second/$dll" "$second/$lower"; do
                [ -f "$candidate" ] && { source="$candidate"; break; }
            done
            [ -n "$source" ] || continue   # provided by Windows
            cp "$source" "$STAGE/bin/$dll"
            case "$source" in
                "$VENDOR"/*) origin="from Vosk" ;;
                *)           origin="from the toolchain" ;;
            esac
            say "  bundled $dll $origin"
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
    pacman -S mingw-w64-x86_64-nsis   (or mingw-w64-i686-nsis for 32-bit)
  or run the staging step alone with --stage-only"

    mkdir -p "$DIST"
    output="$DIST/voiceannotate-$VERSION-$ARCH_TAG-setup.exe"

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
    say "staged tree ready in ${VA_STAGE_DIR:-build/stage} ($(du -sh "$STAGE" | cut -f1))"
    say "run ${VA_STAGE_DIR:-build/stage}/bin/voiceannotate.exe to try it before packing"
    exit 0
fi

build_installer
