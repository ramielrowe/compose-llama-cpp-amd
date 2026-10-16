#!/usr/bin/env python3
"""Small stdlib-only client for the llama-server checks.

  fill   <n_tokens>          prefill n tokens of corpus text, report timings
  niah   <n_tokens> [k]      k-needle retrieval in an n-token haystack
  leak                       temp-0 determinism across a reused slot (#29092)
  spec   [n_predict] [depths]  decode t/s + draft acceptance, short prompts + summaries at depths

Env: BASE_URL (default http://127.0.0.1:18080), API_KEY, CORPUS (default data/wiki.test.raw).
Every subcommand prints one JSON line on stdout.
"""

import hashlib
import json
import os
import random
import sys
import time
import urllib.request

BASE_URL = os.environ.get("BASE_URL", "http://127.0.0.1:18080")
API_KEY = os.environ.get("API_KEY", "")
CORPUS = os.environ.get("CORPUS", "data/wiki.test.raw")


def post(path, body, timeout=7200):
    req = urllib.request.Request(
        BASE_URL + path,
        data=json.dumps(body).encode(),
        headers={"Content-Type": "application/json", "Authorization": f"Bearer {API_KEY}"},
    )
    with urllib.request.urlopen(req, timeout=timeout) as r:
        return json.load(r)


def tokenize(text):
    return post("/tokenize", {"content": text, "add_special": False})["tokens"]


def detokenize(tokens):
    return post("/detokenize", {"tokens": tokens})["content"]


_corpus_tokens = None


def corpus_tokens(n):
    """First n tokens of the corpus (repeated if it is shorter than n)."""
    global _corpus_tokens
    if _corpus_tokens is None:
        with open(CORPUS, encoding="utf-8") as f:
            _corpus_tokens = tokenize(f.read())
    toks = _corpus_tokens
    while len(toks) < n:
        toks = toks + _corpus_tokens
    return toks[:n]


def completion(prompt, **kw):
    body = {"prompt": prompt, "n_predict": 16, "temperature": 0, "cache_prompt": False}
    body.update(kw)
    t0 = time.time()
    r = post("/completion", body)
    r["_wall_s"] = round(time.time() - t0, 2)
    return r


def cmd_fill(n):
    n = int(n)
    r = completion(corpus_tokens(n), n_predict=32)
    t = r["timings"]
    print(json.dumps({
        "fill_tokens": t["prompt_n"],
        "prefill_tps": round(t["prompt_per_second"], 1),
        "decode_tps": round(t["predicted_per_second"], 2),
        "wall_s": r["_wall_s"],
        "ok": t["prompt_n"] >= n * 0.99,
    }))


WORDS = ["amber", "basalt", "cobalt", "delta", "ember", "fjord", "garnet", "harbor",
         "indigo", "juniper", "kelp", "lumen", "marble", "nimbus", "onyx", "prism"]


def cmd_niah(n, k=10):
    """Insert k 'The secret code for <name> is <number>.' needles at evenly spaced
    depths, then ask for all of them at once (thinking off, temp 0)."""
    n, k = int(n), int(k)
    rng = random.Random(n * 1000 + k)
    needles = []
    for i in range(k):
        name = f"{rng.choice(WORDS)}-{rng.choice(WORDS)}-{i}"
        needles.append((name, str(rng.randint(100000, 999999))))

    question = ("\n\nList the secret code for each of these names, one per line, formatted "
                "exactly as `name: code`. Names: " + ", ".join(nm for nm, _ in needles))
    needle_toks = [tokenize(f" The secret code for {nm} is {code}. ") for nm, code in needles]
    budget = n - sum(map(len, needle_toks)) - len(tokenize(question)) - 64
    hay = corpus_tokens(budget)

    # needle i at depth (i + 0.5) / k of the haystack
    parts, prev = [], 0
    for i, nt in enumerate(needle_toks):
        pos = int(budget * (i + 0.5) / k)
        parts.append(hay[prev:pos])
        parts.append(nt)
        prev = pos
    parts.append(hay[prev:])
    haystack = detokenize([t for p in parts for t in p])

    t0 = time.time()
    r = post("/v1/chat/completions", {
        "messages": [{"role": "user", "content": haystack + question}],
        "temperature": 0, "max_tokens": 32 * k + 64, "cache_prompt": False,
        "chat_template_kwargs": {"enable_thinking": False},
    })
    out = r["choices"][0]["message"]["content"] or ""
    found = [code in out for _, code in needles]
    print(json.dumps({
        "ctx_tokens": r["usage"]["prompt_tokens"],
        "needles": k,
        "found": sum(found),
        "missed_depths": [round((i + 0.5) / k, 2) for i, f in enumerate(found) if not f],
        "wall_s": round(time.time() - t0, 1),
    }))


def cmd_leak():
    """Generate A, then unrelated B, then A again on the same (only) slot with
    temp 0 and no prompt cache. A recurrent-state leak (#29092) shows up as A != A'."""
    a = "Write a short Python function that checks whether a string is a palindrome."
    b = "Summarise the causes of the French Revolution in three sentences. " + detokenize(corpus_tokens(4000))

    def gen(p):
        return post("/v1/chat/completions", {
            "messages": [{"role": "user", "content": p}], "temperature": 0, "max_tokens": 200,
            "cache_prompt": False, "chat_template_kwargs": {"enable_thinking": False},
        })["choices"][0]["message"]["content"]

    a1 = gen(a)
    gen(b)
    a2 = gen(a)
    a3 = gen(a)
    print(json.dumps({"a1_eq_a2": a1 == a2, "a2_eq_a3": a2 == a3, "len": len(a1),
                      "diverge_at": next((i for i, (x, y) in enumerate(zip(a1, a2)) if x != y), None)}))


SPEC_PROMPTS = {
    "code": "Write a complete Python implementation of a thread-safe LRU cache class with get, put, "
            "and delete methods, type hints, docstrings and a few unit tests.",
    "prose": "Write a 600-word short story about a lighthouse keeper who finds a message in a bottle.",
    "summary": "Summarise the following text in about 300 words.\n\n",  # + corpus excerpt
}


def cmd_spec(n_predict=512, depths="16000"):
    """Decode speed, draft acceptance and a greedy-output fingerprint (thinking off,
    temp 0): two short prompts (code, prose), plus a summary of a corpus excerpt
    at each comma-separated depth in `depths` (tokens)."""
    n_predict = int(n_predict)
    jobs = [("code", SPEC_PROMPTS["code"]), ("prose", SPEC_PROMPTS["prose"])]
    for d in (int(x) for x in str(depths).split(",") if x):
        jobs.append((f"summary_{d}", SPEC_PROMPTS["summary"] + detokenize(corpus_tokens(d))))
    res = {}
    for name, p in jobs:
        r = post("/v1/chat/completions", {
            "messages": [{"role": "user", "content": p}], "temperature": 0, "max_tokens": n_predict,
            "cache_prompt": False, "chat_template_kwargs": {"enable_thinking": False},
        })
        t = r.get("timings", {})
        res[name] = {
            "decode_tps": round(t.get("predicted_per_second", 0), 2),
            "prefill_tps": round(t.get("prompt_per_second", 0), 1),
            "prompt_n": t.get("prompt_n"),
            "n": t.get("predicted_n"),
            "draft_n": t.get("draft_n"),
            "draft_accepted": t.get("draft_n_accepted"),
            # greedy output fingerprint: speculative decoding must not change it
            "sha": hashlib.sha256((r["choices"][0]["message"]["content"] or "").encode()).hexdigest()[:12],
        }
    res["short_mean_decode_tps"] = round((res["code"]["decode_tps"] + res["prose"]["decode_tps"]) / 2, 2)
    print(json.dumps(res))


if __name__ == "__main__":
    cmds = {"fill": cmd_fill, "niah": cmd_niah, "leak": cmd_leak, "spec": cmd_spec}
    if len(sys.argv) < 2 or sys.argv[1] not in cmds:
        sys.exit(__doc__)
    cmds[sys.argv[1]](*sys.argv[2:])
