#!/bin/sh
#
# Builds the macOS installer: a .pkg that installs voiceannotate.app, a bundle
# carrying everything the application needs and running natively on Apple
# silicon and Intel Macs alike.
#
# Two steps, as for the Windows installer. First the bundle is staged, with the
# universal binaries, the Tcl/Tk runtime and the Vosk library inside it; then
# the tools macOS ships (pkgbuild, productbuild) pack it into an installer whose
# pages come in English and French. The staging step is the one that matters
# -- it decides whether the program runs somewhere else -- so it is kept
# separate and can be run on its own with --stage-only.
#
# Usage:
#   scripts/make-macos-installer.sh                 stage, then build the .pkg
#   scripts/make-macos-installer.sh --stage-only    stage only, and say where
#
# Environment, all with sane defaults (the Makefile passes its own):
#   VERSION            version string                      (default 0.0.0)
#   INSTALLER_MODELS   models to bundle, "" for none
#   MACOS_MIN          oldest macOS the binaries were built for (default 11.0)
#   BUNDLE_ID          the bundle identifier      (default org.voiceannotate.app)
#   CODESIGN_IDENTITY  "Developer ID Application: ..." to sign for distribution;
#                      by default the code is signed ad hoc, which Apple silicon
#                      requires to run it at all but Gatekeeper does not trust
#   INSTALLER_IDENTITY "Developer ID Installer: ..." to sign the .pkg itself

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
STAGE="$ROOT/build/stage"
APP="$STAGE/voiceannotate.app"
DIST="$ROOT/dist"
VOSK="$ROOT/vendor/vosk"
TCLTK="$ROOT/vendor/tcltk"
MODELS_DIR="$ROOT/models"
RESOURCES="$ROOT/scripts/macos"

VERSION="${VERSION:-0.0.0}"
MACOS_MIN="${MACOS_MIN:-11.0}"
BUNDLE_ID="${BUNDLE_ID:-org.voiceannotate.app}"
CODESIGN_IDENTITY="${CODESIGN_IDENTITY:--}"
INSTALLER_IDENTITY="${INSTALLER_IDENTITY:-}"
# The two models "make models" fetches, so a fresh installation can transcribe
# straight away. An explicitly empty INSTALLER_MODELS ships none, hence the
# "-" rather than ":-" below.
INSTALLER_MODELS="${INSTALLER_MODELS-${VOSK_LANG_MODEL:-vosk-model-small-fr-0.22} ${VOSK_SPK_MODEL:-vosk-model-spk-0.4}}"
STAGE_ONLY=0
[ "${1:-}" = "--stage-only" ] && STAGE_ONLY=1

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(uname -s)" = Darwin ] || die "the macOS installer can only be built on macOS"
for tool in lipo otool codesign pkgbuild productbuild; do
    command -v "$tool" >/dev/null 2>&1 || die "$tool is required (part of the Xcode command line tools)"
done

# The oldest macOS a Mach-O file agrees to run on, as recorded in it.
min_macos_of() {
    otool -l "$1" 2>/dev/null | awk '/LC_BUILD_VERSION/{v=1} v && /minos/{print $2; exit}'
}

# --------------------------------------------------------------------------
# What goes in has to be universal, and built for the right minimum
# --------------------------------------------------------------------------

check_inputs() {
    for exe in voiceannotate voiceannotate-cli; do
        [ -f "$ROOT/bin/$exe" ] || die "bin/$exe is not built; run 'make installer' (it builds universal binaries)"
        case "$(lipo -archs "$ROOT/bin/$exe")" in
            *arm64*x86_64*|*x86_64*arm64*) ;;
            *) die "bin/$exe is not universal ($(lipo -archs "$ROOT/bin/$exe")); build with 'make UNIVERSAL=1'" ;;
        esac
    done
    [ -f "$TCLTK/lib/libtk8.6.dylib" ] || die "vendor/tcltk is missing; 'make UNIVERSAL=1' builds it"
    [ -f "$VOSK/lib/libvosk.dylib" ] || die "vendor/vosk is missing; run 'make deps'"

    # A binary stamped with a newer minimum than intended would install fine
    # and then refuse to launch on the very machines the installer is for.
    for file in "$ROOT/bin/voiceannotate" "$TCLTK/lib/libtcl8.6.dylib" "$TCLTK/lib/libtk8.6.dylib"; do
        built_for=$(min_macos_of "$file")
        [ "$built_for" = "$MACOS_MIN" ] || die \
            "$(basename "$file") requires macOS $built_for, not $MACOS_MIN; rebuild with 'make clean' then 'make installer'"
    done
}

# --------------------------------------------------------------------------
# Staging the bundle
# --------------------------------------------------------------------------

# The layout is one the program already knows how to be run from, so nothing
# has to be told where anything is:
#
#   Contents/MacOS/      the executables
#   Contents/lib/        the three dylibs -- the binaries carry an rpath of
#                        ../lib relative to themselves -- and the Tcl and Tk
#                        script libraries, which Tcl finds at ../lib/tcl8.6
#                        relative to the executable
#   Contents/Resources/  app.tcl, which locateScript looks for at ../Resources,
#                        and the bundled models, which the interface looks for
#                        beside app.tcl
stage_bundle() {
    say "staging voiceannotate.app into build/stage"
    rm -rf "$STAGE"
    mkdir -p "$APP/Contents/MacOS" "$APP/Contents/lib" "$APP/Contents/Resources"

    cp "$ROOT/bin/voiceannotate" "$ROOT/bin/voiceannotate-cli" "$APP/Contents/MacOS/"
    cp "$ROOT/tcl/app.tcl" "$APP/Contents/Resources/"
    cp "$VOSK/lib/libvosk.dylib" "$TCLTK/lib/libtcl8.6.dylib" "$TCLTK/lib/libtk8.6.dylib" \
        "$APP/Contents/lib/"

    write_info_plist
    stage_tcl_library
    stage_models
    stage_documents
}

write_info_plist() {
    cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>voiceannotate</string>
    <key>CFBundleDisplayName</key>        <string>voiceannotate</string>
    <key>CFBundleIdentifier</key>         <string>$BUNDLE_ID</string>
    <key>CFBundleVersion</key>            <string>$VERSION</string>
    <key>CFBundleShortVersionString</key> <string>$VERSION</string>
    <key>CFBundleExecutable</key>         <string>voiceannotate</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleInfoDictionaryVersion</key> <string>6.0</string>
    <key>CFBundleDevelopmentRegion</key>  <string>en</string>
    <key>CFBundleLocalizations</key>
    <array><string>en</string><string>fr</string></array>
    <key>LSMinimumSystemVersion</key>     <string>$MACOS_MIN</string>
    <key>LSArchitecturePriority</key>
    <array><string>arm64</string><string>x86_64</string></array>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSHumanReadableCopyright</key>   <string>Speech engine: Vosk (Apache-2.0). Interface: Tcl/Tk.</string>
</dict>
</plist>
PLIST
    printf 'APPL????' > "$APP/Contents/PkgInfo"

    # The Finder reads the name from here in the machine's language. Both say
    # the same thing; the directories are what tells macOS the languages the
    # bundle knows about.
    for lang in en fr; do
        mkdir -p "$APP/Contents/Resources/$lang.lproj"
        printf 'CFBundleDisplayName = "voiceannotate";\nCFBundleName = "voiceannotate";\n' \
            > "$APP/Contents/Resources/$lang.lproj/InfoPlist.strings"
    done
}

# Tcl and Tk are half C and half script: without these directories the
# interpreter comes up and then fails on its own init.tcl.
stage_tcl_library() {
    for dir in tcl8.6 tk8.6 tcl8; do
        [ -d "$TCLTK/lib/$dir" ] || die "$TCLTK/lib/$dir is missing"
        cp -R "$TCLTK/lib/$dir" "$APP/Contents/lib/"
    done
    # A megabyte of example programs nobody will run from here.
    rm -rf "$APP/Contents/lib/tk8.6/demos"
    say "  bundled the Tcl/Tk runtime"
}

stage_models() {
    for name in ${INSTALLER_MODELS:-}; do
        if [ ! -d "$MODELS_DIR/$name" ]; then
            say "  skipped $name (not in models/; run 'make models' to bundle it)"
            continue
        fi
        mkdir -p "$APP/Contents/Resources/models"
        cp -R "$MODELS_DIR/$name" "$APP/Contents/Resources/models/"
        say "  bundled model $name"
    done
}

stage_documents() {
    for name in README.md LICENSE LICENSE.txt COPYING; do
        [ -f "$ROOT/$name" ] && cp "$ROOT/$name" "$APP/Contents/Resources/"
    done
    for name in "$VOSK"/*LICENSE* "$VOSK"/*COPYING*; do
        [ -f "$name" ] && cp "$name" "$APP/Contents/Resources/"
    done
    return 0
}

# --------------------------------------------------------------------------
# Signing
#
# Apple silicon runs no unsigned native code at all, so at the very least
# every Mach-O file is signed ad hoc -- a signature vouching for nothing but
# the file's integrity. With a Developer ID identity the same steps produce a
# signature Gatekeeper accepts; notarising the result afterwards is up to the
# person holding the certificate (xcrun notarytool).
# --------------------------------------------------------------------------

sign_bundle() {
    if [ "$CODESIGN_IDENTITY" = "-" ]; then
        say "signing ad hoc (set CODESIGN_IDENTITY for a Developer ID signature)"
        options=""
    else
        say "signing with: $CODESIGN_IDENTITY"
        options="--timestamp --options runtime"
    fi

    # Innermost first: the bundle's own signature seals what is inside it.
    for target in "$APP"/Contents/lib/*.dylib "$APP"/Contents/MacOS/voiceannotate-cli "$APP"; do
        sign "$target"
    done
    codesign --verify --deep --strict "$APP" || die "the signed bundle does not verify"
}

# The linker signs ad hoc on its own, so codesign remarks on every file that it
# is replacing a signature. True, and not worth a line each.
sign() {
    # shellcheck disable=SC2086
    if ! codesign --force --sign "$CODESIGN_IDENTITY" $options "$1" 2>"$STAGE/codesign.log"; then
        cat "$STAGE/codesign.log" >&2
        die "signing $(basename "$1") failed"
    fi
    grep -v "replacing existing signature" "$STAGE/codesign.log" >&2 || true
    rm -f "$STAGE/codesign.log"
}

# --------------------------------------------------------------------------
# Packing
# --------------------------------------------------------------------------

build_installer() {
    mkdir -p "$DIST"
    output="$DIST/voiceannotate-$VERSION-macos.pkg"
    work="$STAGE/pkg"
    rm -rf "$work"
    mkdir -p "$work/packages" "$work/resources"

    # The component package: the .app and where it goes. The Installer maps
    # /Applications to ~/Applications when the user installs for themselves.
    say "packing the application"
    pkgbuild --quiet \
        --component "$APP" \
        --install-location /Applications \
        --identifier "$BUNDLE_ID" \
        --version "$VERSION" \
        "$work/packages/voiceannotate.pkg" || die "pkgbuild failed"

    # The pages the Installer shows, one directory per language; it picks the
    # one matching the machine's language and falls back to English.
    cp -R "$RESOURCES/en.lproj" "$RESOURCES/fr.lproj" "$work/resources/"
    sed -e "s|@VERSION@|$VERSION|g" \
        -e "s|@BUNDLE_ID@|$BUNDLE_ID|g" \
        -e "s|@MACOS_MIN@|$MACOS_MIN|g" \
        -e "s|@COMPONENT_PKG@|voiceannotate.pkg|g" \
        "$RESOURCES/distribution.xml" > "$work/distribution.xml"

    say "packing the installer"
    set -- --distribution "$work/distribution.xml" \
           --resources "$work/resources" \
           --package-path "$work/packages" \
           --version "$VERSION"
    if [ -n "$INSTALLER_IDENTITY" ]; then
        say "signing the installer with: $INSTALLER_IDENTITY"
        set -- "$@" --sign "$INSTALLER_IDENTITY" --timestamp
    fi
    productbuild --quiet "$@" "$output" || die "productbuild failed"

    rm -rf "$work"
    say "installer ready: dist/$(basename "$output") ($(du -h "$output" | cut -f1))"
    if [ "$CODESIGN_IDENTITY" = "-" ]; then
        say "note: unsigned by a Developer ID, so on another Mac the first launch goes through"
        say "      right-click > Open, or Privacy & Security > Open Anyway (the installer says so too)"
    fi
}

check_inputs
stage_bundle
sign_bundle

if [ "$STAGE_ONLY" = 1 ]; then
    say "bundle ready: build/stage/voiceannotate.app ($(du -sh "$APP" | cut -f1))"
    say "run 'open build/stage/voiceannotate.app' to try it before packing"
    exit 0
fi

build_installer
