#!/usr/bin/env python3
"""llama-bench jsonl (stdin or files) -> markdown table."""

import fileinput
import json

print("| backend | model | K | V | ub | depth | test | t/s |")
print("|---|---|---|---|---|---|---|---|")
for line in fileinput.input():
    if not line.startswith("{"):
        continue
    r = json.loads(line)
    test = f"pp{r['n_prompt']}" if r["n_prompt"] else f"tg{r['n_gen']}"
    model = r["model_filename"].split("/")[-1].removeprefix("Qwen3.8-27B-").removesuffix(".gguf")
    print(f"| {r['backends']} | {model} | {r['type_k']} | {r['type_v']} | {r['n_ubatch']} "
          f"| {r['n_depth']} | {test} | {r['avg_ts']:.1f} ± {r['stddev_ts']:.1f} |")
