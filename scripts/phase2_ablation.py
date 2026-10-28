"""Phase 2 ablation on synthetic video (roadmap task 2.9) using the float design model.

Clips: LOL well-lit stills -> clip_from_still (static background + one moving object, exact motion mask)
-> low-light simulator at 3 noise presets. Design images come from the LOL *tuning* split only.
Fixed-strength baseline ('uncoupled') is the best of a small grid, chosen on DIFFERENT tuning images.

Usage: python -I scripts/phase2_ablation.py [--frames 30] [--images 3]
Writes docs/results/ablation_<preset>.md and prints the tables.
"""
import argparse
import itertools
import json
import os
import sys
from dataclasses import replace

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model import enh, lowlight_sim as sim, metrics  # noqa: E402

SETTLE = 8   # frames ignored for metrics while the controller settles


def make_clips(names, preset, t, seed0):
    clips = []
    for i, rel in enumerate(names):
        hi = cv2.imread(os.path.join(ROOT, rel), cv2.IMREAD_GRAYSCALE)
        gt, mask = sim.clip_from_still(hi, t, seed=seed0 + i, size=(640, 480), pan=(0, 0))
        noisy = sim.simulate_clip_preset(gt, preset, seed=seed0 + 100 + i)
        clips.append((gt, mask, noisy))
    return clips


def evaluate(cfg, clips):
    ps, ss, nz = [], [], []
    for gt, mask, noisy in clips:
        out = enh.run_clip(noisy, cfg)
        o, g = out[SETTLE:], gt[SETTLE:]
        ps.append(np.mean([metrics.psnr(a, b) for a, b in zip(o, g)]))
        ss.append(np.mean([metrics.ssim(a, b) for a, b in zip(o[::4], g[::4])]))
        k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (21, 21))
        ever = np.zeros(mask.shape[1:], np.uint8)
        for m in mask:
            ever |= m.astype(np.uint8)
        static = ~cv2.dilate(ever, k).astype(bool)
        nz.append(float(np.std(o.astype(np.float64), axis=0, ddof=1)[static].mean()))
    return float(np.mean(ps)), float(np.mean(ss)), float(np.mean(nz))


def ghost(cfg, clips):
    vals = []
    for gt, mask, noisy in clips:
        out = enh.run_clip(noisy, cfg)
        base = enh.run_clip(noisy, replace(cfg, temporal=False))
        vals.append(metrics.ghost_error(out[SETTLE:], gt[SETTLE:], mask[SETTLE:], base[SETTLE:])[2])
    return float(np.mean(vals))


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--frames", type=int, default=30)
    ap.add_argument("--images", type=int, default=3)
    a = ap.parse_args()
    man = json.load(open(os.path.join(ROOT, "data", "benchmark_manifest.json")))
    tune = [e["high"] for e in man["tuning"]]
    design, search = tune[30:30 + a.images], tune[60:60 + a.images]
    os.makedirs(os.path.join(ROOT, "docs", "results"), exist_ok=True)

    full = enh.Cfg()
    # --- best fixed (uncoupled) strengths: grid over all three presets on the *search* images ---
    search_clips = {p: make_clips(search[:1], p, 16, 500) for p in sim.NOISE_PRESETS}   # 1 image x 16 frames keeps the grid affordable
    best = None
    for am, lam, sh in itertools.product((1 / 8, 1 / 4, 1 / 2), (0.0, 0.5, 1.0), (0.0, 0.5, 1.0)):
        c = replace(full, coupled=False, fixed_a_min=am, fixed_lam=lam, fixed_sharp=sh)
        score = np.mean([evaluate(c, search_clips[p])[0] for p in sim.NOISE_PRESETS])
        if best is None or score > best[0]:
            best = (score, am, lam, sh)
    print("best fixed strengths (a_min, lam, sharp) = (%.4f, %.1f, %.1f), mean PSNR %.2f" % (best[1], best[2], best[3], best[0]))
    uncoupled = replace(full, coupled=False, fixed_a_min=best[1], fixed_lam=best[2], fixed_sharp=best[3])

    variants = [
        ("tone map only", replace(full, temporal=False, spatial=False, sharpen=False)),
        ("+ temporal", replace(full, spatial=False, sharpen=False)),
        ("+ temporal + spatial", replace(full, sharpen=False)),
        ("+ temporal + spatial + sharpen (coupled = full)", full),
        ("same, strengths fixed (uncoupled)", uncoupled),
    ]
    for p in sim.NOISE_PRESETS:
        clips = make_clips(design, p, a.frames, 100)
        lines = ["| variant | PSNR (dB) | SSIM | static noise std | ghost ratio |", "|---|---|---|---|---|"]
        for name, c in variants:
            ps, ss, nz = evaluate(c, clips)
            gr = ghost(c, clips) if c.temporal else float("nan")
            lines.append("| %s | %.2f | %.3f | %.2f | %s |" % (name, ps, ss, nz, "-" if gr != gr else "%.2f" % gr))
        txt = "preset **%s**, %d design images x %d frames (first %d ignored), design images from the LOL tuning split\n\n%s\n" % (
            p, len(design), a.frames, SETTLE, "\n".join(lines))
        open(os.path.join(ROOT, "docs", "results", "ablation_%s.md" % p), "w").write(txt)
        print("\n" + txt, flush=True)


if __name__ == "__main__":
    main()
