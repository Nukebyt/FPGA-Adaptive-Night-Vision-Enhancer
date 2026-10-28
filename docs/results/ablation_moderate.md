preset **moderate**, 2 design images x 24 frames (first 8 ignored), design images from the LOL tuning split

| variant | PSNR (dB) | SSIM | static noise std | ghost ratio |
|---|---|---|---|---|
| tone map only | 12.83 | 0.156 | 48.95 | - |
| + temporal | 17.24 | 0.509 | 5.48 | 0.61 |
| + temporal + spatial | 17.43 | 0.657 | 1.78 | 1.41 |
| + temporal + spatial + sharpen (coupled = full) | 17.43 | 0.657 | 1.78 | 1.41 |
| same, strengths fixed (uncoupled) | 17.50 | 0.643 | 2.89 | 1.29 |
