"""Run the float design model on the real night clips and save evidence (first real-footage sanity check).

For each clip: process a segment at 640x480, then write
  docs/results/real_<name>.png   input (x1 and x4 for viewing) vs. enhanced, 3 time points
and for lampstep also a trace plot of input mean, output mean and gain G over time.
Usage: python -I scripts/real_clip_test.py
"""
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "scripts"))
import matplotlib  # noqa: E402

matplotlib.use("Agg")
import matplotlib.pyplot as plt  # noqa: E402

from clip_to_y8 import load_clip_480  # noqa: E402
from model import enh  # noqa: E402

CLIPS = {
    "static_dimroom": ("static_dimroom_iso2000_1-60.mp4", 0, 240),
    "move_slow_hand": ("move_slow_hand_iso2000_1-60.mp4", 300, 300),
    "brightsource": ("brightsource_iso2000-1-60.mp4", 0, 300),
    "static_verydark": ("static_verydark_iso2000_1-60.mp4", 0, 240),
    "lampstep": ("lampstep_iso2000_1-60.mp4", 0, None),
}


def label(img, txt):
    t = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
    cv2.putText(t, txt, (6, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
    return t


def main():
    for name, (f, start, count) in CLIPS.items():
        clip = load_clip_480(os.path.join(ROOT, "data", "own_clips", f), start, count)
        out, log = enh.run_clip(clip, enh.Cfg(), return_log=True)
        n = len(clip)
        pts = [n // 4, n // 2, n - 1]
        rows = []
        for i in pts:
            x4 = np.clip(clip[i].astype(np.float32) * 4, 0, 255).astype(np.uint8)
            rows.append(np.hstack([label(clip[i], "input"), label(x4, "input x4"), label(out[i], "enhanced g=%.1f" % log[i]["g"])]))
        cv2.imwrite(os.path.join(ROOT, "docs", "results", "real_%s.png" % name),
                    cv2.resize(np.vstack(rows), None, fx=0.5, fy=0.5, interpolation=cv2.INTER_AREA))
        m_in = clip.reshape(n, -1).mean(axis=1)
        m_out = out.reshape(n, -1).mean(axis=1)
        print("%-16s frames %4d  input mean %.1f..%.1f  output mean %.1f..%.1f  gain %.1f..%.1f" % (
            name, n, m_in.min(), m_in.max(), m_out.min(), m_out.max(),
            min(l["g"] for l in log), max(l["g"] for l in log)), flush=True)
        if name == "lampstep":
            fig, ax = plt.subplots(3, 1, figsize=(8, 7), sharex=True, constrained_layout=True)
            t = np.arange(n) / 58.4
            ax[0].plot(t, m_in, color="#555555", lw=1.4)
            ax[0].set_ylabel("input mean luma")
            ax[1].plot(t, m_out, color="#2a6fb0", lw=1.4)
            ax[1].axhline(enh.Cfg().target, color="#888888", lw=0.8)
            ax[1].set_ylabel("output mean luma")
            ax[2].plot(t, [l["g"] for l in log], color="#c26a1b", lw=1.4)
            ax[2].set_yscale("log")
            ax[2].set_ylabel("gain G")
            ax[2].set_xlabel("seconds")
            ax[0].set_title("Real lamp-step clip, float design model", loc="left", fontsize=11)
            for x in ax:
                x.spines[["top", "right"]].set_visible(False)
            fig.savefig(os.path.join(ROOT, "docs", "results", "real_lampstep_trace.png"), dpi=130)


if __name__ == "__main__":
    main()
