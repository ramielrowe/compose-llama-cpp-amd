#
# llama.cpp built from source with the Vulkan (Mesa RADV) backend.
# Same commit as the HIP image; select with BACKEND=vulkan in .env.

ARG UBUNTU_IMAGE=docker.io/library/ubuntu:26.04

FROM ${UBUNTU_IMAGE} AS build

ARG LLAMA_REPO=https://github.com/ggml-org/llama.cpp
ARG LLAMA_REF=b11679

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential cmake ninja-build git libssl-dev ca-certificates \
        libvulkan-dev glslc spirv-headers \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN git init -q . \
    && git remote add origin "${LLAMA_REPO}" \
    && git fetch -q --filter=blob:none origin "${LLAMA_REF}" \
    && git checkout -q FETCH_HEAD

RUN cmake -S . -B build -G Ninja \
        -DCMAKE_BUILD_TYPE=Release \
        -DGGML_VULKAN=ON \
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
        echo "backend=vulkan"; \
        echo "built=$(date -u +%Y-%m-%dT%H:%M:%SZ)"; \
    } > /app/BUILD_INFO

FROM ${UBUNTU_IMAGE} AS server

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        libgomp1 libvulkan1 mesa-vulkan-drivers curl ca-certificates \
    && rm -rf /var/lib/apt/lists/*

COPY --from=build /app/ /app/
ENV LD_LIBRARY_PATH=/app/lib
ENV PATH=/app:${PATH}
WORKDIR /app

ENV LLAMA_ARG_HOST=0.0.0.0
ENV LLAMA_ARG_PORT=8080
HEALTHCHECK --interval=15s --timeout=5s --start-period=10m \
    CMD curl -fs http://localhost:8080/health || exit 1

ENTRYPOINT ["/app/llama-server"]
