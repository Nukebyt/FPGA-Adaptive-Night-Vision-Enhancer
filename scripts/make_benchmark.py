"""Freeze the LOL image benchmark and the tuning split (roadmap task 1.6).

Benchmark (never tuned on): all 15 eval15 pairs + 35 pairs drawn from our485 with a fixed seed = 50.
Tuning set (free to tune on): 100 pairs drawn from the remaining our485 with a second fixed seed.
Everything else in our485 is unused.

Writes data/benchmark_manifest.json with sha256 of every file. Refuses to overwrite an existing
manifest (it is frozen) unless --force is given.

Usage: python -I scripts/make_benchmark.py [--force]
"""
import hashlib
import json
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
LOL = os.path.join(ROOT, "data", "lol")
OUT = os.path.join(ROOT, "data", "benchmark_manifest.json")
SEED_BENCH = 20261025
SEED_TUNE = 20261026


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for blk in iter(lambda: f.read(1 << 20), b""):
            h.update(blk)
    return h.hexdigest()


def entry(split, name):
    lo = os.path.join("data", "lol", split, "low", name)
    hi = os.path.join("data", "lol", split, "high", name)
    return {"split": split, "name": name, "low": lo.replace("\\", "/"), "high": hi.replace("\\", "/"),
            "sha256_low": sha(os.path.join(ROOT, lo)), "sha256_high": sha(os.path.join(ROOT, hi))}


def main():
    if os.path.exists(OUT) and "--force" not in sys.argv:
        print("manifest already exists and is frozen:", OUT, "(use --force to rebuild)")
        return 1
    ev = sorted(os.listdir(os.path.join(LOL, "eval15", "low")))
    tr = sorted(os.listdir(os.path.join(LOL, "our485", "low")))
    assert len(ev) == 15 and len(tr) == 485
    rng = np.random.default_rng(SEED_BENCH)
    bench_tr = sorted(rng.choice(tr, 35, replace=False).tolist())
    rest = [n for n in tr if n not in set(bench_tr)]
    tune = sorted(np.random.default_rng(SEED_TUNE).choice(rest, 100, replace=False).tolist())
    assert not set(tune) & set(bench_tr)
    man = {
        "description": "LOL benchmark (never tune on 'benchmark') and tuning split",
        "seeds": {"benchmark": SEED_BENCH, "tuning": SEED_TUNE},
        "benchmark": [entry("eval15", n) for n in ev] + [entry("our485", n) for n in bench_tr],
        "tuning": [entry("our485", n) for n in tune],
    }
    with open(OUT, "w") as f:
        json.dump(man, f, indent=1)
    print("benchmark: %d images, tuning: %d images -> %s" % (len(man["benchmark"]), len(man["tuning"]), OUT))
    return 0


if __name__ == "__main__":
    sys.exit(main())
