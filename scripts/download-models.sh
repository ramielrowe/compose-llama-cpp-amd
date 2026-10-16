#!/usr/bin/env bash
# Fetch Qwen3.8-27B GGUFs into ./models (resumable).
#
#   scripts/download-models.sh            # the served config only
#   scripts/download-models.sh --all      # every benchmark candidate (~70 GB)
set -euo pipefail
cd "$(dirname "$0")/.."

UNSLOTH=unsloth/Qwen3.8-27B-GGUF
GGML=ggml-org/Qwen3.8-27B-GGUF

if [[ "${1:-}" == --all ]]; then
    hf download "$UNSLOTH" --local-dir ./models \
        Qwen3.8-27B-UD-IQ4_XS.gguf \
        Qwen3.8-27B-UD-Q4_K_M.gguf \
        Qwen3.8-27B-UD-Q4_K_XL.gguf \
        Qwen3.8-27B-UD-Q5_K_M.gguf \
        MTP/mtp-Qwen3.8-27B-Q4_0.gguf
    hf download "$GGML" --local-dir ./models \
        mtp-Qwen3.8-27B-Q4_0.gguf \
        dflash-Qwen3.8-27B-Q4_0.gguf
else
    [[ -f .env ]] && set -a && . ./.env && set +a
    hf download "$UNSLOTH" --local-dir ./models "${MODEL_FILE:-Qwen3.8-27B-UD-IQ4_XS.gguf}"
fi

ls -lh ./models/*.gguf ./models/MTP/*.gguf 2>/dev/null
