Hardware ablation: the same clips on the board with stages switched off through the CSR enable bits (the controller is unchanged, so the gain is the same).

| clip | stages | mean luma | temporal std | SNR (mean / temporal std) | spatial noise sigma |
|---|---|---|---|---|---|
| static_dimroom | tone map only | 133.6 | 2.84 | 47.1 | 1.10 |
| static_dimroom | + temporal | 133.6 | 2.84 | 47.1 | 1.10 |
| static_dimroom | + temporal + spatial | 133.6 | 2.84 | 47.1 | 1.10 |
| static_dimroom | full (+ sharpen) | 133.7 | 3.51 | 38.1 | 1.79 |
| static_brighter | tone map only | 119.5 | 3.21 | 37.2 | 1.33 |
| static_brighter | + temporal | 119.6 | 3.06 | 39.1 | 1.28 |
| static_brighter | + temporal + spatial | 119.6 | 3.05 | 39.2 | 1.27 |
| static_brighter | full (+ sharpen) | 119.4 | 3.73 | 32.0 | 2.00 |
| static_verydark | tone map only | 86.5 | 6.19 | 14.0 | 2.28 |
| static_verydark | + temporal | 87.3 | 1.67 | 52.3 | 2.13 |
| static_verydark | + temporal + spatial | 87.5 | 1.48 | 59.2 | 1.57 |
| static_verydark | full (+ sharpen) | 87.3 | 1.59 | 55.0 | 1.82 |
