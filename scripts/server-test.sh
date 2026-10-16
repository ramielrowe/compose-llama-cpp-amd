#!/usr/bin/env bash
# Run an llm_client.py check against a throwaway server.
#
#   scripts/server-test.sh <check> [check args] -- <llama-server args>
#   scripts/server-test.sh <check> [check args]            # use the .env config
#
# Checks (see scripts/llm_client.py):
#   niah <n_tokens> [needles]   needle retrieval in an n-token haystack
#   leak                        recurrent-state leak across a reused slot (#29092)
#   spec [n_predict] [depths]   decode t/s + draft acceptance (+ summaries at depths)
#   fill <n_tokens>             long prefill
#
# Appends {"check", "args", "server", "result"} to results/raw/server-test.jsonl.
set -euo pipefail
source "$(dirname "$0")/lib.sh"
ensure_wikitext

CHECK=()
while [[ $# -gt 0 && "$1" != -- ]]; do CHECK+=("$1"); shift; done
[[ "${1:-}" == -- ]] && shift
if [[ $# -gt 0 ]]; then
    SERVER=("$@")
else
    # shellcheck disable=SC2206  # SPEC_ARGS is intentionally word-split
    SERVER=(-m "/models/$MODEL_FILE" -c "$CTX" -fa on -ctk "$CTK" -ctv "$CTV"
            -b "$BATCH" -ub "$UBATCH" $SPEC_ARGS)
fi

echo ">> ${CHECK[*]} :: ${SERVER[*]}" >&2
start_server "${SERVER[@]}"
trap stop_server EXIT
wait_server 900 || { server_logs | tail -30 >&2; echo "server failed to start" >&2; exit 1; }

res=$(BASE_URL=$BASE_URL python3 scripts/llm_client.py "${CHECK[@]}")
jq -cn --arg check "${CHECK[*]}" --arg server "${SERVER[*]}" --argjson result "$res" \
    '{time: (now | todate), check: $check, server: $server, result: $result}' |
    tee -a results/raw/server-test.jsonl
