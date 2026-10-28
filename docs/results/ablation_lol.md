preset **lol**, 2 design images x 24 frames (first 8 ignored), design images from the LOL tuning split

| variant | PSNR (dB) | SSIM | static noise std | ghost ratio |
|---|---|---|---|---|
| tone map only | 18.35 | 0.625 | 8.52 | - |
| + temporal | 18.62 | 0.776 | 1.46 | 1.03 |
| + temporal + spatial | 18.54 | 0.778 | 0.71 | 1.04 |
| + temporal + spatial + sharpen (coupled = full) | 18.60 | 0.787 | 0.83 | 1.03 |
| same, strengths fixed (uncoupled) | 18.59 | 0.784 | 1.22 | 1.02 |
