"""Does the noise coupling earn its place when the noise level CHANGES inside one clip? (roadmap 2.9, decisive test)

Exposure schedule low -> high (x5) -> low: at high exposure the SNR is much better, so the right denoise
strength differs between segments. Fixed-strength pipelines can only fit one regime; the coupled one
should track. Compared: coupled, best fixed (from the first search), 'gentle' fixed, 'heavy' fixed.
Design images: LOL tuning split [30:32]. PSNR/SSIM are reported per segment (first 8 frames after every
exposure change are skipped while the controller settles).
Usage: python -I scripts/phase2_adaptivity.py
"""
import json
import os
import sys
from dataclasses import replace

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model import enh, lowlight_sim as sim, metrics  # noqa: E402

SEG = 30
T = 3 * SEG
LOW, HIGH = 0.006, 0.03
SKIP = 8


def main():
    man = json.load(open(os.path.join(ROOT, "data", "benchmark_manifest.json")))
    imgs = [e["high"] for e in man["tuning"]][30:32]
    exp = np.array([LOW] * SEG + [HIGH] * SEG + [LOW] * SEG)
    base = enh.Cfg()
    variants = {
        "coupled": base,
        "fixed best (a=1/4, lam=1, sharp=.5)": replace(base, coupled=False, fixed_a_min=0.25, fixed_lam=1.0, fixed_sharp=0.5),
        "fixed gentle (a=1/2, lam=.25, sharp=.5)": replace(base, coupled=False, fixed_a_min=0.5, fixed_lam=0.25, fixed_sharp=0.5),
        "fixed heavy (a=1/8, lam=1, sharp=0)": replace(base, coupled=False, fixed_a_min=0.125, fixed_lam=1.0, fixed_sharp=0.0),
    }
    out_lines = []
    for preset in (sys.argv[1:] or ["moderate", "harsh"]):
        res = {k: {"dark": [], "bright": []} for k in variants}
        for i, rel in enumerate(imgs):
            hi = cv2.imread(os.path.join(ROOT, rel), cv2.IMREAD_GRAYSCALE)
            gt, _ = sim.clip_from_still(hi, T, seed=40 + i)
            noisy = sim.simulate_clip(gt, exp, seed=77 + i, **sim.NOISE_PRESETS[preset])
            for name, cfg in variants.items():
                out = enh.run_clip(noisy, cfg)
                dark = list(range(SKIP, SEG)) + list(range(2 * SEG + SKIP, T))
                bright = list(range(SEG + SKIP, 2 * SEG))
                for seg, idx in (("dark", dark), ("bright", bright)):
                    res[name][seg].append((np.mean([metrics.psnr(out[j], gt[j]) for j in idx]),
                                           np.mean([metrics.ssim(out[j], gt[j]) for j in idx[::3]])))
        lines = ["| %s preset | dark PSNR | dark SSIM | bright PSNR | bright SSIM | mean PSNR |" % preset, "|---|---|---|---|---|---|"]
        for name in variants:
            d = np.mean(res[name]["dark"], axis=0)
            b = np.mean(res[name]["bright"], axis=0)
            lines.append("| %s | %.2f | %.3f | %.2f | %.3f | %.2f |" % (name, d[0], d[1], b[0], b[1], (d[0] + b[0]) / 2))
        out_lines += lines + [""]
        print("\n".join(lines) + "\n", flush=True)
    open(os.path.join(ROOT, "docs", "results", "adaptivity_%s.md" % ("_".join(sys.argv[1:]) or "noisy")), "w").write(
        "Exposure x%.0f step inside one clip (%d frames per segment), LOL tuning images [30:32]\n\n%s\n" % (HIGH / LOW, SEG, "\n".join(out_lines)))


if __name__ == "__main__":
    main()
