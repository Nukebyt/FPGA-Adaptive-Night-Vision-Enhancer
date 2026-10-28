"""Sanity demo: synthetic low-light frame vs. the three baselines (PSNR/SSIM/LOE against ground truth).
Run: .venv/Scripts/python.exe scripts/demo_baselines.py [exposure]
Writes docs/results/demo_baselines.png and prints a table. Not a benchmark: one synthetic frame.
"""
import sys
from pathlib import Path

import cv2
import numpy as np

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))
from model import baselines, lowlight_sim as sim, metrics, stats  # noqa: E402


def main():
    exposure = float(sys.argv[1]) if len(sys.argv) > 1 else 0.03
    gt, _ = sim.synth_clip(1, 480, 640, seed=0)
    dark = sim.simulate_clip(gt, exposure, seed=0)[0]
    gt = gt[0]
    cands = {
        "raw (dark)": dark,
        "gamma 0.45 x4": baselines.gamma_correct(dark, 0.45, 4.0),
        "hist-eq": baselines.hist_eq(dark),
        "CLAHE": baselines.clahe(dark),
    }
    print(f"exposure={exposure}  mean luma gt={gt.mean():.1f} dark={dark.mean():.1f}  "
          f"noise sigma est (dark)={stats.noise_sigma(dark):.2f}")
    print(f"{'method':<16}{'PSNR':>8}{'SSIM':>8}{'LOE':>8}{'mean':>8}{'noise':>8}")
    for name, img in cands.items():
        print(f"{name:<16}{metrics.psnr(gt, img):>8.2f}{metrics.ssim(gt, img):>8.3f}"
              f"{metrics.loe(gt, img):>8.3f}{img.mean():>8.1f}{stats.noise_sigma(img):>8.2f}")
    tiles = [gt] + list(cands.values())
    labels = ["ground truth"] + list(cands)
    out = []
    for img, lab in zip(tiles, labels):
        t = cv2.cvtColor(cv2.resize(img, (320, 240)), cv2.COLOR_GRAY2BGR)
        cv2.putText(t, lab, (6, 20), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2)
        out.append(t)
    out.append(np.zeros_like(out[0]))
    sheet = np.vstack([np.hstack(out[0:3]), np.hstack(out[3:6])])
    dst = ROOT / "docs" / "results" / "demo_baselines.png"
    dst.parent.mkdir(parents=True, exist_ok=True)
    cv2.imwrite(str(dst), sheet)
    print("wrote", dst)


if __name__ == "__main__":
    main()
