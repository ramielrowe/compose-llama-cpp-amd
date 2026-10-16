#!/usr/bin/env bash
# KL divergence of quantized KV caches vs an f16 KV cache, same weights.
#
#   scripts/kv-kld.sh <model.gguf> <ctk:ctv>[,<ctk:ctv>...]
#
# One 32768-token chunk of wikitext-2: llama-perplexity scores the second half,
# so every scored token attends over 16K-32K of (quantized) context. The f16
# reference logits (~8 GB) are cached in data/ per model. llama-perplexity keeps
# a whole chunk's logits in host RAM (ctx x 248K vocab x 4 B = 32 GB at 32K),
# so 64K would not fit in this box's 60 GB.
# Appends rows to results/raw/kv-kld.tsv.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_wikitext

MODEL="$1"
PAIRS="$2"
CTX_KLD="${CTX_KLD:-32768}"
BASE="/data/kld-base-${MODEL%.gguf}-c$CTX_KLD.bin"
OUT=results/raw/kv-kld.tsv
[[ -f $OUT ]] || printf 'time\tmodel\tctk\tctv\tctx\tppl\tmean_kld\tp99_kld\tsame_top\n' > "$OUT"

ppl() {
    docker compose --profile bench run --rm -T bench \
        llama-perplexity -m "/models/$MODEL" -f /data/wiki.test.raw -c "$CTX_KLD" --chunks 1 \
        -ngl 999 -fa on -b 2048 -ub 1024 "$@" 2>&1
}

if [[ ! -f "data/${BASE#/data/}" ]]; then
    echo ">> f16 reference logits for $MODEL" >&2
    ppl -ctk f16 -ctv f16 --kl-divergence-base "$BASE" | grep -E "Final estimate|error|failed" || true
    [[ -s "data/${BASE#/data/}" ]] || { echo "reference run failed" >&2; exit 1; }
fi

IFS=, read -ra pairs <<<"$PAIRS"
for pair in "${pairs[@]}"; do
    ctk="${pair%%:*}" ctv="${pair##*:}"
    echo ">> $MODEL K=$ctk V=$ctv" >&2
    log=$(ppl -ctk "$ctk" -ctv "$ctv" --kl-divergence-base "$BASE" --kl-divergence)
    echo "$log" > "results/raw/kld-$BACKEND-${MODEL%.gguf}-$ctk-$ctv.log"
    row=$(printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' "$(date -Is)" "$MODEL" "$ctk" "$ctv" "$CTX_KLD" \
        "$(grep -E '^Mean PPL\(Q\) +:' <<<"$log" | awk '{print $4}')" \
        "$(grep -E '^Mean +KLD:' <<<"$log" | awk '{print $3}')" \
        "$(grep -E '^99\.0% +KLD:' <<<"$log" | awk '{print $3}')" \
        "$(grep -E '^Same top p:' <<<"$log" | awk '{print $4}')")
    echo "$row" | tee -a "$OUT"
done
