#!/usr/bin/env bash
# llama-bench sweep: one model, several K:V pairs, ubatch sizes and depths.
#
#   scripts/bench.sh <model.gguf> <ctk:ctv>[,<ctk:ctv>...] [ubatches] [depths] [reps]
#   BACKEND=vulkan scripts/bench.sh ...      # same sweep on the Vulkan image
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
BACKEND="${BACKEND:-hip}"
SERVICE=bench; [[ $BACKEND == vulkan ]] && SERVICE=vulkan-bench

OUT="results/raw/bench-$BACKEND-${MODEL%.gguf}.jsonl"
IFS=, read -ra pairs <<<"$PAIRS"
for pair in "${pairs[@]}"; do
    ctk="${pair%%:*}" ctv="${pair##*:}"
    echo ">> $BACKEND $MODEL K=$ctk V=$ctv ub=$UBS d=$DEPTHS" >&2
    docker compose --profile bench --profile vulkan run --rm -T "$SERVICE" \
        llama-bench -m "/models/$MODEL" -ngl 999 -fa 1 -ctk "$ctk" -ctv "$ctv" \
        -b 2048 -ub "$UBS" -p 2048 -n 128 -d "$DEPTHS" -r "$REPS" -o jsonl \
        | grep '^{' | tee -a "$OUT"
done | python3 -c '
import json, sys
rows = [json.loads(l) for l in sys.stdin]
print("| backend | model | K | V | ub | depth | test | t/s |")
print("|---|---|---|---|---|---|---|---|")
for r in rows:
    test = f"pp{r[\"n_prompt\"]}" if r["n_prompt"] else f"tg{r[\"n_gen\"]}"
    print(f"| {r[\"backends\"]} | {r[\"model_filename\"].split(\"/\")[-1]} | {r[\"type_k\"]} | {r[\"type_v\"]} "
          f"| {r[\"n_ubatch\"]} | {r[\"n_depth\"]} | {test} | {r[\"avg_ts\"]:.1f} ± {r[\"stddev_ts\"]:.1f} |")
'
