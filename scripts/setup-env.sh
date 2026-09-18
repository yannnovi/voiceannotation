#!/usr/bin/env bash
#
# Prepares a shell for "make": puts the toolchain on PATH, points pkg-config at
# Tcl/Tk, picks the right make, checks that nothing is missing -- then builds.
#
# On Windows the compiler lives in MSYS2 while the shell is often Git Bash,
# which ships neither gcc nor make; this script bridges the two. On Linux and
# macOS there is nothing to bridge, so it only verifies the prerequisites and
# names the package to install when one is absent.
#
# Usage:
#   . scripts/setup-env.sh              configure the current shell, build nothing
#   scripts/setup-env.sh                configure, then "make"
#   scripts/setup-env.sh check          configure, then "make check" (any target)
#   scripts/setup-env.sh --verify-only  report the environment and stop
#   scripts/setup-env.sh --install-deps install what is missing, then build
#
# Environment:
#   MSYS2_ROOT   MSYS2 installation to use, when it is somewhere unusual
#   MSYSTEM      MINGW64 (default), UCRT64 or CLANG64 -- which MSYS2 toolchain
#
# Sourcing it leaves PATH, PKG_CONFIG_PATH and MAKE set in the current shell,
# so plain "make" works there for the rest of the session.

# --------------------------------------------------------------------------
# Sourced or executed? Sourcing must never exit the user's shell, so the whole
# body is a function and the tail below turns its status into the right thing.
# --------------------------------------------------------------------------

if [ -n "${BASH_SOURCE:-}" ] && [ "${BASH_SOURCE[0]}" != "$0" ]; then
    VA_SOURCED=1
else
    VA_SOURCED=0
fi

VA_SELF="${BASH_SOURCE[0]}"

va_say()  { printf '==> %s\n' "$*"; }
va_warn() { printf 'warning: %s\n' "$*" >&2; }
va_err()  { printf 'error: %s\n' "$*" >&2; }
va_have() { command -v "$1" >/dev/null 2>&1; }

va_usage() {
    sed -n '11,21p' "$VA_SELF" | sed 's/^#\{1,\} \{0,1\}//'
}

# Prepends to PATH, but only once: sourcing the script twice in the same shell
# should not grow PATH.
va_path_prepend() {
    case ":$PATH:" in
        *":$1:"*) ;;
        *) PATH="$1:$PATH" ;;
    esac
}

va_detect_platform() {
    case "$(uname -s 2>/dev/null || echo unknown)" in
        MINGW*|MSYS*|CYGWIN*) echo windows ;;
        Darwin)               echo macos ;;
        Linux)                echo linux ;;
        *)                    echo unknown ;;
    esac
}

# --------------------------------------------------------------------------
# Windows: find MSYS2 and put its toolchain first
# --------------------------------------------------------------------------

# The subdirectory matching MSYSTEM, which is how MSYS2 names its toolchains.
va_msys_subdir() {
    case "${MSYSTEM:-MINGW64}" in
        UCRT64)     echo ucrt64 ;;
        CLANG64)    echo clang64 ;;
        CLANGARM64) echo clangarm64 ;;
        MINGW32)    echo mingw32 ;;
        *)          echo mingw64 ;;
    esac
}

va_find_msys2() {
    local subdir root posix
    subdir=$(va_msys_subdir)
    for root in \
        "${MSYS2_ROOT:-}" \
        "${USERPROFILE:-}/scoop/apps/msys2/current" \
        "C:/msys64" \
        "${LOCALAPPDATA:-}/Programs/msys64" \
        "C:/Program Files/msys64" \
        "C:/tools/msys64"
    do
        [ -n "$root" ] || continue
        # Everything here starts out as "C:\..." -- a drive letter that bash
        # would read as a PATH separator. cygpath turns it into /c/... first.
        posix=$(cygpath -u "$root" 2>/dev/null) || posix="$root"
        if [ -x "$posix/$subdir/bin/g++.exe" ]; then
            printf '%s\n' "$posix"
            return 0
        fi
    done
    return 1
}

va_setup_windows() {
    local subdir
    # An MSYS2 shell already has everything; only Git Bash and the like need
    # the bridge. pacman is the tell: it exists nowhere else.
    if va_have pacman && va_have g++; then
        VA_IN_MSYS2_SHELL=1
        va_say "shell   : MSYS2 ${MSYSTEM:-MINGW64}, used as is"
    else
        VA_IN_MSYS2_SHELL=0
        if ! VA_MSYS2_ROOT=$(va_find_msys2); then
            va_err "MSYS2 not found (looked for $(va_msys_subdir)/bin/g++.exe)"
            va_err "install it from https://www.msys2.org/, or set MSYS2_ROOT"
            return 1
        fi
        subdir=$(va_msys_subdir)
        va_say "shell   : $(basename "${SHELL:-sh}"), borrowing MSYS2 at $VA_MSYS2_ROOT ($subdir)"
        va_path_prepend "$VA_MSYS2_ROOT/$subdir/bin"
        export PKG_CONFIG_PATH="$VA_MSYS2_ROOT/$subdir/lib/pkgconfig${PKG_CONFIG_PATH:+:$PKG_CONFIG_PATH}"
        export MSYSTEM="${MSYSTEM:-MINGW64}"
        # MSYS2's usr/bin is deliberately left out. Its msys-2.0.dll is a
        # different build from the one Git Bash has already loaded, and two of
        # them in one process tree break fork. Everything the build needs from
        # there -- sh, uname, cp, unzip -- Git Bash provides itself.
    fi

    # mingw32-make is a native Windows binary, so it runs under any shell.
    # Inside MSYS2, "make" is present and is what the README tells people to
    # run, so prefer it there.
    if [ "$VA_IN_MSYS2_SHELL" = 1 ] && va_have make; then
        VA_MAKE=make
    elif va_have mingw32-make; then
        VA_MAKE=mingw32-make
    elif va_have make; then
        VA_MAKE=make
    else
        VA_MAKE=
    fi
}

# --------------------------------------------------------------------------
# What to install when something is missing
# --------------------------------------------------------------------------

va_install_command() {
    local pfx
    case "$VA_PLATFORM" in
        windows)
            case "${MSYSTEM:-MINGW64}" in
                UCRT64)  pfx=mingw-w64-ucrt-x86_64 ;;
                CLANG64) pfx=mingw-w64-clang-x86_64 ;;
                MINGW32) pfx=mingw-w64-i686 ;;
                *)       pfx=mingw-w64-x86_64 ;;
            esac
            echo "pacman -S --needed $pfx-gcc $pfx-make $pfx-pkgconf $pfx-tcl $pfx-tk make unzip"
            ;;
        macos)
            echo "brew install tcl-tk@8 pkg-config"
            ;;
        *)
            if va_have apt; then
                echo "sudo apt install build-essential pkg-config tcl-dev tk-dev curl unzip"
            elif va_have dnf; then
                echo "sudo dnf install gcc-c++ make pkgconf tcl-devel tk-devel curl unzip"
            elif va_have pacman; then
                echo "sudo pacman -S base-devel tcl tk curl unzip"
            else
                echo "install a C++17 compiler, make, pkg-config, the Tcl/Tk headers, curl and unzip"
            fi
            ;;
    esac
}

# Outside MSYS2 pacman runs through msys2_shell.cmd rather than directly, for
# the runtime reason given above: pacman forks, and a foreign msys-2.0.dll in
# the process tree is exactly what it cannot survive.
va_install_deps() {
    local cmd shell_cmd
    cmd=$(va_install_command)
    if [ "$VA_PLATFORM" != windows ]; then
        va_err "run this yourself, it needs a password: $cmd"
        return 1
    fi
    va_say "installing: $cmd"
    if [ "$VA_IN_MSYS2_SHELL" = 1 ]; then
        $cmd --noconfirm
        return $?
    fi
    shell_cmd="$VA_MSYS2_ROOT/msys2_shell.cmd"
    if [ ! -f "$shell_cmd" ]; then
        va_err "$shell_cmd not found; run this in an MSYS2 shell: $cmd"
        return 1
    fi
    MSYS2_ARG_CONV_EXCL='*' cmd.exe //c "$(cygpath -w "$shell_cmd")" \
        -defterm -no-start -here -mingw64 -c "$cmd --noconfirm"
}

# The build shells out to all of these. tclsh is not among them: it only serves
# "make check-ui", which skips itself when it is absent.
VA_REQUIRED_EXTRA="g++ pkg-config curl unzip"

va_missing_tools() {
    local tool missing=""
    for tool in "${VA_MAKE:-make}" $VA_REQUIRED_EXTRA; do
        va_have "$tool" || missing="$missing $tool"
    done
    printf '%s' "$missing"
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------

va_setup_env() {
    local missing
    VA_DO_INSTALL=0
    VA_VERIFY_ONLY=0
    VA_TARGETS=()

    while [ $# -gt 0 ]; do
        case "$1" in
            -h|--help)      va_usage; return 0 ;;
            --install-deps) VA_DO_INSTALL=1 ;;
            --verify-only)  VA_VERIFY_ONLY=1 ;;
            *)              VA_TARGETS+=("$1") ;;
        esac
        shift
    done

    VA_ROOT=$(cd "$(dirname "$VA_SELF")/.." && pwd)
    VA_PLATFORM=$(va_detect_platform)
    VA_IN_MSYS2_SHELL=0
    VA_MSYS2_ROOT=
    VA_MAKE=

    va_say "project : $VA_ROOT"
    va_say "platform: $VA_PLATFORM ($(uname -s 2>/dev/null))"

    case "$VA_PLATFORM" in
        windows)
            va_setup_windows || return 1
            ;;
        *)
            if va_have make; then VA_MAKE=make
            elif va_have gmake; then VA_MAKE=gmake
            fi
            ;;
    esac

    export PATH
    [ -n "$VA_MAKE" ] && export MAKE="$VA_MAKE"

    missing=$(va_missing_tools)
    if [ -n "$missing" ] && [ "$VA_DO_INSTALL" = 1 ]; then
        va_install_deps || return 1
        hash -r 2>/dev/null
        missing=$(va_missing_tools)
    fi

    if [ -n "$missing" ]; then
        va_err "missing:$missing"
        va_err "install with: $(va_install_command)"
        [ "$VA_DO_INSTALL" = 1 ] || va_err "or re-run this script with --install-deps"
        return 1
    fi

    va_have tclsh || va_warn "tclsh is not on PATH; 'make check-ui' will skip itself"

    if ! pkg-config --exists tcl tk 2>/dev/null && ! pkg-config --exists tcl8.6 tk8.6 2>/dev/null; then
        va_warn "pkg-config knows no tcl/tk; the Makefile will fall back to guessed paths"
        va_warn "if the link then fails: make TCLTK_CFLAGS=... TCLTK_LIBS=..."
    fi

    va_say "make    : $(command -v "$VA_MAKE")"
    va_say "compiler: $(command -v g++) $(g++ -dumpversion 2>/dev/null)"
    va_say "tcl/tk  : $(pkg-config --modversion tcl 2>/dev/null || echo 'not through pkg-config')"

    if [ "$VA_VERIFY_ONLY" = 1 ]; then
        va_say "environment ready; nothing built (--verify-only)"
        return 0
    fi

    if [ "$VA_SOURCED" = 1 ]; then
        # A shell function, because on Windows the binary is called
        # mingw32-make: this is what makes a plain "make" work afterwards.
        if [ "$VA_MAKE" != make ]; then
            eval "make() { command $VA_MAKE \"\$@\"; }"
            va_say "environment ready; 'make' runs $VA_MAKE in this shell"
        else
            va_say "environment ready; run: make"
        fi
        return 0
    fi

    va_say "running : $VA_MAKE ${VA_TARGETS[*]}"
    ( cd "$VA_ROOT" && "$VA_MAKE" "${VA_TARGETS[@]}" )
}

va_setup_env "$@"
VA_STATUS=$?

if [ "$VA_SOURCED" = 1 ]; then
    unset -f va_say va_warn va_err va_have va_usage va_path_prepend \
             va_detect_platform va_msys_subdir va_find_msys2 va_setup_windows \
             va_install_command va_install_deps va_missing_tools va_setup_env
    unset VA_SOURCED VA_SELF VA_DO_INSTALL VA_VERIFY_ONLY VA_TARGETS \
          VA_ROOT VA_PLATFORM VA_IN_MSYS2_SHELL VA_MSYS2_ROOT VA_MAKE \
          VA_REQUIRED_EXTRA
    # VA_STATUS outlives the cleanup on purpose: it is what we return, and
    # nothing can unset it afterwards.
    return $VA_STATUS
fi
exit $VA_STATUS
