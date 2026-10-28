LOL benchmark split (50 paired images, luma, resized to 640x480). The engine column is the output of the **FPGA board** after 24 identical frames (controller settled); mean +/- standard error.

| method | PSNR (dB) | SSIM | LOE (lower is better) | mean luma | noise sigma |
|---|---|---|---|---|---|
| raw | 7.59 +/- 0.35 | 0.174 +/- 0.018 | 0.064 | 14.4 | 0.57 |
| gamma0.4 | 14.27 +/- 0.60 | 0.695 +/- 0.018 | 0.064 | 71.8 | 2.37 |
| hist-eq | 15.30 +/- 0.39 | 0.482 +/- 0.021 | 0.064 | 128.4 | 7.36 |
| CLAHE | 9.33 +/- 0.45 | 0.394 +/- 0.022 | 0.129 | 31.2 | 1.57 |
| engine | 20.29 +/- 0.58 | 0.684 +/- 0.014 | 0.071 | 127.3 | 4.75 |

Engine beats all three baselines on 39/50 images in PSNR and on 28/50 in SSIM.
