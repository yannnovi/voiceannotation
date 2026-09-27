# voiceannotate on the web, in one image.
#
# Two stages. The first builds the C++ engine exactly as the repository's own
# Makefile does -- `make cli`, which needs no Tcl/Tk, since the desktop
# interface has no place in a container. The second carries the binary, the
# Vosk shared library it loads, and the Python service that drives it.
#
# Build from the repository root, not from web/:
#     docker build --platform linux/amd64 -f web/Dockerfile -t voiceannotate-web .
#
# x86_64, and not by choice: Vosk publishes one Linux build and it is
# vosk-linux-x86_64. There is no aarch64 archive to fetch, so an arm64 image
# would have nothing to link against. On an Apple Silicon or ARM server the
# image therefore runs emulated, which costs perhaps a third of the speed --
# --platform is in the compose file so this is not something to remember.

# --------------------------------------------------------------------------
# 1. The engine
# --------------------------------------------------------------------------
FROM --platform=linux/amd64 debian:bookworm-slim AS engine

RUN apt-get update && apt-get install -y --no-install-recommends \
        g++ make pkg-config curl unzip ca-certificates \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src

# The sources the build reads, and nothing else: a change to the web app must
# not invalidate this layer and recompile the engine for nothing.
COPY Makefile ./
COPY scripts/fetch-deps.sh scripts/
COPY src/ src/
COPY tests/ tests/

# `make cli` fetches minimp3 and the Vosk library into the tree first.
RUN make cli -j"$(nproc)"

# The self-tests of the core -- JSON, resampling, WAV decoding, transcript
# rendering, speaker clustering. None of them needs a model or a screen, so
# they belong in the build: an image that ships a broken engine is worse than
# a build that fails.
RUN make check-core

# --------------------------------------------------------------------------
# 2. The service
# --------------------------------------------------------------------------
FROM --platform=linux/amd64 python:3.12-slim-bookworm

# libgomp is what Kaldi inside Vosk is threaded with; libstdc++ comes with the
# image's own toolchain-free runtime and is listed for the same reason -- both
# are loaded by libvosk.so, not by anything Python.
RUN apt-get update && apt-get install -y --no-install-recommends \
        libgomp1 libstdc++6 \
    && rm -rf /var/lib/apt/lists/* \
    && useradd --create-home --uid 10001 voiceannotate

ENV VA_HOME=/opt/voiceannotate
WORKDIR ${VA_HOME}

# Laid out as the binary expects to find things: it looks for libvosk.so
# through an rpath relative to itself, ../vendor/vosk/lib.
COPY --from=engine /src/bin/voiceannotate-cli   ${VA_HOME}/bin/voiceannotate-cli
COPY --from=engine /src/vendor/vosk/lib/        ${VA_HOME}/vendor/vosk/lib/

COPY web/requirements.txt ${VA_HOME}/requirements.txt
RUN pip install --no-cache-dir -r requirements.txt

COPY web/backend/  ${VA_HOME}/backend/
COPY web/frontend/ ${VA_HOME}/frontend/

ENV VA_CLI=${VA_HOME}/bin/voiceannotate-cli \
    VA_DATA_DIR=/var/lib/voiceannotate \
    VA_MODELS_DIR=/var/lib/voiceannotate/models \
    VA_MAX_CONCURRENT=4 \
    VA_MAX_PER_USER=1 \
    PYTHONUNBUFFERED=1

RUN mkdir -p /var/lib/voiceannotate/models \
    && chown -R voiceannotate:voiceannotate /var/lib/voiceannotate

USER voiceannotate
EXPOSE 8000
VOLUME ["/var/lib/voiceannotate"]

HEALTHCHECK --interval=30s --timeout=5s --start-period=10s --retries=3 \
    CMD python -c "import urllib.request,sys; \
sys.exit(0 if urllib.request.urlopen('http://127.0.0.1:8000/healthz', timeout=4).status == 200 else 1)"

# One worker on purpose. The queue, the four-at-a-time limit and the finished
# transcripts live in this process's memory; a second worker would have its
# own copy of all three and the limits would quietly become eight. The work
# itself is done by child processes, so one worker is not a bottleneck --
# what it serves is HTTP, and the transcribing happens elsewhere.
CMD ["uvicorn", "backend.main:app", "--host", "0.0.0.0", "--port", "8000", \
     "--workers", "1", "--timeout-keep-alive", "75"]
