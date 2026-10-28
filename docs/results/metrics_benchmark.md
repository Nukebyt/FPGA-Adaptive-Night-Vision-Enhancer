LOL benchmark split, 50 images, luma only (BT.601 gray of the RGB files)

| method | PSNR (dB) | SSIM | LOE | mean luma | noise sigma |
|---|---|---|---|---|---|
| raw | 7.59 | 0.169 | 0.074 | 14.5 | 1.26 |
| gamma0.4 | 14.19 | 0.662 | 0.074 | 71.7 | 4.67 |
| hist-eq | 15.14 | 0.445 | 0.074 | 127.6 | 14.85 |
| CLAHE | 9.42 | 0.387 | 0.132 | 32.0 | 3.40 |
