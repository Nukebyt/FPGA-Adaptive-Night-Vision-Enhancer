"""Quality / noise / stability metrics (roadmap task 1.5).

Paired-image metrics: psnr, ssim, loe.
Video metrics:        static_noise (temporal), flicker, ghost_error.
"""
import numpy as np
from skimage.metrics import structural_similarity


def psnr(a, b, peak=255.0):
    mse = np.mean((np.asarray(a, np.float64) - np.asarray(b, np.float64)) ** 2)
    return float("inf") if mse == 0 else float(10.0 * np.log10(peak * peak / mse))


def ssim(a, b):
    return float(structural_similarity(np.asarray(a), np.asarray(b), data_range=255))


def loe(ref, enh, target=50):
    """Lightness order error (lower is better): fraction of pixel pairs whose brightness order
    differs between ref and enh, on both images decimated so the short side is ~`target` px."""
    ref = np.asarray(ref, np.float64)
    enh = np.asarray(enh, np.float64)
    step = max(1, min(ref.shape[:2]) // target)
    r = ref[::step, ::step].ravel()
    e = enh[::step, ::step].ravel()
    err = 0
    # chunked pairwise comparison keeps memory bounded: n ~ 3-4k -> n^2 ~ 10M
    for i in range(0, r.size, 512):
        rr = r[i:i + 512, None] >= r[None, :]
        ee = e[i:i + 512, None] >= e[None, :]
        err += np.count_nonzero(rr != ee)
    return err / float(r.size * r.size)


def static_noise(frames, patch):
    """Mean per-pixel temporal std (ddof=1) inside patch=(y0,y1,x0,x1) of a (T,H,W) clip.
    Only meaningful over a span with constant scene brightness (a controller step inflates it)."""
    y0, y1, x0, x1 = patch
    p = np.asarray(frames, np.float64)[:, y0:y1, x0:x1]
    return float(np.mean(np.std(p, axis=0, ddof=1)))


def flicker(frames):
    """Mean absolute frame-to-frame change of the frame-mean luma (grey levels). 0 for steady brightness."""
    m = np.asarray(frames, np.float64).reshape(len(frames), -1).mean(axis=1)
    return float(np.mean(np.abs(np.diff(m))))


def ghost_error(out, gt, motion_mask, baseline_out, dilate=8):
    """Error around moving objects: MSE(out, gt) vs. MSE(baseline_out, gt) inside the motion mask dilated
    by `dilate` px. `baseline_out` is the same pipeline with the temporal stage off. A ratio above 1 means
    the temporal stage smears or ghosts relative to the baseline.
    Arrays are (T,H,W); motion_mask is bool (T,H,W). Returns (mse_out, mse_base, ratio)."""
    import cv2

    k = cv2.getStructuringElement(cv2.MORPH_ELLIPSE, (2 * dilate + 1, 2 * dilate + 1))
    reg = np.stack([cv2.dilate(m.astype(np.uint8), k).astype(bool) for m in motion_mask])
    o = np.asarray(out, np.float64)[reg] - np.asarray(gt, np.float64)[reg]
    b = np.asarray(baseline_out, np.float64)[reg] - np.asarray(gt, np.float64)[reg]
    mo, mb = float(np.mean(o * o)), float(np.mean(b * b))
    return mo, mb, (mo / mb if mb > 0 else float("inf"))
