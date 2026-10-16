# shellcheck shell=bash
# Shared helpers for the benchmark/validation scripts. Source, don't run.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT"
[[ -f .env ]] && set -a && . ./.env && set +a

TEST_PORT="${TEST_PORT:-18080}"
TEST_NAME="${TEST_NAME:-qwen38-test}"
BASE_URL="http://127.0.0.1:${TEST_PORT}"

# start_server <extra llama-server args...>
# Starts a throwaway server from the compose `llama` service definition
# (same image/devices/env), but with the given args instead of .env's.
start_server() {
    stop_server
    docker compose run -d --name "$TEST_NAME" --no-deps \
        -p "127.0.0.1:${TEST_PORT}:8080" llama \
        --host 0.0.0.0 --port 8080 -ngl 999 --fit off -np 1 --jinja "$@" >/dev/null
}

stop_server() {
    docker rm -f "$TEST_NAME" >/dev/null 2>&1 || true
}

# wait_server [timeout_s] -> 0 when /health is ok, 1 if the container died/timed out.
wait_server() {
    local t="${1:-900}" i
    for ((i = 0; i < t; i += 2)); do
        if curl -fs "$BASE_URL/health" >/dev/null 2>&1; then return 0; fi
        if [[ "$(docker inspect -f '{{.State.Running}}' "$TEST_NAME" 2>/dev/null)" != true ]]; then return 1; fi
        sleep 2
    done
    return 1
}

server_logs() { docker logs "$TEST_NAME" 2>&1; }

# VRAM used on the XTX (card index 0 in rocm-smi), MiB.
vram_used_mib() {
    rocm-smi -d 0 --showmeminfo vram --json 2>/dev/null | grep "^{" |
        python3 -c 'import json,sys; d=json.load(sys.stdin); c=next(iter(d.values())); print(int(c["VRAM Total Used Memory (B)"])//2**20)'
}

auth_header() { echo "Authorization: Bearer ${API_KEY}"; }

# wikitext-2 test split -> data/wiki.test.raw (~1.3 MB, ~300K tokens).
# Used as filler/haystack text and as the KLD corpus.
ensure_wikitext() {
    [[ -f data/wiki.test.raw ]] && return
    mkdir -p data
    local tmp; tmp=$(mktemp -d)
    curl -fsSL -o "$tmp/w.zip" https://huggingface.co/datasets/ggml-org/ci/resolve/main/wikitext-2-raw-v1.zip
    python3 -I -c 'import sys,zipfile; z=zipfile.ZipFile(sys.argv[1]); open(sys.argv[2],"wb").write(z.read("wikitext-2-raw/wiki.test.raw"))' "$tmp/w.zip" data/wiki.test.raw
    rm -rf "$tmp"
}
