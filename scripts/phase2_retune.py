"""Retune the coupling constants (sigma_t, motion threshold r0, blend floor a_floor) on the LOL tuning split.

Images tuning[70:72] (disjoint from the images used for the first fixed-strength search [60:] and for the
ablation [30:]); all three noise presets; score = mean over presets of PSNR + 5*SSIM on frames >= 8, plus the
ghost ratio is reported. Prints the table sorted by score and writes docs/results/retune.md.
Usage: python -I scripts/phase2_retune.py
"""
import itertools
import json
import os
import sys
from dataclasses import replace

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from phase2_ablation import evaluate, ghost, make_clips  # noqa: E402
from model import enh, lowlight_sim as sim  # noqa: E402


def main():
    man = json.load(open(os.path.join(ROOT, "data", "benchmark_manifest.json")))
    imgs = [e["high"] for e in man["tuning"]][70:71]
    clips = {p: make_clips(imgs, p, 16, 900) for p in sim.NOISE_PRESETS}
    base = enh.Cfg()
    rows = []
    for st, r0, af in itertools.product((0.75, 1.0, 1.5, 2.0, 3.0), (1.5,), (1 / 8,)):
        c = replace(base, sigma_t=st, r0=r0, a_floor=af)
        ps, ss, gh = [], [], []
        for p in sim.NOISE_PRESETS:
            a, b, _ = evaluate(c, clips[p])
            ps.append(a)
            ss.append(b)
            gh.append(ghost(c, clips[p]))
        score = float(np.mean(ps) + 5 * np.mean(ss))
        rows.append((score, st, r0, af, float(np.mean(ps)), float(np.mean(ss)), float(np.mean(gh))))
        print("sigma_t %.1f r0 %.1f a_floor 1/%d -> score %.2f (PSNR %.2f SSIM %.3f ghost %.2f)" % (
            st, r0, round(1 / af), score, *rows[-1][4:]), flush=True)
    rows.sort(reverse=True)
    lines = ["| rank | sigma_t | r0 | a_floor | PSNR | SSIM | ghost ratio | score |", "|---|---|---|---|---|---|---|---|"]
    for i, r in enumerate(rows):
        lines.append("| %d | %.1f | %.1f | 1/%d | %.2f | %.3f | %.2f | %.2f |" % (i + 1, r[1], r[2], round(1 / r[3]), r[4], r[5], r[6], r[0]))
    open(os.path.join(ROOT, "docs", "results", "retune_low_sigma.md"), "w").write(
        "Tuning split images [70:71], 3 presets, 16 frames (first 8 ignored). score = PSNR + 5*SSIM, mean over presets.\n\n" + "\n".join(lines) + "\n")
    print("\n".join(lines[:8]))


if __name__ == "__main__":
    main()
