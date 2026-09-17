# voiceannotate -- speech to text with speaker annotation
#
# One Makefile for Windows (MSYS2/MinGW), Linux and macOS. Everything that
# differs between them is gathered in the block below; the rules themselves are
# platform neutral.
#
#   make deps      download minimp3 and the Vosk library into the tree
#   make models    download a language model and the speaker model
#   make           build bin/voiceannotate and bin/voiceannotate-cli
#   make run       build and launch the interface
#   make check     build and run the self-tests
#   make install   install to $(PREFIX), default /usr/local
#
# Useful overrides:
#   make DEBUG=1                 -O0 -g, assertions on
#   make CXX=clang++
#   make TCLTK_CFLAGS=... TCLTK_LIBS=...   when Tcl/Tk is somewhere unusual

# --------------------------------------------------------------------------
# Platform
# --------------------------------------------------------------------------

UNAME_S := $(shell uname -s 2>/dev/null || echo unknown)

ifneq (,$(findstring MINGW,$(UNAME_S)))
  PLATFORM := windows
else ifneq (,$(findstring MSYS,$(UNAME_S)))
  PLATFORM := windows
else ifneq (,$(findstring CYGWIN,$(UNAME_S)))
  PLATFORM := windows
else ifeq ($(UNAME_S),Darwin)
  PLATFORM := macos
else
  PLATFORM := linux
endif

ifeq ($(PLATFORM),windows)
  EXE := .exe
else
  EXE :=
endif

# --------------------------------------------------------------------------
# Layout
# --------------------------------------------------------------------------

SRC_DIR      := src
TCL_DIR      := tcl
BUILD_DIR    := build
OBJ_DIR      := $(BUILD_DIR)/obj
BIN_DIR      := bin
VENDOR_DIR   := vendor/vosk
MINIMP3_DIR  := third_party/minimp3
MODELS_DIR   := models
TESTS_DIR    := tests

GUI_BIN  := $(BIN_DIR)/voiceannotate$(EXE)
CLI_BIN  := $(BIN_DIR)/voiceannotate-cli$(EXE)
TEST_BIN := $(BIN_DIR)/voiceannotate-tests$(EXE)

PREFIX ?= /usr/local

# --------------------------------------------------------------------------
# Toolchain
# --------------------------------------------------------------------------

CXX ?= g++
PKG_CONFIG ?= pkg-config

WARNINGS := -Wall -Wextra -Wpedantic -Wshadow -Wno-unused-parameter

ifdef DEBUG
  OPTIMIZE := -O0 -g
else
  OPTIMIZE := -O2 -DNDEBUG
endif

BASE_CXXFLAGS := -std=c++17 $(WARNINGS) $(OPTIMIZE) -I$(SRC_DIR) \
                 -I$(VENDOR_DIR)/include -I$(MINIMP3_DIR)

# --------------------------------------------------------------------------
# Tcl/Tk discovery
#
# pkg-config first, since that is how every Linux distribution and Homebrew
# ship it. Homebrew's plain "tcl-tk" formula now installs Tcl/Tk 9, which
# ships no pkg-config files and has a different C API than this project
# targets, so on macOS we also look for the keg-only "tcl-tk@8" formula
# (8.6.x) via `brew --prefix`, since that one is never on PKG_CONFIG_PATH by
# default. macOS with neither falls back to the system frameworks.
# --------------------------------------------------------------------------

ifeq ($(PLATFORM),macos)
  BREW_TCLTK8_PREFIX := $(shell command -v brew >/dev/null 2>&1 && brew --prefix tcl-tk@8 2>/dev/null)
endif

ifeq ($(origin TCLTK_CFLAGS), undefined)
  TCLTK_CFLAGS := $(shell $(PKG_CONFIG) --cflags tcl tk 2>/dev/null)
  ifeq ($(strip $(TCLTK_CFLAGS)),)
    TCLTK_CFLAGS := $(shell $(PKG_CONFIG) --cflags tcl8.6 tk8.6 2>/dev/null)
  endif
  ifeq ($(strip $(TCLTK_CFLAGS)),)
    ifneq ($(strip $(BREW_TCLTK8_PREFIX)),)
      TCLTK_CFLAGS := $(shell PKG_CONFIG_PATH="$(BREW_TCLTK8_PREFIX)/lib/pkgconfig" $(PKG_CONFIG) --cflags tcl tk 2>/dev/null)
    endif
  endif
endif

ifeq ($(origin TCLTK_LIBS), undefined)
  TCLTK_LIBS := $(shell $(PKG_CONFIG) --libs tcl tk 2>/dev/null)
  ifeq ($(strip $(TCLTK_LIBS)),)
    TCLTK_LIBS := $(shell $(PKG_CONFIG) --libs tcl8.6 tk8.6 2>/dev/null)
  endif
  ifeq ($(strip $(TCLTK_LIBS)),)
    ifneq ($(strip $(BREW_TCLTK8_PREFIX)),)
      TCLTK_LIBS := $(shell PKG_CONFIG_PATH="$(BREW_TCLTK8_PREFIX)/lib/pkgconfig" $(PKG_CONFIG) --libs tcl tk 2>/dev/null)
    endif
  endif
endif

ifeq ($(strip $(TCLTK_LIBS)),)
  ifeq ($(PLATFORM),macos)
    TCLTK_CFLAGS := -I/usr/local/opt/tcl-tk/include -I/opt/homebrew/opt/tcl-tk/include
    TCLTK_LIBS   := -framework Tcl -framework Tk
  else
    TCLTK_CFLAGS := -I/usr/include/tcl8.6 -I/usr/include/tcl
    TCLTK_LIBS   := -ltcl8.6 -ltk8.6
  endif
endif

# The interpreter the interface test runs under. Whatever pkg-config pointed the
# build at, so the test exercises the same Tcl the application links against.
ifeq ($(strip $(BREW_TCLTK8_PREFIX)),)
  TCLSH ?= tclsh
else
  TCLSH ?= $(BREW_TCLTK8_PREFIX)/bin/tclsh
endif

# --------------------------------------------------------------------------
# Vosk and link flags
#
# The library is loaded from the tree at run time. On Unix an rpath relative to
# the executable does that; on Windows the DLL is staged next to the binary,
# which is where the loader looks.
# --------------------------------------------------------------------------

VOSK_LIBS := -L$(VENDOR_DIR)/lib -lvosk

ifeq ($(PLATFORM),linux)
  # Three places, in order: the build tree, beside the binary, and ../lib for
  # an installed copy. Absolute paths are avoided so the tree stays movable.
  RPATH_FLAGS := -Wl,-rpath,'$$ORIGIN/../$(VENDOR_DIR)/lib' -Wl,-rpath,'$$ORIGIN' \
                 -Wl,-rpath,'$$ORIGIN/../lib'
  PLATFORM_LIBS := -lpthread -ldl
  VOSK_RUNTIME := $(VENDOR_DIR)/lib/libvosk.so
  VOSK_RUNTIME_DEST := lib
else ifeq ($(PLATFORM),macos)
  RPATH_FLAGS := -Wl,-rpath,@executable_path/../$(VENDOR_DIR)/lib -Wl,-rpath,@executable_path \
                 -Wl,-rpath,@executable_path/../lib
  PLATFORM_LIBS := -lpthread
  VOSK_RUNTIME := $(VENDOR_DIR)/lib/libvosk.dylib
  VOSK_RUNTIME_DEST := lib
else
  RPATH_FLAGS :=
  PLATFORM_LIBS :=
  # Windows has no rpath: the loader looks beside the executable, so the DLL
  # is installed into bin/ rather than lib/.
  VOSK_RUNTIME := $(VENDOR_DIR)/bin/libvosk.dll
  VOSK_RUNTIME_DEST := bin
  # MinGW needs the threading runtime spelled out for std::thread.
  BASE_CXXFLAGS += -D_WIN32_WINNT=0x0601
endif

# A GUI-subsystem binary on Windows, so no console window appears behind it.
ifeq ($(PLATFORM),windows)
  GUI_LDFLAGS := -mwindows -static-libgcc -static-libstdc++
else
  GUI_LDFLAGS :=
endif

# --------------------------------------------------------------------------
# Sources
# --------------------------------------------------------------------------

CORE_SOURCES := \
  $(SRC_DIR)/audio/audio_source.cpp \
  $(SRC_DIR)/audio/mp3_decoder.cpp \
  $(SRC_DIR)/audio/wav_reader.cpp \
  $(SRC_DIR)/audio/resampler.cpp \
  $(SRC_DIR)/core/pipeline.cpp \
  $(SRC_DIR)/core/transcript.cpp \
  $(SRC_DIR)/stt/diarizer.cpp \
  $(SRC_DIR)/stt/vosk_engine.cpp \
  $(SRC_DIR)/util/json.cpp

GUI_SOURCES := $(SRC_DIR)/main.cpp $(SRC_DIR)/tcl/tcl_app.cpp
ifeq ($(PLATFORM),windows)
  GUI_SOURCES += $(SRC_DIR)/platform/win_main.cpp
endif

CLI_SOURCES  := $(SRC_DIR)/cli_main.cpp
TEST_SOURCES := $(TESTS_DIR)/run_tests.cpp

CORE_OBJECTS := $(CORE_SOURCES:$(SRC_DIR)/%.cpp=$(OBJ_DIR)/%.o)
GUI_OBJECTS  := $(GUI_SOURCES:$(SRC_DIR)/%.cpp=$(OBJ_DIR)/%.o)
CLI_OBJECTS  := $(CLI_SOURCES:$(SRC_DIR)/%.cpp=$(OBJ_DIR)/%.o)
TEST_OBJECTS := $(TEST_SOURCES:$(TESTS_DIR)/%.cpp=$(OBJ_DIR)/tests/%.o)

DEPFILES := $(CORE_OBJECTS:.o=.d) $(GUI_OBJECTS:.o=.d) $(CLI_OBJECTS:.o=.d) $(TEST_OBJECTS:.o=.d)

# Staged DLLs that must sit beside the executable on Windows.
ifeq ($(PLATFORM),windows)
  STAGED_DLLS := $(BIN_DIR)/libvosk.dll
else
  STAGED_DLLS :=
endif

# --------------------------------------------------------------------------
# Rules
# --------------------------------------------------------------------------

.PHONY: all gui cli check check-core check-ui run deps models clean distclean \
        install uninstall print-config help

all: gui cli

gui: $(GUI_BIN)
cli: $(CLI_BIN)

# The header is downloaded, not vendored, so every object that could include it
# waits for it to exist.
$(MINIMP3_DIR)/minimp3.h:
	@echo "minimp3 is missing; fetching it"
	@$(SHELL) scripts/fetch-deps.sh minimp3

$(VENDOR_DIR)/include/vosk_api.h:
	@echo "the Vosk library is missing; fetching it"
	@$(SHELL) scripts/fetch-deps.sh vosk

$(OBJ_DIR)/%.o: $(SRC_DIR)/%.cpp | $(MINIMP3_DIR)/minimp3.h $(VENDOR_DIR)/include/vosk_api.h
	@mkdir -p $(dir $@)
	$(CXX) $(BASE_CXXFLAGS) $(TCLTK_CFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(OBJ_DIR)/tests/%.o: $(TESTS_DIR)/%.cpp | $(MINIMP3_DIR)/minimp3.h $(VENDOR_DIR)/include/vosk_api.h
	@mkdir -p $(dir $@)
	$(CXX) $(BASE_CXXFLAGS) $(CXXFLAGS) -MMD -MP -c $< -o $@

$(GUI_BIN): $(CORE_OBJECTS) $(GUI_OBJECTS) $(STAGED_DLLS)
	@mkdir -p $(BIN_DIR)
	$(CXX) $(CORE_OBJECTS) $(GUI_OBJECTS) -o $@ \
	  $(GUI_LDFLAGS) $(TCLTK_LIBS) $(VOSK_LIBS) $(PLATFORM_LIBS) $(RPATH_FLAGS) $(LDFLAGS)

$(CLI_BIN): $(CORE_OBJECTS) $(CLI_OBJECTS) $(STAGED_DLLS)
	@mkdir -p $(BIN_DIR)
	$(CXX) $(CORE_OBJECTS) $(CLI_OBJECTS) -o $@ \
	  $(VOSK_LIBS) $(PLATFORM_LIBS) $(RPATH_FLAGS) $(LDFLAGS)

$(TEST_BIN): $(CORE_OBJECTS) $(TEST_OBJECTS) $(STAGED_DLLS)
	@mkdir -p $(BIN_DIR)
	$(CXX) $(CORE_OBJECTS) $(TEST_OBJECTS) -o $@ \
	  $(VOSK_LIBS) $(PLATFORM_LIBS) $(RPATH_FLAGS) $(LDFLAGS)

$(BIN_DIR)/libvosk.dll: $(VENDOR_DIR)/bin/libvosk.dll
	@mkdir -p $(BIN_DIR)
	cp $< $@

# "./" is needed for a relative path and wrong for an absolute one, which is
# what BIN_DIR becomes when the binaries are staged outside the tree.
RUN := $(if $(filter /%,$(BIN_DIR)),,./)

check: check-core check-ui

check-core: $(TEST_BIN)
	$(RUN)$(TEST_BIN)

# Exercises the Tk script with the C++ commands stubbed out. Needs a display;
# on a headless machine run it under Xvfb, or use check-core alone.
#
# tclsh, not wish: wish on macOS reports neither the exit status nor the output
# of the script it runs, so a failing test would go through unnoticed. The
# script pulls Tk in by itself. The status has to reach make, hence the "if"
# rather than "&& ... || echo": the shell would swallow a failure as the "or".
check-ui:
	@if command -v $(TCLSH) >/dev/null 2>&1; then \
	  $(TCLSH) $(TESTS_DIR)/ui_smoke.tcl; \
	else \
	  echo "check-ui: skipped ('$(TCLSH)' is not on PATH)"; \
	fi

run: $(GUI_BIN)
	$(RUN)$(GUI_BIN)

deps:
	$(SHELL) scripts/fetch-deps.sh deps

models:
	$(SHELL) scripts/fetch-deps.sh models

install: all
	install -d $(DESTDIR)$(PREFIX)/bin
	install -d $(DESTDIR)$(PREFIX)/$(VOSK_RUNTIME_DEST)
	install -d $(DESTDIR)$(PREFIX)/share/voiceannotate
	install -m 755 $(GUI_BIN) $(DESTDIR)$(PREFIX)/bin/
	install -m 755 $(CLI_BIN) $(DESTDIR)$(PREFIX)/bin/
	install -m 644 $(TCL_DIR)/app.tcl $(DESTDIR)$(PREFIX)/share/voiceannotate/
	# Without this the installed binaries have no Vosk to load.
	install -m 755 $(VOSK_RUNTIME) $(DESTDIR)$(PREFIX)/$(VOSK_RUNTIME_DEST)/
	@echo "installed to $(DESTDIR)$(PREFIX)"

uninstall:
	rm -f $(DESTDIR)$(PREFIX)/bin/voiceannotate$(EXE)
	rm -f $(DESTDIR)$(PREFIX)/bin/voiceannotate-cli$(EXE)
	rm -f $(DESTDIR)$(PREFIX)/$(VOSK_RUNTIME_DEST)/$(notdir $(VOSK_RUNTIME))
	rm -rf $(DESTDIR)$(PREFIX)/share/voiceannotate

clean:
	rm -rf $(BUILD_DIR) $(BIN_DIR)

# Also drops the downloads. Models are large; distclean keeps them on purpose.
distclean: clean
	rm -rf $(VENDOR_DIR) $(MINIMP3_DIR) .cache

print-config:
	@echo "platform      : $(PLATFORM) ($(UNAME_S))"
	@echo "compiler      : $(CXX)"
	@echo "tcl/tk cflags : $(TCLTK_CFLAGS)"
	@echo "tcl/tk libs   : $(TCLTK_LIBS)"
	@echo "vosk libs     : $(VOSK_LIBS)"
	@echo "gui binary    : $(GUI_BIN)"
	@echo "cli binary    : $(CLI_BIN)"
	@echo "prefix        : $(PREFIX)"

help:
	@echo "targets: all gui cli check check-core check-ui run deps models install uninstall clean distclean print-config"

-include $(DEPFILES)
