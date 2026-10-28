"""Adaptive night-vision enhancement: ideal-math design model (roadmap tasks 2.3-2.9).

Stage order (decided in Phase 2, supersedes the rev-1 order):
    input u8 -> temporal (frame store, raw domain) -> spatial sigma filter -> tone map LUT -> unsharp -> out u8
Denoising happens in the sensor domain where the noise is simple and the frame store is independent of
the controller (a gain change cannot create false motion). The tone map consumes the denoised value with
its fractional bits, so averaging precision is not thrown away before the gain is applied.

Controller (once per frame, applied to the NEXT frame - one frame of delay, Architecture decision 3):
    measured: output mean m (after tone map, before sharpen), input histogram, input noise sum
    ln G <- clip(ln G + clip(k*ln(target/m), -rl_dn, +rl_up) [0 inside deadband], ln Gmin, ln Gmax(p99))
    black level B = min(p1, B_max);  tone curve y = 255*clip(G*(v-B)/255, 0, 1)^gamma
    coupling: noise_out = sigma_raw * slope(tone curve at input median)
              a_min   = clip(sigma_t^2 / noise_out^2, A_MIN, 1)      temporal blend floor (denoise strength)
              lam     = clip((noise_out/sigma_t - 1)/2, 0, 1)         spatial filter mix
              sharp   = S_MAX * clip(1 - noise_out/sigma_hi, 0, 1)    sharpen amount
              core    = max(noise_out * sqrt(a_min/(2-a_min)), 1)     sharpen coring (residual noise estimate)
All window operations use replicate borders (the RTL window generator must match).
"""
from dataclasses import dataclass, field, replace

import numpy as np

from . import roms, stats

EPS = 1e-9


@dataclass(frozen=True)
class Cfg:
    # stage switches (ablation)
    temporal: bool = True
    spatial: bool = True
    sharpen: bool = True
    coupled: bool = True          # False: fixed strengths below instead of the noise-driven formulas
    # fixed strengths used when coupled=False
    fixed_a_min: float = 0.25
    fixed_lam: float = 0.5
    fixed_sharp: float = 0.5
    # tone curve
    gamma: float = 0.4
    b_max: float = 16.0
    # controller
    target: float = 128.0
    k: float = 0.5
    rl_up: float = 0.20
    rl_dn: float = 0.40
    deadband: float = 0.05
    g_min: float = 1.0
    g_max: float = 64.0
    g_init: float = 4.0
    b_sigma: bool = True          # black level also limited to ~1 sigma of the noise estimate
    cap_pct: int = 95             # percentile that must stay below full scale (highlight headroom)
    head: float = 255.0           # p99 output ceiling used for the gain clamp (tuned on LOL tuning split)
    sigma_iir: float = 0.25
    # coupling constants
    sigma_t: float = 1.5          # retuned (docs/results/retune_low_sigma.md): 3.0 under-denoised clean footage
    sigma_hi: float = 12.0
    a_floor: float = 1.0 / 8.0     # retuned on LOL tuning split (docs/results/retune.md): 1/8 beats 1/16 in every setting
    s_max: float = 1.0
    # temporal motion curve: r = mean|cur-prev| / sigma
    r0: float = 1.5
    r1: float = 3.9375            # = 63/16: the integer motion index saturates exactly here
    # spatial sigma filter threshold in units of sigma
    k_sp: float = 2.5
    feedback: bool = True         # False: gain frozen at g_init (manual mode)


def windows(img):
    """(9,H,W) stack of 3x3 neighbours with replicate borders, raster order, centre at index 4."""
    p = np.pad(img, 1, mode="edge")
    h, w = img.shape
    return np.stack([p[dy:dy + h, dx:dx + w] for dy in range(3) for dx in range(3)])


def tone(v, g, b, gamma):
    x = np.clip(g * (np.asarray(v, np.float64) - b) / 255.0, 0.0, 1.0)
    y = np.where(x < roms.TOE, x * roms.TOE ** (gamma - 1.0), x ** gamma) if roms.TOE > 0 else x ** gamma
    return 255.0 * y


def tone_slope(v, g, b, gamma, d=2.0):
    return float((tone(v + d, g, b, gamma) - tone(v - d, g, b, gamma)) / (2 * d))


def temporal(cur, prev, sigma, a_min, cfg):
    sad = np.abs(windows(cur) - windows(prev)).mean(axis=0)
    r = sad / max(sigma, 0.5)
    f = np.clip((r - cfg.r0) / (cfg.r1 - cfg.r0), 0.0, 1.0)
    alpha = a_min + (1.0 - a_min) * f
    return prev + alpha * (cur - prev)


def spatial(x, sigma, lam, cfg):
    w = windows(x)
    c = w[4]
    sel = np.abs(w - c) <= cfg.k_sp * max(sigma, 0.5)
    cnt = sel.sum(axis=0)
    mean = (w * sel).sum(axis=0) / cnt
    return c + lam * (mean - c)


def unsharp(v, amount, core):
    blur = windows(v).mean(axis=0)
    d = v - blur
    dc = np.sign(d) * np.maximum(np.abs(d) - core, 0.0)
    return v + amount * dc


@dataclass
class State:
    ln_g: float
    sigma: float = -1.0
    b: float = 0.0
    prev: object = None


def frame_params(st, cfg, p50, sigma):
    """Strengths for the next frame from the controller state (the coupling formulas)."""
    g = float(np.exp(st.ln_g))
    slope = max(tone_slope(p50, g, st.b, cfg.gamma), 0.25)
    noise_out = sigma * slope
    if cfg.coupled:
        a_min = float(np.clip(cfg.sigma_t ** 2 / max(noise_out ** 2, EPS), cfg.a_floor, 1.0))
        lam = float(np.clip((noise_out / cfg.sigma_t - 1.0) / 2.0, 0.0, 1.0))
        sharp = cfg.s_max * float(np.clip(1.0 - noise_out / cfg.sigma_hi, 0.0, 1.0))
    else:
        a_min, lam, sharp = cfg.fixed_a_min, cfg.fixed_lam, cfg.fixed_sharp
    core = max(noise_out * np.sqrt(a_min / (2.0 - a_min)), 1.0)
    return dict(g=g, b=st.b, a_min=a_min, lam=lam, sharp=sharp, core=core, noise_out=noise_out)


def run_clip(frames, cfg=Cfg(), return_log=False):
    """frames (T,H,W) u8 -> outputs (T,H,W) u8 (+ per-frame log)."""
    frames = np.asarray(frames)
    t_n, h, w = frames.shape
    st = State(ln_g=float(np.log(cfg.g_init)))
    outs = np.empty_like(frames)
    log = []
    p = dict(g=cfg.g_init, b=0.0, a_min=cfg.fixed_a_min, lam=cfg.fixed_lam, sharp=cfg.fixed_sharp,
             core=1.0, noise_out=0.0)
    sigma = 3.0
    for t in range(t_n):
        cur = frames[t].astype(np.float64)
        # --- datapath for frame t uses parameters computed after frame t-1 ---
        x = cur
        if cfg.temporal and st.prev is not None:
            x = temporal(cur, st.prev, sigma, p["a_min"], cfg)
        st.prev = x
        if cfg.spatial:
            x = spatial(x, sigma, p["lam"], cfg)
        y = tone(x, p["g"], p["b"], cfg.gamma)
        m_out = float(y.mean())
        z = unsharp(y, p["sharp"], p["core"]) if cfg.sharpen else y
        outs[t] = np.clip(np.rint(z), 0, 255).astype(np.uint8)
        # --- statistics of frame t -> controller -> parameters for frame t+1 ---
        hist = stats.histogram(frames[t])
        p1, p50, p99 = stats.percentiles(hist)
        pcap = stats.percentile_from_hist(hist, cfg.cap_pct, 100)
        s_frame = stats.noise_sigma(frames[t])
        sigma = s_frame if st.sigma < 0 else st.sigma + cfg.sigma_iir * (s_frame - st.sigma)
        st.sigma = sigma
        st.b = float(min(p1, cfg.b_max, int(np.floor(sigma + 0.5)) if cfg.b_sigma else 99))   # black level never exceeds ~1 sigma of noise
        if cfg.feedback:
            e = np.log(cfg.target / max(m_out, 1.0))
            d = 0.0 if abs(e) < cfg.deadband else float(np.clip(cfg.k * e, -cfg.rl_dn, cfg.rl_up))
            g_cap = min(cfg.g_max, (cfg.head / 255.0) ** (1.0 / cfg.gamma) * 255.0 / max(pcap - st.b, 8.0))
            st.ln_g = float(np.clip(st.ln_g + d, np.log(cfg.g_min), np.log(max(g_cap, cfg.g_min))))
        p = frame_params(st, cfg, p50, sigma)
        log.append(dict(t=t, m_out=m_out, sigma=sigma, p1=p1, p50=p50, p99=p99, **p))
    return (outs, log) if return_log else outs


def enhance_image(img_u8, cfg=Cfg(), settle=12):
    """Single image: let the controller settle on repeated copies (temporal off: identical frames carry no new information)."""
    c = replace(cfg, temporal=False)
    clip = np.repeat(np.asarray(img_u8)[None], settle, axis=0)
    return run_clip(clip, c)[-1]
