"""Scene statistics (roadmap task 2.1), defined the way the RTL will compute them.

* histogram: 256 bins of 8-bit luma.
* mean:      floor(sum(v*h[v]) / N), integer.
* percentile (num/den): smallest v with cdf[v] >= ceil(N*num/den), cdf inclusive. Pure integer,
             one running sum over the histogram -> a small sequential engine in hardware.
* noise:     Immerkaer's estimate. sum|I * K| with K = [[1,-2,1],[-2,4,-2],[1,-2,1]] over the interior,
             sigma = sqrt(pi/2) * sum / (6*(W-2)*(H-2)). Hardware keeps the integer sum (one accumulator).
"""
import numpy as np

NBINS = 256
_K = np.array([[1, -2, 1], [-2, 4, -2], [1, -2, 1]], dtype=np.int32)


def histogram(img_u8):
    return np.bincount(np.asarray(img_u8, np.uint8).ravel(), minlength=NBINS).astype(np.int64)


def mean_from_hist(hist):
    n = int(hist.sum())
    return int((hist * np.arange(NBINS)).sum() // n)


def percentile_from_hist(hist, num, den):
    n = int(hist.sum())
    target = max(1, -(-n * num // den))  # ceil(n*num/den), at least 1
    cdf = np.cumsum(hist)
    return int(np.searchsorted(cdf, target, side="left"))


def percentiles(hist):
    """(p1, p50, p99) as defined above."""
    return (percentile_from_hist(hist, 1, 100),
            percentile_from_hist(hist, 50, 100),
            percentile_from_hist(hist, 99, 100))


def noise_sum(img_u8):
    """Integer accumulator of the Immerkaer filter response (what the RTL keeps per frame)."""
    a = np.asarray(img_u8, np.int32)
    h, w = a.shape
    acc = np.zeros((h - 2, w - 2), np.int32)
    for dy in range(3):
        for dx in range(3):
            acc += _K[dy, dx] * a[dy:h - 2 + dy, dx:w - 2 + dx]
    return int(np.abs(acc).sum())


def noise_sigma(img_u8):
    h, w = np.asarray(img_u8).shape
    return float(np.sqrt(np.pi / 2.0) * noise_sum(img_u8) / (6.0 * (w - 2) * (h - 2)))
