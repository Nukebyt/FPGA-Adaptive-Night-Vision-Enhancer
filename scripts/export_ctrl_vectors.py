"""Controller-only golden vectors: random and DIRECTED frame statistics fed straight to nv_ctrl (roadmap 4.7, 4.8).

Why a separate set: image-derived vectors never hit the corner cases (exact deadband edges, black-level clamp at 16, very high
noise, rounding ties in the LUT index, saturated strengths). Fault injection found exactly those blind spots, so this set
generates statistics directly:
  * histograms: dark / bright / bimodal / constant / uniform / very dark shapes, always summing to W*H pixels
  * output sums: random around the target plus DIRECTED cases whose mean_q4 lands exactly on the deadband edges (+-294/+-295)
  * noise sums: sigma from 0.05 to 80 grey levels (log-uniform), reaching every coupling clamp
  * passthru toggled on some cases (identity LUT)
The state evolves case after case (the controller is stateful), driven in the model by IntPipeline.update_stats().

Usage: python -I scripts/export_ctrl_vectors.py [ctrl_small ctrl_full]
Writes tb/vec/<name>/: meta.json, hist.hex (N*256, 5 digits), in.hex (N*3: out_sum, noise_sum, passthru; 8 digits),
exp_state.hex ((N+1)*15, 8 digits, same fields as scripts/export_vectors.py), exp_lut.hex ((N+1)*1024), exp_th.hex (N*64, 4 digits)
"""
import json
import math
import os
import sys

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from export_vectors import NS, c_sig, state_words, write_hex  # noqa: E402
from model import pipeline_int, roms, stats  # noqa: E402

# sizes chosen so that N*95 mod 100 is in 5..45 (T95 rounding differs from a plain round) and N is not a multiple of 8
SETS = {"ctrl_small": (26, 19, 600), "ctrl_full": (640, 480, 240), "ctrl_soak": (24, 18, 8000)}


def make_hist(rng, npix):
    kind = int(rng.integers(0, 7))
    v = np.arange(256, dtype=np.float64)
    if kind == 0:      # dark natural
        m = rng.uniform(2, 40); p = np.exp(-v / m)
    elif kind == 1:    # bright
        m = rng.uniform(150, 250); p = np.exp(-(255 - v) / max(255 - m, 3))
    elif kind == 2:    # bimodal
        a, b = rng.uniform(5, 60), rng.uniform(150, 250); p = np.exp(-0.5 * ((v - a) / 6) ** 2) + np.exp(-0.5 * ((v - b) / 10) ** 2)
    elif kind == 3:    # constant
        p = np.zeros(256); p[int(rng.integers(0, 256))] = 1.0
    elif kind == 4:    # uniform
        p = np.ones(256)
    elif kind == 5:    # very dark with a few bright pixels
        p = np.exp(-v / 1.5); p[255] += 0.03 * p.sum()
    else:              # gaussian around a random level
        c, s = rng.uniform(0, 255), rng.uniform(2, 50); p = np.exp(-0.5 * ((v - c) / s) ** 2) + 1e-12
    return rng.multinomial(npix, p / p.sum()).astype(np.int64)


def deadband_edge_means():
    """mean_q4 values whose e = log2(2048) - log2(mean_q4) is exactly +-294 or +-295 (the deadband edge is 295)."""
    out = []
    for m4 in range(1200, 3600):
        e = roms.log2_q12(2048) - roms.log2_q12(m4)
        if abs(e) in (293, 294, 295, 296):
            out.append(m4)
    return out


def export(name):
    w, h, n = SETS[name]
    npix = w * h
    rng = np.random.default_rng(777 + w)
    cs = c_sig(w, h)
    pipe = pipeline_int.IntPipeline(w, h)
    edges = deadband_edge_means()
    states = [state_words(pipe, (0, 0, 0), 0, 0, 0)]
    luts = [pipe.lut.copy()]
    hists, ins, ths = [], [], []
    for i in range(n):
        regime = (i // 40) % 4                     # 0: dark scene (gain climbs), 1: bright, 2: random, 3: ultra dark (hits the p95 headroom floor)
        hist = make_hist(rng, npix)
        if regime == 0:
            v = np.arange(256); p = np.exp(-v / rng.uniform(2, 25)); hist = rng.multinomial(npix, p / p.sum()).astype(np.int64)
        elif regime == 3:
            v = np.arange(256); p = np.exp(-v / rng.uniform(0.6, 1.4)); hist = rng.multinomial(npix, p / p.sum()).astype(np.int64)
        elif regime == 1:
            v = np.arange(256); p = np.exp(-(255 - v) / rng.uniform(5, 40)); hist = rng.multinomial(npix, p / p.sum()).astype(np.int64)
        r = rng.random()
        if regime == 3:
            out_sum = int(npix * rng.uniform(1, 12))
        elif regime == 0 and i % 2 == 0:
            out_sum = int(npix * rng.uniform(5, 70))
        elif regime == 1 and i % 2 == 0:
            out_sum = int(npix * rng.uniform(150, 250))
        elif i < len(edges) * 2 and i % 2 == 1:          # directed deadband edge
            m4 = edges[i // 2 % len(edges)]
            out_sum = int(round(m4 * npix / 16.0))
        elif r < 0.25:
            out_sum = int(npix * rng.uniform(120, 136))          # near the target: deadband / small steps
        elif r < 0.5:
            out_sum = int(npix * rng.uniform(1, 255))
        elif r < 0.6:
            out_sum = int(npix * rng.choice([0, 1, 255]))        # extremes (mean_q4 = 0 handled as 1)
        else:
            out_sum = int(npix * 128 * rng.uniform(0.8, 1.25))
        sigma = float(np.exp(rng.uniform(np.log(0.05), np.log(80.0) if regime == 2 else np.log(4.0))))
        # (regime 3 keeps sigma small too so the gain can climb to the headroom limit)
        noise_sum = int(sigma * 256 * (1 << 24) / cs)
        if i % 120 >= 95:
            noise_sum = 0                          # perfectly clean stretch: sigma decays towards 0 (reaches nq_raw == 0)
        passthru = 1 if rng.random() < 0.1 else 0
        pipe.passthru = bool(passthru)
        pipe.update_stats(hist, noise_sum, out_sum)
        lg = pipe.log[-1]
        states.append(state_words(pipe, (lg["p1"], lg["p50"], lg["p99"]), lg["mean_q4"], out_sum, noise_sum))
        luts.append(pipe.lut.copy())
        hists.append(hist); ins += [out_sum, noise_sum, passthru]
        ths.append([min(65535, int(hist[4 * k:4 * k + 4].sum()) >> 4) for k in range(64)])
    d = os.path.join(ROOT, "tb", "vec", name)
    os.makedirs(d, exist_ok=True)
    write_hex(os.path.join(d, "hist.hex"), np.concatenate(hists), 5)
    write_hex(os.path.join(d, "in.hex"), ins, 8)
    write_hex(os.path.join(d, "exp_state.hex"), np.concatenate([np.array(s, dtype=np.int64) for s in states]), 8)
    write_hex(os.path.join(d, "exp_lut.hex"), np.concatenate(luts), 2)
    write_hex(os.path.join(d, "exp_th.hex"), np.concatenate([np.array(t) for t in ths]), 4)
    json.dump(dict(name=name, W=w, H=h, N=n, C_SIG=cs, NS=NS), open(os.path.join(d, "meta.json"), "w"), indent=1)
    lgs = [s[0] for s in states]
    print("%-10s %dx%d N=%d  lg range %d..%d, %d deadband-edge means available" % (name, w, h, n, min(lgs), max(lgs), len(edges)))


if __name__ == "__main__":
    for nm in (sys.argv[1:] or list(SETS)):
        export(nm)
