"""Closed-loop step response of the controller (roadmap tasks 2.4 / 2.8 / 4.8 reference).

Static scene with a moving object; scene exposure steps up at frame 30 (x3.75 brighter) and back down at 60.
Compares the tuned controller with a fast one and an over-aggressive one, to show where stability ends.
Linear-loop argument (docs/controller.md): output mean ~ G^gamma_eff, so loop gain per frame is k*gamma_eff;
stable and monotone for k*gamma_eff < 1, oscillatory above 1, unstable above 2.

Usage: python -I scripts/phase2_stepresponse.py [--preset moderate]
Writes docs/results/step_response_<preset>.png and prints the table.
"""
import argparse
import json
import os
import sys
from dataclasses import replace

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
import matplotlib  # noqa: E402

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from model import enh, lowlight_sim as sim, metrics  # noqa: E402

T, UP, DOWN = 90, 30, 60
LOW, HIGH = 0.008, 0.03


def settle_frames(m, start, target, tol=0.10, hold=5):
    """Frames after `start` until |m-target| < tol*target for `hold` consecutive frames."""
    ok = np.abs(np.asarray(m) - target) < tol * target
    for i in range(start, len(m) - hold):
        if ok[i:i + hold].all():
            return i - start
    return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--preset", default="moderate")
    a = ap.parse_args()
    man = json.load(open(os.path.join(ROOT, "data", "benchmark_manifest.json")))
    hi = cv2.imread(os.path.join(ROOT, man["tuning"][31]["high"]), cv2.IMREAD_GRAYSCALE)
    gt, mask = sim.clip_from_still(hi, T, seed=3)
    exp = np.full(T, LOW)
    exp[UP:DOWN] = HIGH
    noisy = sim.simulate_clip(gt, exp, seed=9, **sim.NOISE_PRESETS[a.preset])

    base = enh.Cfg()
    variants = [
        ("tuned (k=0.5, rate limit, deadband)", base, "-"),
        ("fast (k=2)", replace(base, k=2.0, rl_up=5.0, rl_dn=5.0), "--"),
        ("over-aggressive (k=5, no limit, no deadband)", replace(base, k=5.0, rl_up=5.0, rl_dn=5.0, deadband=0.0), ":"),
    ]
    colors = ["#2a6fb0", "#c26a1b", "#555555"]
    fig, ax = plt.subplots(3, 1, figsize=(8, 8), sharex=True, constrained_layout=True)
    rows = ["| controller | settle after up-step | settle after down-step | max overshoot | steady flicker (grey levels/frame) |",
            "|---|---|---|---|---|"]
    for (name, cfg, ls), col in zip(variants, colors):
        out, log = enh.run_clip(noisy, cfg, return_log=True)
        m = np.array([l["m_out"] for l in log])
        g = np.array([l["g"] for l in log])
        ax[0].plot(m, ls, color=col, lw=1.6, label=name)
        ax[1].plot(g, ls, color=col, lw=1.6)
        ax[2].plot(np.abs(np.diff(np.log(g), prepend=np.log(g[0]))), ls, color=col, lw=1.2)
        su, sd = settle_frames(m, UP, cfg.target), settle_frames(m, DOWN, cfg.target)
        over = float(max(m[UP:DOWN].max(), m[DOWN:].max(), m[:UP].max()) / cfg.target - 1.0)
        fl = 0.5 * (metrics.flicker(out[UP - 12:UP]) + metrics.flicker(out[DOWN - 12:DOWN]))
        rows.append("| %s | %s | %s | %.0f%% | %.2f |" % (name, su, sd, 100 * max(over, 0), fl))
    ax[0].axhline(base.target, color="#888888", lw=0.8)
    ax[0].text(T - 1, base.target + 3, "target", ha="right", color="#555555", fontsize=9)
    for k in (0, 1, 2):
        for x in (UP, DOWN):
            ax[k].axvline(x, color="#bbbbbb", lw=0.8)
    ax[0].set_ylabel("output mean luma")
    ax[1].set_ylabel("gain G")
    ax[1].set_yscale("log")
    ax[2].set_ylabel("|d ln G| per frame")
    ax[2].set_xlabel("frame (exposure x3.75 at 30, back at 60)")
    ax[0].legend(frameon=False, fontsize=9, loc="lower right")
    ax[0].set_title("Controller step response, %s noise preset" % a.preset, loc="left", fontsize=11)
    for x in ax:
        x.spines[["top", "right"]].set_visible(False)
    out_png = os.path.join(ROOT, "docs", "results", "step_response_%s.png" % a.preset)
    fig.savefig(out_png, dpi=130)
    txt = "\n".join(rows)
    open(os.path.join(ROOT, "docs", "results", "step_response_%s.md" % a.preset), "w").write(txt + "\n")
    print(txt)
    print("wrote", out_png)


if __name__ == "__main__":
    main()
