"""Measure the recorded night clips (roadmap 1.2): brightness, black clipping, noise (spatial and temporal).

For every file in data/own_clips: sample frames, take luma, report
  mean luma, % of pixels at 0, p1/p50/p99 at 1080p,
  spatial noise sigma (Immerkaer) at 1080p and after the pipeline's 4:3 centre crop + resize to 640x480,
  temporal noise (mean per-pixel std over 60 consecutive frames, centre 640x480 crop of the resized frame)
  -- meaningful only for static clips. Writes docs/results/own_clips_summary.md.
Usage: python -I scripts/analyze_clips.py
"""
import glob
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model import stats  # noqa: E402


def to_480(gray):
    h, w = gray.shape
    cw = int(h * 4 / 3)
    x0 = (w - cw) // 2
    return cv2.resize(gray[:, x0:x0 + cw], (640, 480), interpolation=cv2.INTER_AREA)


def read_gray(cap, idx):
    cap.set(cv2.CAP_PROP_POS_FRAMES, idx)
    ok, f = cap.read()
    return cv2.cvtColor(f, cv2.COLOR_BGR2GRAY) if ok else None


def main():
    rows = ["| clip | s | mean luma | % zero | p1 / p50 / p99 | noise sigma 1080p | noise sigma 640x480 | temporal std 640x480 |",
            "|---|---|---|---|---|---|---|---|"]
    trace = {}
    for path in sorted(glob.glob(os.path.join(ROOT, "data", "own_clips", "*.mp4"))):
        name = os.path.basename(path)
        cap = cv2.VideoCapture(path)
        n = int(cap.get(cv2.CAP_PROP_FRAME_COUNT))
        fps = cap.get(cv2.CAP_PROP_FPS)
        idxs = np.linspace(0, n - 2, 24).astype(int)
        means, zero, s1080, s480 = [], [], [], []
        hist = np.zeros(256, np.int64)
        for i in idxs:
            g = read_gray(cap, int(i))
            if g is None:
                continue
            means.append(g.mean())
            zero.append(100.0 * np.mean(g == 0))
            hist += stats.histogram(g)
            s1080.append(stats.noise_sigma(g))
            s480.append(stats.noise_sigma(to_480(g)))
        p1, p50, p99 = stats.percentiles(hist)
        # temporal std on 60 consecutive frames from the middle
        cap.set(cv2.CAP_PROP_POS_FRAMES, n // 2)
        stack = []
        for _ in range(60):
            ok, f = cap.read()
            if not ok:
                break
            stack.append(to_480(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY)).astype(np.float32))
        tstd = float(np.std(np.stack(stack), axis=0, ddof=1).mean()) if len(stack) > 10 else float("nan")
        rows.append("| %s | %.1f | %.1f | %.1f | %d / %d / %d | %.2f | %.2f | %.2f |" % (
            name, n / fps, np.mean(means), np.mean(zero), p1, p50, p99, np.mean(s1080), np.mean(s480), tstd))
        trace[name] = means
        print(rows[-1], flush=True)
    txt = "\n".join(rows)
    open(os.path.join(ROOT, "docs", "results", "own_clips_summary.md"), "w").write(txt + "\n")
    # lamp-step time course
    for k, v in trace.items():
        if k.startswith("lampstep"):
            print("\nlampstep mean luma over 24 samples:", [round(x, 1) for x in v])


if __name__ == "__main__":
    main()
