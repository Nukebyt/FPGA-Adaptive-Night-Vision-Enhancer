"""Freeze the synthetic VIDEO benchmark (roadmap 1.6): a spec, a deterministic generator and checksums.

10 clips of 60 frames, 640x480, from the 10 first LOL *benchmark* images' well-lit versions:
  preset   = lol / moderate / harsh  (i mod 3)
  schedule = steady / pulse / step_up / steady / step_down (i mod 5), exposure 0.008 <-> 0.03
  pan      = (0,0) static background for even i, (2,0) px/frame for odd i
  seed     = 1000 + i (clip geometry) and 2000 + i (noise)
Never tune on these. get_clip(i) regenerates (gt, motion_mask, noisy, exposure) deterministically.
Checksums depend on the numpy/opencv versions that produced them; they are stored with the versions and
verified with --check (a mismatch with different versions is a warning to regenerate, not necessarily a bug).

Usage: python -I scripts/make_video_benchmark.py [--check]
"""
import hashlib
import json
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model import lowlight_sim as sim  # noqa: E402

OUT = os.path.join(ROOT, "data", "video_benchmark_manifest.json")
PRESETS = ["lol", "moderate", "harsh"]
SCHEDULES = ["steady", "pulse", "step_up", "steady", "step_down"]
T, LOW, HIGH = 60, 0.008, 0.03


def spec(i, man):
    return dict(index=i, image=man["benchmark"][i]["high"], preset=PRESETS[i % 3], schedule=SCHEDULES[i % 5],
                pan=[0, 0] if i % 2 == 0 else [2, 0], seed_geometry=1000 + i, seed_noise=2000 + i, frames=T)


def get_clip(i, man=None):
    man = man or json.load(open(os.path.join(ROOT, "data", "benchmark_manifest.json")))
    s = spec(i, man)
    hi = cv2.imread(os.path.join(ROOT, s["image"]), cv2.IMREAD_GRAYSCALE)
    gt, mask = sim.clip_from_still(hi, T, seed=s["seed_geometry"], pan=tuple(s["pan"]))
    exp = sim.exposure_schedule(T, s["schedule"], low=LOW, high=HIGH)
    noisy = sim.simulate_clip(gt, exp, seed=s["seed_noise"], **sim.NOISE_PRESETS[s["preset"]])
    return gt, mask, noisy, exp


def digest(a):
    return hashlib.sha256(np.ascontiguousarray(a).tobytes()).hexdigest()


def main():
    man = json.load(open(os.path.join(ROOT, "data", "benchmark_manifest.json")))
    versions = dict(numpy=np.__version__, opencv=cv2.__version__)
    if "--check" in sys.argv:
        frozen = json.load(open(OUT))
        bad = 0
        for c in frozen["clips"]:
            gt, mask, noisy, _ = get_clip(c["index"], man)
            if digest(noisy) != c["sha256_noisy"] or digest(gt) != c["sha256_gt"]:
                print("MISMATCH clip", c["index"])
                bad += 1
        print("versions now:", versions, "| frozen with:", frozen["versions"])
        print("video benchmark check:", "FAIL" if bad else "ok")
        return 1 if bad else 0
    if os.path.exists(OUT):
        print("video benchmark already frozen:", OUT)
        return 1
    clips = []
    for i in range(10):
        gt, mask, noisy, _ = get_clip(i, man)
        clips.append(dict(spec(i, man), sha256_gt=digest(gt), sha256_noisy=digest(noisy), mean_luma_noisy=float(noisy.mean())))
        print("clip %d  %-8s %-9s pan %s  mean luma %.1f" % (i, clips[-1]["preset"], clips[-1]["schedule"], clips[-1]["pan"], noisy.mean()))
    json.dump(dict(versions=versions, exposure=dict(low=LOW, high=HIGH), clips=clips), open(OUT, "w"), indent=1)
    print("frozen ->", OUT)
    return 0


if __name__ == "__main__":
    sys.exit(main())
