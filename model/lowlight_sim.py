"""Synthetic low-light generator (roadmap task 1.4).

Takes well-lit frames (the ground truth), scales scene radiance by an exposure
factor, applies Poisson (shot) + Gaussian (read) noise in electrons, then
re-encodes with a display gamma and quantises to 8 bits.

    gt (display-referred u8) --gamma--> linear radiance L in [0,1]
    electrons = Poisson(L * exposure * full_well) + N(0, read_sigma)
    out       = encode(electrons / full_well)

Variance of the pre-encode signal is  (L*exposure/full_well) + (read_sigma/full_well)^2
so noise is signal dependent, and dark pixels are dominated by read noise.

All randomness comes from an explicit numpy Generator so clips are reproducible.
"""
from dataclasses import dataclass

import numpy as np

GAMMA = 2.2


@dataclass(frozen=True)
class SensorParams:
    exposure: float = 0.03      # scene scale vs. the well-lit ground truth (1.0 = unchanged)
    full_well: float = 400.0    # electrons at ADC full scale; lower = noisier
    read_sigma: float = 2.0     # read noise, electrons rms


def to_linear(u8):
    return (np.asarray(u8, dtype=np.float64) / 255.0) ** GAMMA


def to_u8(lin):
    x = np.clip(lin, 0.0, 1.0) ** (1.0 / GAMMA)
    return np.clip(np.rint(255.0 * x), 0, 255).astype(np.uint8)


def simulate_frame(gt_u8, params, rng):
    lin = to_linear(gt_u8) * params.exposure
    electrons = rng.poisson(lin * params.full_well).astype(np.float64)
    electrons += rng.normal(0.0, params.read_sigma, size=lin.shape)
    return to_u8(electrons / params.full_well)


def simulate_clip(gt_frames, exposure, seed, full_well=400.0, read_sigma=2.0):
    """gt_frames: (T,H,W) u8. exposure: scalar or length-T schedule. Noise is independent per frame."""
    gt_frames = np.asarray(gt_frames)
    t = gt_frames.shape[0]
    exp = np.broadcast_to(np.asarray(exposure, dtype=np.float64), (t,))
    rng = np.random.default_rng(seed)
    out = np.empty_like(gt_frames)
    for i in range(t):
        out[i] = simulate_frame(gt_frames[i], SensorParams(float(exp[i]), full_well, read_sigma), rng)
    return out


def duplicate_content(gt_frames, factor=2):
    """30 -> 60 fps: repeat scene content. Noise is drawn per output frame by simulate_clip,
    so the repeated frames get independent noise (like a 60 fps sensor viewing 30 fps content)."""
    return np.repeat(np.asarray(gt_frames), factor, axis=0)


def synth_clip(n_frames, height=480, width=640, seed=0):
    """Self-contained test scene (no dataset needed): textured background with two moving objects.

    Returns (gt_frames u8 (T,H,W), motion_masks bool (T,H,W)). Motion masks cover the objects'
    current positions and are used by the ghosting metric.
    """
    import cv2
    from skimage import data

    bg = cv2.resize(data.camera(), (width, height), interpolation=cv2.INTER_AREA)
    rng = np.random.default_rng(seed)
    bg = np.clip(bg.astype(np.int16) + rng.integers(-4, 5, size=bg.shape), 0, 255).astype(np.uint8)
    frames = np.empty((n_frames, height, width), np.uint8)
    masks = np.zeros((n_frames, height, width), bool)
    for t in range(n_frames):
        f = bg.copy()
        m = np.zeros((height, width), np.uint8)
        cx = int(80 + (width - 160) * ((t * 7) % 200) / 200.0)
        cy = int(height * 0.3)
        cv2.circle(f, (cx, cy), 28, 235, -1)
        cv2.circle(m, (cx, cy), 28, 1, -1)
        bx = int(width - 100 - (width - 220) * ((t * 5) % 160) / 160.0)
        by = int(height * 0.7)
        cv2.rectangle(f, (bx - 30, by - 20), (bx + 30, by + 20), 25, -1)
        cv2.rectangle(m, (bx - 30, by - 20), (bx + 30, by + 20), 1, -1)
        frames[t] = f
        masks[t] = m.astype(bool)
    return frames, masks


def exposure_schedule(n_frames, kind="steady", low=0.02, high=0.08, at=None):
    """Exposure vs. time for controller tests: 'steady', 'step_up', 'step_down', 'pulse' (headlights)."""
    e = np.full(n_frames, low, dtype=np.float64)
    at = n_frames // 3 if at is None else at
    if kind == "steady":
        pass
    elif kind == "step_up":
        e[at:] = high
    elif kind == "step_down":
        e[:] = high
        e[at:] = low
    elif kind == "pulse":
        e[at:at + max(2, n_frames // 6)] = high
    else:
        raise ValueError(kind)
    return e


# Noise presets, calibrated on the LOL *tuning* split (scripts/calibrate note in docs/results/sim_calibration.md):
# LOL low images have Immerkaer sigma ~1.1 at mean luma ~13, which a 'lol' sensor reproduces with exposure ~0.008.
# 'moderate' and 'harsh' are deliberately much noisier than LOL: they are where adaptive denoising matters and
# are closer to a raw phone sensor at night. Quote results per preset, never pooled.
NOISE_PRESETS = {
    "lol": dict(full_well=30000.0, read_sigma=3.0),
    "moderate": dict(full_well=2000.0, read_sigma=2.0),
    "harsh": dict(full_well=400.0, read_sigma=2.0),
}
DEFAULT_EXPOSURE = 0.008   # gives mean luma ~14 on well-lit indoor scenes, like LOL low


def simulate_clip_preset(gt_frames, preset, exposure=DEFAULT_EXPOSURE, seed=0):
    return simulate_clip(gt_frames, exposure, seed, **NOISE_PRESETS[preset])


def clip_from_still(still_u8, n_frames, seed=0, size=(640, 480), pan=(0, 0), obj_still=None, obj=100):
    """Build a clip with exact ground truth from one well-lit still (e.g. a LOL 'high' image).

    Background: the still resized to cover size*1.15, viewed through a size window that moves by `pan`
    integer px/frame and bounces at the edges (pan=(0,0) = static background).
    Object: an elliptical patch cut from obj_still (or from the still itself) moving on a Lissajous-like
    path, composited with a hard mask so the motion mask is exact.
    Returns (frames u8 (T,H,W), motion_masks bool (T,H,W)).
    """
    import cv2

    w, h = size
    rng = np.random.default_rng(seed)
    bw, bh = int(w * 1.15), int(h * 1.15)
    bg = cv2.resize(np.asarray(still_u8), (bw, bh), interpolation=cv2.INTER_CUBIC)
    src = bg if obj_still is None else cv2.resize(np.asarray(obj_still), (bw, bh), interpolation=cv2.INTER_CUBIC)
    py, px = int(rng.integers(0, bh - obj)), int(rng.integers(0, bw - obj))
    patch = src[py:py + obj, px:px + obj].copy()
    pmask = np.zeros((obj, obj), np.uint8)
    half = obj // 2
    cv2.ellipse(pmask, (half, half), (int(obj * 0.48), int(obj * 0.36)), 0, 0, 360, 1, -1)
    margin = half + 10
    frames = np.empty((n_frames, h, w), np.uint8)
    masks = np.zeros((n_frames, h, w), bool)
    ox0, oy0 = (bw - w) // 2, (bh - h) // 2
    for t in range(n_frames):
        # bouncing window offset
        def bounce(pos0, v, span):
            period = 2 * span
            p = (pos0 + v * t) % period if span > 0 else 0
            return p if p <= span else period - p
        ox = bounce(ox0 if pan[0] else 0, pan[0], bw - w) if pan[0] else ox0
        oy = bounce(oy0 if pan[1] else 0, pan[1], bh - h) if pan[1] else oy0
        f = bg[oy:oy + h, ox:ox + w].copy()
        cx = int(margin + (w - 2 * margin) * (0.5 + 0.5 * np.sin(2 * np.pi * (t * 3 / 120.0 + 0.1))))
        cy = int(margin + (h - 2 * margin) * (0.5 + 0.5 * np.sin(2 * np.pi * (t * 2 / 120.0 + 0.4))))
        x0, y0 = cx - half, cy - half
        m = np.zeros((h, w), bool)
        sl = (slice(y0, y0 + obj), slice(x0, x0 + obj))
        mm = pmask.astype(bool)
        f[sl][mm] = patch[mm]
        m[sl] = mm
        frames[t] = f
        masks[t] = m
    return frames, masks
