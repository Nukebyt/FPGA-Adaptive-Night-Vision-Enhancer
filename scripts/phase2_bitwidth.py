"""Quality vs. fractional bits F of the frame store / tone-LUT index (roadmap task 2.10).

For F = 0..4 run the integer model on synthetic clips (LOL tuning image, 3 noise presets) and report
PSNR vs ground truth, PSNR vs the float design model, and the frame-store size in M10K bits and as a
fraction of the device (5,662,720 bits). Writes docs/results/bitwidth.md.
Usage: python -I scripts/phase2_bitwidth.py
"""
import json
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model import enh, lowlight_sim as sim, metrics, pipeline_int  # noqa: E402

DEVICE_M10K_BITS = 5662720
T, SETTLE = 16, 8


def main():
    man = json.load(open(os.path.join(ROOT, "data", "benchmark_manifest.json")))
    hi = cv2.imread(os.path.join(ROOT, man["tuning"][33]["high"]), cv2.IMREAD_GRAYSCALE)
    gt, _ = sim.clip_from_still(hi, T, seed=5)
    rows = ["| preset | F | frame store | M10K share | PSNR vs GT | PSNR vs float model |", "|---|---|---|---|---|---|"]
    for preset in sim.NOISE_PRESETS:
        noisy = sim.simulate_clip_preset(gt, preset, seed=11)
        ref = enh.run_clip(noisy)
        base = np.mean([metrics.psnr(a, b) for a, b in zip(ref[SETTLE:], gt[SETTLE:])])
        rows.append("| %s | float model | - | - | %.2f | - |" % (preset, base))
        for F in range(0, 5):
            out, _ = pipeline_int.run_clip_int(noisy, F)
            bits = 640 * 480 * (8 + F)
            rows.append("| %s | %d | %d bit | %.0f%% | %.2f | %.2f |" % (
                preset, F, 8 + F, 100.0 * bits / DEVICE_M10K_BITS,
                np.mean([metrics.psnr(a, b) for a, b in zip(out[SETTLE:], gt[SETTLE:])]),
                np.mean([metrics.psnr(a, b) for a, b in zip(out[SETTLE:], ref[SETTLE:])])))
            print(rows[-1], flush=True)
    txt = "Integer model, 640x480, %d frames (first %d ignored), one LOL tuning image\n\n%s\n" % (T, SETTLE, "\n".join(rows))
    open(os.path.join(ROOT, "docs", "results", "bitwidth.md"), "w").write(txt)
    print(txt)


if __name__ == "__main__":
    main()
