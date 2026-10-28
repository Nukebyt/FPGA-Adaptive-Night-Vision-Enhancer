Static real clips (your camera, ISO 2000, 1/60 s), first 300 frames, statistics after 40 settling frames. Engine = FPGA board output.

| clip | method | mean luma | p99 | temporal std (grey levels) | SNR = mean / temporal std | spatial noise sigma | frame-mean flicker |
|---|---|---|---|---|---|---|---|
| brightsource_iso2000-1-60 | raw | 32.4 | 255 | 1.94 | 16.7 | 0.43 | 0.21 |
| brightsource_iso2000-1-60 | gamma0.4 | 100.4 | 255 | 2.66 | 37.7 | 0.67 | 0.33 |
| brightsource_iso2000-1-60 | hist-eq | 131.5 | 255 | 7.13 | 18.5 | 2.56 | 0.06 |
| brightsource_iso2000-1-60 | CLAHE | 45.4 | 255 | 3.26 | 13.9 | 0.87 | 0.26 |
| brightsource_iso2000-1-60 | engine | 132.6 | 255 | 4.18 | 31.7 | 1.47 | 0.43 |
| static_brighter | raw | 31.6 | 255 | 1.75 | 18.1 | 0.65 | 0.79 |
| static_brighter | gamma0.4 | 96.4 | 255 | 2.69 | 35.8 | 0.92 | 1.29 |
| static_brighter | hist-eq | 130.9 | 255 | 5.39 | 24.3 | 2.66 | 0.06 |
| static_brighter | CLAHE | 48.3 | 255 | 2.84 | 17.0 | 1.13 | 0.79 |
| static_brighter | engine | 119.4 | 255 | 3.73 | 32.0 | 2.00 | 0.74 |
| static_dimroom_gt_iso200 | raw | 102.0 | 255 | 1.58 | 64.7 | 0.99 | 0.16 |
| static_dimroom_gt_iso200 | gamma0.4 | 164.0 | 255 | 1.41 | 116.0 | 0.95 | 0.13 |
| static_dimroom_gt_iso200 | hist-eq | 128.3 | 255 | 2.07 | 61.9 | 1.62 | 0.03 |
| static_dimroom_gt_iso200 | CLAHE | 114.8 | 255 | 2.31 | 49.6 | 1.55 | 0.13 |
| static_dimroom_gt_iso200 | engine | 162.9 | 255 | 1.89 | 86.0 | 1.66 | 0.13 |
| static_dimroom | raw | 28.4 | 82 | 1.01 | 28.0 | 0.38 | 0.36 |
| static_dimroom | gamma0.4 | 95.8 | 162 | 2.01 | 47.6 | 0.78 | 0.53 |
| static_dimroom | hist-eq | 130.1 | 253 | 4.07 | 32.0 | 1.74 | 0.06 |
| static_dimroom | CLAHE | 52.8 | 155 | 2.26 | 23.4 | 0.93 | 0.53 |
| static_dimroom | engine | 133.7 | 232 | 3.51 | 38.1 | 1.79 | 0.74 |
| static_verydark | raw | 7.6 | 106 | 0.60 | 12.8 | 0.41 | 0.01 |
| static_verydark | gamma0.4 | 43.9 | 179 | 3.18 | 13.8 | 1.05 | 0.27 |
| static_verydark | hist-eq | 176.8 | 252 | 12.93 | 13.7 | 2.93 | 2.11 |
| static_verydark | CLAHE | 17.1 | 158 | 1.30 | 13.2 | 0.68 | 0.12 |
| static_verydark | engine | 87.3 | 255 | 1.59 | 55.0 | 1.82 | 0.13 |

Static dim room against the ISO-200 reference (time-averaged, well exposed) of the same scene; mean over frames:

| method | PSNR (dB) | SSIM |
|---|---|---|
| raw | 7.45 | 0.192 |
| gamma0.4 | 9.57 | 0.266 |
| hist-eq | 7.46 | 0.191 |
| CLAHE | 8.38 | 0.211 |
| engine | 8.32 | 0.215 |
