"""Compare frames recorded from the board (scripts/nv_viewer.py --dump) with each other and with the integer model.

  python -I scripts/run_hw_compare.py --repro run1.npz run2.npz      Gate 0: two runs after FRAME_RESET must be bit-identical
  python -I scripts/run_hw_compare.py --model run1.npz               Gate 1: board output == IntPipeline on the same input frames
  python -I scripts/run_hw_compare.py --selftest                     check the comparison logic itself (no board needed)

Gate 1 sweeps a frame offset of +/- MAXOFF before declaring a value mismatch (checklist 4.2): if the board matches the model only at a
non-zero offset the pipeline is right and a frame was dropped or duplicated, which is a different bug from wrong pixel values.
The verdict is the last line: "RESULT: PASS" or "RESULT: FAIL ..." (no verdict = fail, same convention as run_regression.py).
"""
import argparse
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model.pipeline_int import IntPipeline  # noqa: E402

MAXOFF = 2


def first_diff(a, b):
    d = np.argwhere(a != b)
    return None if len(d) == 0 else tuple(int(v) for v in d[0])


def compare_streams(board, model):
    """board, model: (n,h,w) uint8. Returns (dict offset -> mismatching frame count, frames compared)."""
    res = {}
    for off in range(-MAXOFF, MAXOFF + 1):
        # board frame i is compared with model frame i + off
        lo, hi = max(0, -off), min(len(board), len(model) - off)
        if hi <= lo:
            continue
        bad = sum(int(np.any(board[i] != model[i + off])) for i in range(lo, hi))
        res[off] = (bad, hi - lo)
    return res


def model_run(raw):
    n, h, w = raw.shape
    pipe = IntPipeline(w, h)
    return np.stack([pipe.step(f) for f in raw])


def verdict_model(board, raw):
    model = model_run(raw)
    res = compare_streams(board, model)
    for off, (bad, n) in sorted(res.items()):
        print("  offset %+d: %d of %d frames differ" % (off, bad, n))
    if 0 in res and res[0][0] == 0:
        return "RESULT: PASS (%d frames bit-exact)" % res[0][1]
    exact = [o for o, (bad, n) in res.items() if bad == 0]
    if exact:
        return "RESULT: FAIL frame offset %+d matches exactly: a frame was dropped or duplicated, pixel values are right" % exact[0]
    n0 = min(len(board), len(model))
    for i in range(n0):
        p = first_diff(board[i], model[i])
        if p:
            return "RESULT: FAIL first value mismatch frame %d at (row %d, col %d): board %d, model %d" % (
                i, p[0], p[1], board[i][p[0], p[1]], model[i][p[0], p[1]])
    return "RESULT: FAIL stream lengths differ (board %d, model %d)" % (len(board), len(model))


def verdict_repro(a, b):
    n = min(len(a), len(b))
    if len(a) != len(b):
        print("  note: runs have %d and %d frames, comparing the first %d" % (len(a), len(b), n))
    for i in range(n):
        p = first_diff(a[i], b[i])
        if p:
            return "RESULT: FAIL runs differ at frame %d (row %d, col %d): %d vs %d" % (i, p[0], p[1], a[i][p[0], p[1]], b[i][p[0], p[1]])
    return "RESULT: PASS (%d frames identical)" % n if n else "RESULT: FAIL no frames"


def selftest():
    rng = np.random.default_rng(3)
    base = rng.integers(0, 60, (24, 32), dtype=np.uint8)
    raw = np.stack([np.clip(base.astype(int) + rng.integers(-4, 5, base.shape) + 2 * i, 0, 255).astype(np.uint8) for i in range(8)])
    good = model_run(raw)
    cases = []
    cases.append(("exact match passes", verdict_model(good, raw), True))
    dropped = good[1:]                                                # board stream starts one frame late (constant offset)
    cases.append(("constant offset is reported as an offset", verdict_model(dropped, raw), False))
    bad = good.copy()
    bad[5, 10, 7] ^= 1
    cases.append(("single flipped pixel is caught", verdict_model(bad, raw), False))
    cases.append(("identical runs pass", verdict_repro(good, good.copy()), True))
    cases.append(("different runs fail", verdict_repro(good, bad), False))
    ok = True
    for name, v, want in cases:
        got = v.startswith("RESULT: PASS")
        print("  %-42s -> %s %s" % (name, v, "" if got == want else "  <-- WRONG"))
        ok &= got == want
    assert "offset" in cases[1][1] and "frame 5" in cases[2][1]
    return ok


def main():
    ap = argparse.ArgumentParser()
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--repro", nargs=2, metavar=("RUN1", "RUN2"))
    g.add_argument("--model", metavar="RUN")
    g.add_argument("--selftest", action="store_true")
    a = ap.parse_args()
    if a.selftest:
        ok = selftest()
        print("RESULT: PASS" if ok else "RESULT: FAIL selftest")
        return 0 if ok else 1
    if a.repro:
        r1, r2 = (np.load(p)["enh"] for p in a.repro)
        v = verdict_repro(r1, r2)
    else:
        d = np.load(a.model)
        v = verdict_model(d["enh"], d["raw"])
    print(v)
    return 0 if v.startswith("RESULT: PASS") else 1


if __name__ == "__main__":
    sys.exit(main())
