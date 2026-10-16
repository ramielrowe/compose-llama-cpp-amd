#
# llama.cpp built from source with the HIP backend, for gfx1100 (RX 7900 XTX) only.
#
# Build via scripts/build.sh (resolves LLAMA_REF to a commit SHA so a moving
# ref like `master` never hits a stale layer cache), or `docker compose build`.

ARG ROCM_IMAGE=docker.io/rocm/dev-ubuntu-26.04:10.1.0-full

FROM ${ROCM_IMAGE} AS build

ARG LLAMA_REPO=https://github.com/ggml-org/llama.cpp
ARG LLAMA_REF=b11679
ARG GPU_TARGETS=gfx1100
# Every K/V cache type pair we may run with flash attention must be compiled in;
# a pair that isn't falls off the fused FA path (pp ~3x and tg ~25% slower on
# this card). Keep this in sync with the CTK/CTV values in .env and bench.sh.
ARG FA_QUANTS="f16-f16;q8_0-q8_0;q8_0-q5_1;q5_1-q5_1;q8_0-q4_0;q5_0-q5_0;q4_0-q4_0"

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git libssl-dev ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*

# Blobless fetch keeps full commit history, so `git rev-list --count` (the
# llama.cpp build number) is correct, without downloading every old blob.
WORKDIR /src
RUN git init -q . \
    && git remote add origin "${LLAMA_REPO}" \
    && git fetch -q --filter=blob:none origin "${LLAMA_REF}" \
    && git checkout -q FETCH_HEAD

RUN HIPCXX="$(hipconfig -l)/clang" HIP_PATH="$(hipconfig -R)" \
    cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_HIP=ON \
        -DGPU_TARGETS="${GPU_TARGETS}" \
        -DGGML_CUDA_FA_QUANTS="${FA_QUANTS}" \
        -DGGML_NATIVE=ON \
        -DGGML_CCACHE=OFF \
        -DLLAMA_BUILD_TESTS=OFF \
        -DLLAMA_BUILD_EXAMPLES=OFF \
    && cmake --build build -j"$(nproc)" \
        --target llama-server llama-bench llama-perplexity llama-cli

RUN mkdir -p /app/lib \
    && cp build/bin/llama-server build/bin/llama-bench build/bin/llama-perplexity build/bin/llama-cli /app/ \
    && find build -name '*.so*' -exec cp -P {} /app/lib/ \; \
    && { \
        echo "llama_ref=${LLAMA_REF}"; \
        echo "llama_sha=$(git rev-parse HEAD)"; \
        echo "llama_build=b$(git rev-list --count HEAD)"; \
        echo "rocm=$(cat /opt/rocm/.info/version 2>/dev/null || hipconfig --version)"; \
        echo "hip_clang=$("$(hipconfig -l)/clang" --version | head -1)"; \
        echo "gpu_targets=${GPU_TARGETS}"; \
        echo "fa_quants=${FA_QUANTS}"; \
        echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
    } > /app/BUILD_INFO \
    && cat /app/BUILD_INFO

# Runtime: same base, since rocBLAS/hipBLASLt load their per-arch kernel
# libraries from /opt/rocm at runtime. The base layers are shared with the
# build stage, so this costs no extra disk.
FROM ${ROCM_IMAGE} AS server

RUN apt-get update \
    && apt-get install -y --no-install-recommends libgomp1 curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/ /app/
ENV LD_LIBRARY_PATH=/app/lib
ENV PATH=/app:${PATH}
WORKDIR /app

ARG LLAMA_REF=b11679
LABEL org.opencontainers.image.title="llama.cpp HIP gfx1100" \
      org.opencontainers.image.version="${LLAMA_REF}"

# v0.7.0 moved llama-server's default port to 9931; pin it to 8080 in-container.
ENV LLAMA_ARG_HOST=0.0.0.0
ENV LLAMA_ARG_PORT=8080
HEALTHCHECK --interval=15s --timeout=5s --start-period=10m \
    CMD curl -fs http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/llama-server"]
