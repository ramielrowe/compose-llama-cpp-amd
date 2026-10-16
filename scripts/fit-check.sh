#!/usr/bin/env bash
# Does a config load at full context, and survive a long prefill?
#
#   scripts/fit-check.sh <model.gguf> <ctk> <ctv> <ubatch> [fill_tokens] [-- extra server args]
#
# fill_tokens=0 (default) only checks that the server loads (KV and compute
# buffers are allocated up front, so this is the main fit signal); a non-zero
# value also prefills that many tokens and records peak VRAM.
# A load that spills more than GTT_LIMIT_MIB (default 256) into GTT counts as
# a failure ("spill"): Vulkan/RADV overflows into system RAM instead of failing.
# Spill = GTT growth minus the pinned host buffers llama.cpp asked for on purpose
# (`ROCm_Host`/`Vulkan_Host` ... buffer size lines).
# Appends one row to results/raw/fit.tsv.
set -euo pipefail
source "$(dirname "$0")/lib.sh"

MODEL="$1" CTK="$2" CTV="$3" UB="$4"
FILL="${5:-0}"
shift $(( $# >= 5 ? 5 : 4 ))
[[ "${1:-}" == -- ]] && shift
EXTRA=("$@")
CTX_SIZE="${CTX_SIZE:-262144}"

OUT=results/raw/fit.tsv
[[ -f $OUT ]] || printf 'time\tbackend\tmodel\tctk\tctv\tub\tctx\textra\tload\tmodel_mib\tkv_mib\tcompute_mib\tvram_idle_mib\tgtt_spill_mib\tfill\tprefill_tps\tvram_peak_mib\tfill_ok\n' > "$OUT"

echo ">> $BACKEND $MODEL K=$CTK V=$CTV ub=$UB ctx=$CTX_SIZE fill=$FILL ${EXTRA[*]}"
stop_server
gtt_base=$(gtt_used_mib)
start_server -m "/models/$MODEL" -c "$CTX_SIZE" -fa on -ctk "$CTK" -ctv "$CTV" -b 2048 -ub "$UB" "${EXTRA[@]}"

load=ok
wait_server 900 || load=FAIL
LOG=results/raw/fit-$BACKEND-${MODEL%.gguf}-$CTK-$CTV-ub$UB${EXTRA:+-spec}.log

# Sum per-device GPU buffer sizes reported at load (ROCm0 or Vulkan0).
sumbuf() { server_logs | grep -E "(ROCm0|Vulkan0) $1 buffer size" | grep -oE '[0-9]+\.[0-9]+ MiB' | awk '{s+=$1} END {printf "%d", s}' || true; }
model_mib=$(sumbuf model) kv_mib=$(sumbuf '(KV|RS)') compute_mib=$(sumbuf compute)
vram_idle=$(vram_used_mib)
host_mib=$(server_logs | grep -E "(ROCm|Vulkan)_Host +[a-z]+ buffer size" | grep -oE '[0-9]+\.[0-9]+ MiB' | awk '{s+=$1} END {printf "%d", s}' || true)
gtt_spill=$(( $(gtt_used_mib) - gtt_base - ${host_mib:-0} ))
[[ $load == ok && $gtt_spill -gt ${GTT_LIMIT_MIB:-256} ]] && load=spill

prefill=- peak=- fill_ok=-
if [[ $load == ok && $FILL -gt 0 ]]; then
    peakfile=$(mktemp)
    echo "$vram_idle" > "$peakfile"
    ( while sleep 1; do v=$(vram_used_mib); (( v > $(cat "$peakfile") )) && echo "$v" > "$peakfile"; done ) &
    poller=$!
    if res=$(BASE_URL=$BASE_URL python3 scripts/llm_client.py fill "$FILL"); then
        prefill=$(jq -r .prefill_tps <<<"$res"); fill_ok=$(jq -r .ok <<<"$res")
    else
        fill_ok=FAIL
    fi
    kill "$poller" 2>/dev/null || true
    peak=$(cat "$peakfile"); rm -f "$peakfile"
    echo "   fill: $res"
fi

server_logs > "$LOG"
stop_server
printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$(date -Is)" "$BACKEND" "$MODEL" "$CTK" "$CTV" "$UB" "$CTX_SIZE" "${EXTRA[*]:-}" "$load" \
    "$model_mib" "$kv_mib" "$compute_mib" "$vram_idle" "$gtt_spill" "$FILL" "$prefill" "$peak" "$fill_ok" | tee -a "$OUT"
[[ $load == ok ]]
