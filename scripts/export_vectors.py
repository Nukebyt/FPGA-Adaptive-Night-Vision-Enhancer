"""Export golden test vectors for the RTL testbenches from the bit-accurate integer model (roadmap 4.7 / 5.10).

Usage: python -I scripts/export_vectors.py [name ...]      (default: all sets)
Writes tb/vec/<name>/ with  meta.json and one value per line, $readmemh format:
  in.hex        T*W*H   raw input pixels (2 hex digits)
  exp_tp.hex    T*W*H   temporal stage output, Q8.2 (3 digits)
  exp_sp.hex    T*W*H   spatial stage output, Q8.2 (3 digits)
  exp_v.hex     T*W*H   tone-mapped values before sharpening (2 digits)
  exp_out.hex   T*W*H   final output (2 digits)
  exp_state.hex (T+1)*NS 32-bit words; entry k = controller result after k frames (k = 0: initial). Fields, NS = 15:
                lg, sigma_q8, b, a_q8, lam_q4, sharp_q4, core_q4 (saturated 16 bit), k_mot, thr, p1, p50, p99,
                mean_q4, out_sum, noise_sum
  exp_lut.hex   (T+1)*1024  tone LUT generated after k frames (k = 0: initial), 2 digits
Vector sets are derived artefacts (gitignored): regenerate with this script; run_regression.py does it automatically.
"""
import json
import math
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model import lowlight_sim as sim, pipeline_int  # noqa: E402

NS = 15
SETS = {
    # name: (W, H, T, kind)
    "small_nat":  (32, 24, 8, "natural"),
    "small_step": (40, 30, 10, "step"),
    "small_rand": (24, 16, 5, "random"),
    "small_ext":  (16, 12, 5, "extreme"),
    "full":       (640, 480, 3, "natural"),
}


def c_sig(w, h):
    return int(round((1 << 24) * 256 * math.sqrt(math.pi / 2.0) / (6.0 * (w - 2) * (h - 2))))


def make_frames(w, h, t, kind):
    rng = np.random.default_rng(1000 + w + t)
    if kind == "random":
        return rng.integers(0, 256, (t, h, w), dtype=np.uint8)
    if kind == "extreme":
        f = np.zeros((t, h, w), np.uint8)
        f[1::2] = 255
        f[2, h // 3: 2 * h // 3] = 128
        f[3] = rng.integers(0, 2, (h, w)) * 255
        return f
    still = cv2.GaussianBlur(rng.integers(0, 256, (max(h, 60) // 2 + 20, max(w, 80) // 2 + 20), dtype=np.uint8), (0, 0), 2.5)
    gt, _ = sim.clip_from_still(still, t, seed=int(rng.integers(1 << 30)), size=(w, h), obj=max(8, min(24, h // 2)))
    if kind == "step":
        exp = np.array([0.006] * (t // 3) + [0.05] * (t // 3) + [0.006] * (t - 2 * (t // 3)))
        return sim.simulate_clip(gt, exp, seed=5, full_well=1500.0, read_sigma=2.0)
    return sim.simulate_clip_preset(gt, "moderate", exposure=0.01, seed=7)


def state_words(pipe, p, mean_q4, out_sum, noise_sum):
    sig_eff = max(pipe.sigma_q8, 128)
    kmot = pipeline_int.rdiv(1 << 26, 9 * sig_eff)
    thr = min(4095, ((sig_eff * 20) + 256) >> 9)
    return [pipe.lg, min(pipe.sigma_q8, 65535), pipe.b, pipe.a_q8, pipe.lam_q4, pipe.sharp_q4, min(pipe.core_q4, 65535),
            kmot, thr, p[0], p[1], p[2], mean_q4, out_sum, noise_sum]


def write_hex(path, values, digits):
    with open(path, "w", newline="\n") as f:
        for v in values:
            f.write(("%0" + str(digits) + "x\n") % int(v))


def export(name):
    w, h, t, kind = SETS[name]
    frames = make_frames(w, h, t, kind)
    pipe = pipeline_int.IntPipeline(w, h)
    states = [state_words(pipe, (0, 0, 0), 0, 0, 0)]
    luts = [pipe.lut.copy()]
    tp, sp, v, out = [], [], [], []
    for f in frames:
        o = pipe.step(f)
        d = pipe.dbg
        tp.append(d["p_new"].ravel()); sp.append(d["sp"].ravel()); v.append(d["v"].ravel()); out.append(o.ravel())
        lg = pipe.log[-1]
        states.append(state_words(pipe, (lg["p1"], lg["p50"], lg["p99"]), lg["mean_q4"], d["out_sum"], d["noise_sum"]))
        luts.append(pipe.lut.copy())
    d = os.path.join(ROOT, "tb", "vec", name)
    os.makedirs(d, exist_ok=True)
    write_hex(os.path.join(d, "in.hex"), frames.ravel(), 2)
    write_hex(os.path.join(d, "exp_tp.hex"), np.concatenate(tp), 3)
    write_hex(os.path.join(d, "exp_sp.hex"), np.concatenate(sp), 3)
    write_hex(os.path.join(d, "exp_v.hex"), np.concatenate(v), 2)
    write_hex(os.path.join(d, "exp_out.hex"), np.concatenate(out), 2)
    write_hex(os.path.join(d, "exp_state.hex"), np.concatenate([np.array(s, dtype=np.int64) for s in states]), 8)
    write_hex(os.path.join(d, "exp_lut.hex"), np.concatenate(luts), 2)
    json.dump(dict(name=name, W=w, H=h, T=t, kind=kind, C_SIG=c_sig(w, h), NS=NS), open(os.path.join(d, "meta.json"), "w"), indent=1)
    print("%-11s %3dx%-3d T=%d  p-stats: out mean %.1f, final gain 2^(%d/4096)" % (name, w, h, t, np.mean(out[-1]), pipe.lg))


if __name__ == "__main__":
    for n in (sys.argv[1:] or list(SETS)):
        export(n)
