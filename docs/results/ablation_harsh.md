preset **harsh**, 2 design images x 24 frames (first 8 ignored), design images from the LOL tuning split

| variant | PSNR (dB) | SSIM | static noise std | ghost ratio |
|---|---|---|---|---|
| tone map only | 7.63 | 0.030 | 100.11 | - |
| + temporal | 14.38 | 0.239 | 9.95 | 0.29 |
| + temporal + spatial | 14.73 | 0.462 | 3.14 | 1.02 |
| + temporal + spatial + sharpen (coupled = full) | 14.73 | 0.462 | 3.14 | 1.02 |
| same, strengths fixed (uncoupled) | 14.70 | 0.432 | 5.16 | 0.97 |
