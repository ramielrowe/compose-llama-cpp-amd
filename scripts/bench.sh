#!/usr/bin/env bash
# llama-bench sweep: one model, several K:V pairs, ubatch sizes and depths.
#
#   scripts/bench.sh <model.gguf> <ctk:ctv>[,<ctk:ctv>...] [ubatches] [depths] [reps]
#   BACKEND=hip scripts/bench.sh ...         # override the backend from .env
#
# Defaults: ubatches 512,1024,2048; depths 0,32768,131072; reps 2.
# pp2048 / tg128 are measured *at* each depth (the depth is prefilled first,
# untimed). Raw jsonl goes to results/raw/, a markdown table to stdout.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

MODEL="$1"
PAIRS="$2"
UBS="${3:-512,1024,2048}"
DEPTHS="${4:-0,32768,131072}"
REPS="${5:-2}"

OUT="results/raw/bench-$BACKEND-${MODEL%.gguf}.jsonl"
IFS=, read -ra pairs <<<"$PAIRS"
for pair in "${pairs[@]}"; do
    ctk="${pair%%:*}" ctv="${pair##*:}"
    echo ">> $BACKEND $MODEL K=$ctk V=$ctv ub=$UBS d=$DEPTHS" >&2
    docker compose --profile bench run --rm -T bench \
        llama-bench -m "/models/$MODEL" -ngl 999 -fa 1 -ctk "$ctk" -ctv "$ctv" \
        -b 2048 -ub "$UBS" -p 2048 -n 128 -d "$DEPTHS" -r "$REPS" -o jsonl \
        | grep '^{' | tee -a "$OUT"
done | python3 scripts/bench_table.py
