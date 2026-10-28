"""One-command paired-image metrics (roadmap tasks 1.7 / 7.1).

Runs every method on the frozen LOL benchmark (default) or the tuning split and prints a table;
writes docs/results/metrics_<split>.csv (per image) and .md (means). Verifies file checksums
against the manifest first and aborts on any mismatch, so numbers can only come from frozen data.

Usage: python -I scripts/run_metrics.py [--split benchmark|tuning]
New methods (the engine) are added to METHODS; they take and return an 8-bit luma image.
"""
import argparse
import csv
import json
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model import baselines, metrics, stats  # noqa: E402
from scripts.make_benchmark import sha  # noqa: E402

METHODS = {
    "raw": lambda x: x,
    "gamma0.4": lambda x: baselines.gamma_correct(x, 0.4, 1.0),
    "hist-eq": baselines.hist_eq,
    "CLAHE": baselines.clahe,
}


def load_gray(rel):
    img = cv2.imread(os.path.join(ROOT, rel), cv2.IMREAD_GRAYSCALE)
    if img is None:
        raise FileNotFoundError(rel)
    return img


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--split", default="benchmark", choices=["benchmark", "tuning"])
    a = ap.parse_args()
    man = json.load(open(os.path.join(ROOT, "data", "benchmark_manifest.json")))
    items = man[a.split]
    rows = []
    for it in items:
        for key in ("low", "high"):
            if sha(os.path.join(ROOT, it[key])) != it["sha256_" + key]:
                print("CHECKSUM MISMATCH:", it[key])
                return 1
        lo, hi = load_gray(it["low"]), load_gray(it["high"])
        for name, fn in METHODS.items():
            out = fn(lo)
            rows.append({"image": it["name"], "split": it["split"], "method": name,
                         "psnr": metrics.psnr(hi, out), "ssim": metrics.ssim(hi, out),
                         "loe": metrics.loe(hi, out), "mean_luma": float(out.mean()),
                         "noise_sigma": stats.noise_sigma(out)})
    resdir = os.path.join(ROOT, "docs", "results")
    os.makedirs(resdir, exist_ok=True)
    with open(os.path.join(resdir, "metrics_%s.csv" % a.split), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(rows[0].keys()))
        w.writeheader()
        w.writerows(rows)
    lines = ["| method | PSNR (dB) | SSIM | LOE | mean luma | noise sigma |", "|---|---|---|---|---|---|"]
    for m in METHODS:
        r = [x for x in rows if x["method"] == m]
        mean = lambda k: np.mean([x[k] for x in r])  # noqa: E731
        lines.append("| %s | %.2f | %.3f | %.3f | %.1f | %.2f |" % (
            m, mean("psnr"), mean("ssim"), mean("loe"), mean("mean_luma"), mean("noise_sigma")))
    table = "\n".join(lines)
    with open(os.path.join(resdir, "metrics_%s.md" % a.split), "w") as f:
        f.write("LOL %s split, %d images, luma only (BT.601 gray of the RGB files)\n\n%s\n" % (a.split, len(items), table))
    print("LOL %s split, %d images\n" % (a.split, len(items)))
    print(table)
    return 0


if __name__ == "__main__":
    sys.exit(main())
