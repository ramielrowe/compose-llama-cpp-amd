#!/usr/bin/env bash
# Build the HIP and/or Vulkan images for LLAMA_REF.
#
#   scripts/build.sh                 # LLAMA_REF from .env, both backends
#   scripts/build.sh master          # bleeding edge
#   scripts/build.sh b11679 vulkan   # one backend only (hip|vulkan|all)
#
# The ref is resolved to a commit SHA first, so a moving ref (master) always
# rebuilds instead of reusing a cached clone layer. The image is tagged with
# both the ref and the SHA.
set -euo pipefail
cd "$(dirname "$0")/.."

[[ -f .env ]] && set -a && . ./.env && set +a
REF="${1:-${LLAMA_REF:-b11679}}"
REPO=https://github.com/ggml-org/llama.cpp

if [[ "$REF" =~ ^[0-9a-f]{40}$ ]]; then
    SHA="$REF"
else
    SHA=$(git ls-remote "$REPO" "refs/tags/$REF^{}" "refs/tags/$REF" "refs/heads/$REF" | head -1 | cut -f1)
    [[ -n "$SHA" ]] || { echo "cannot resolve ref '$REF'" >&2; exit 1; }
fi
echo "llama.cpp $REF -> $SHA"

WHICH="${2:-all}"

if [[ $WHICH == all || $WHICH == hip ]]; then
    docker build -f docker/rocm.Dockerfile \
        --build-arg ROCM_IMAGE="${ROCM_IMAGE:-docker.io/rocm/dev-ubuntu-26.04:10.1.0-full}" \
        --build-arg LLAMA_REF="$SHA" \
        -t "local/llama-hip:$REF" -t "local/llama-hip:${SHA:0:12}" .
    docker run --rm --entrypoint cat "local/llama-hip:$REF" /app/BUILD_INFO
fi

if [[ $WHICH == all || $WHICH == vulkan ]]; then
    docker build -f docker/vulkan.Dockerfile \
        --build-arg LLAMA_REF="$SHA" \
        -t "local/llama-vulkan:$REF" -t "local/llama-vulkan:${SHA:0:12}" .
    docker run --rm --entrypoint cat "local/llama-vulkan:$REF" /app/BUILD_INFO
fi

[[ "$REF" == "${LLAMA_REF:-}" ]] || echo "note: set LLAMA_REF=$REF in .env to serve this build"
