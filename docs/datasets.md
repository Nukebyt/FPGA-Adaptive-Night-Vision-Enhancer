# Datasets to download (roadmap Phase 1)

Put everything under `data/` (gitignored). Licences are not checked by me: read each one before using results in anything public.
Links were taken from web search results on 2026-10-25; the ones marked (unverified) I could not open.

## Needed

| # | Dataset | What for | Size | Where |
|---|---|---|---|---|
| 1 | **LOL** (485 train + 15 eval pairs, 400x600, real noise, mostly indoor) | Paired image PSNR/SSIM/LOE (task 7.1), the 50-image benchmark | small (~350 MB) | Project page `daooshee.github.io/BMVC2018website` and Google Drive link on it (paper: https://arxiv.org/abs/1808.04560) (unverified) |
| 2 | *(optional now)* **BVI-RLV** (40 scenes, low-light video at 10% and 20% light, registered to normal-light ground truth, full HD) | Real low-light **video** with ground truth: temporal denoise, flicker, ghosting | large (30k+ frame pairs); take only ~10 scenes if it is split per scene | IEEE DataPort, https://doi.org/10.21227/mzny-8c77 (free IEEE account, no membership) |
| 3 | **Well-lit source video** for the synthetic generator (task 1.4) | Quantitative video results with exact ground truth | any | Your own daytime phone clips (best, 60 fps if possible), and optionally DAVIS 2017 TrainVal 480p from `davischallenge.org` (unverified; it ships object masks I can reuse for the ghosting metric) |
| 4 | **Your own night clips** (>= 10) | Demo and real-noise sanity checks | ~1 GB | Phone |

## Status (2026-10-25)
- LOL: downloaded, verified, frozen (`data/benchmark_manifest.json`).
- BVI-RLV: not available (IEEE login). A Kaggle subset of scenes would be welcome but is not required: video results use synthetic clips built from LOL images.
- Own night clips and well-lit clips: still to record. It is dark outside now, so tonight is a good time for the night clips (settings below).

## Optional

| Dataset | What for | Where |
|---|---|---|
| **ExDark** (7,363 low-light images, 12 classes, boxes) | Downstream detector test (task 7.7) | GitHub `cs-chan/Exclusively-Dark-Image-Dataset`, about 1.4 GB (check the LICENSE file) |
| **SDSD** (150 video pairs) | More video pairs | GitHub `dvlab-research` (ICCV 2021 "Seeing Dynamic Scene in the Dark"). Papers report misaligned frames and overexposed references, so I would skip it unless BVI-RLV is not enough. |

## Not needed
**SID** (raw, tens of GB). Nothing in this pipeline uses raw sensor data.

## How to record your own clips (this decides whether they are usable)
Camera (phone Pro/manual video mode): 1080p, 60 fps (30 fps is fine for offline metrics); **manual and locked** ISO 800-3200,
shutter 1/60, white balance, focus; exposure compensation 0; night mode, HDR, stabilisation and filters **off**; H.264 (or HEVC)
at the highest bitrate; tripod, no digital zoom. Shutter 1/100 (50 Hz mains) or 1/120 (60 Hz) if the preview shows rolling bands.
Target: dark and visibly noisy, clip mean luma roughly 10-30 of 255; if large areas are pure black, raise ISO or add a dim lamp.
Copy the original files over USB (messengers recompress them). Name them `<kind>_<scene>_iso<N>_<shutter>.mp4`.

About 12 clips of 15 s each:
1. Static scenes x3: dim room, street/outdoor, very dark at max ISO (noise and flicker metrics).
2. Moving subject x4: person walking across, hand waving close, car passing, one fast motion (ghosting).
3. Light steps x2: lamp on at ~5 s and off at ~10 s, or headlights sweeping (controller step response).
4. Bright source in the dark x1: streetlight or bare lamp in frame (saturation, blooming).
5. Noise floor x1: same ISO/shutter with the lens covered, 10 s (calibrates the simulator to your camera).
6. Ground-truth pairs for 3-4 of the static scenes: same framing, lights on, low ISO (100-200). Static scenes only.

## Folder layout I will expect
```
data/lol/our485/{low,high}   data/lol/eval15/{low,high}
data/bvi_rlv/<scene>/...     (keep the original names)
data/welllit/                (clips for the synthetic generator)
data/own_clips/              (night clips, original files)
data/exdark/                 (optional)
```

## After the download
I will write `scripts/clip_to_y8.py` (clip to 640x480 8-bit luma files for the HPS feeder), pick the frozen benchmark (about 10 clips and 50 images) and record file checksums in `data/benchmark_manifest.json` (task 1.6). Tuning never touches the benchmark items.
