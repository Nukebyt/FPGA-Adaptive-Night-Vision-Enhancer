"""Bit-accurate integer model of the whole pipeline (roadmap task 2.11): the RTL golden reference #1.

Vectorised numpy, int32/int64 arithmetic only inside the datapath and the controller. The second,
independently written model (model/pipeline_ref.py, scalar loops) must agree with this one bit for bit.
Floating point appears only in the ROM generators (model/roms.py) and in the constants derived from
the frame size at construction time; both are fixed numbers in the RTL.

Q formats (every port comment in the RTL copies this table)
    raw pixel               Q8.0  u8
    frame store / spatial   Q(8.F) u(8+F)   F = 2 by default (value*2^F)
    tone LUT                (256<<F) entries x u8, index = Q(8.F) value
    sigma (noise std)       Q8 (x256), raw grey levels
    log2 G                  Q12 (x4096); G = 2**(lg/4096), G_q12 = G*4096
    alpha / a_min / f       Q8 (256 = 1.0)       lam, sharp: Q4 (16 = 1.0)       core: Q4 output levels
    division convention     round half up: (a + b//2)//b for a>=0; arithmetic shift = floor for signed values
Window operations use replicate borders. Raster order, 3x3 centre at index 4.

Per-frame timeline (matches Architecture decision 3):
    1. datapath for frame t runs with parameters P(t) (computed after frame t-1)
    2. statistics of frame t are accumulated during active video: input histogram, noise sum,
       sum of tone-mapped output (before sharpening)
    3. in vertical blanking the controller turns them into P(t+1) and regenerates the tone LUT
"""
import math

import numpy as np

from . import roms, stats

# ---- policy constants (the integer image of enh.Cfg defaults) ----
TARGET = 128
K_SHIFT = 1                         # k = 0.5
RL_UP_Q12 = 1182                    # 0.20 ln  = 0.2885 log2
RL_DN_Q12 = 2364                    # 0.40 ln
DEADBAND_Q12 = 295                  # 0.05 ln
LG_MIN, LG_MAX = 0, 6 << 12         # G in [1, 64]
LG_INIT = 2 << 12                   # G = 4
B_MAX = 16
CAP_PCT = 95                        # highlight headroom percentile
SIGMA_T2_Q16 = 147456               # sigma_t = 1.5 output levels: 1.5^2 * 65536
A_FLOOR_Q8 = 32                     # 1/8 (retuned, docs/results/retune.md)
SIGMA_INIT_Q8 = 3 * 256
SIGMA_IIR_SHIFT = 2                 # 0.25
LAM_INIT_Q4, SHARP_INIT_Q4, CORE_INIT_Q4 = 8, 8, 16


def rdiv(a, b):
    """Round-half-up integer division, a >= 0, b > 0 (RTL: restoring divider)."""
    return (a + (b >> 1)) // b


class IntPipeline:
    def __init__(self, width=640, height=480, F=2):
        self.W, self.H, self.F = width, height, F
        self.n_pix = width * height
        # sigma from the integer noise sum: sigma_q8 = (S * C_SIG + 2^23) >> 24
        self.c_sig = int(round((1 << 24) * 256 * math.sqrt(math.pi / 2.0) / (6.0 * (width - 2) * (height - 2))))
        self.passthru = False                  # set before a frame: the LUT generated after it is the identity
        self.prev = None                       # frame store, Q(8.F), int32 array
        self.lg = LG_INIT
        self.sigma_q8 = SIGMA_INIT_Q8
        self.b = 0
        self.lam_q4, self.sharp_q4, self.core_q4 = LAM_INIT_Q4, SHARP_INIT_Q4, CORE_INIT_Q4
        self.a_q8 = 64
        self.lut = self.make_lut(self.lg, self.b)
        self.log = []

    # ------------------------------------------------------------------ tone LUT
    def make_lut(self, lg, b):
        F = self.F
        if self.passthru:                                    # identity table: v = i >> F (exact passthrough with a = 1, lam = 0, sharp = 0)
            return (np.arange(256 << F, dtype=np.int32) >> F).astype(np.int32)
        g_q12 = roms.exp2_q12(lg)
        gl = rdiv(g_q12 * 1023, 1020)
        i = np.arange(256 << F, dtype=np.int64)
        d = i - (b << F)
        # idx = (v - B) * G * 1023 / 255 with v = i / 2^F  ==  d * gl / 2^(10+F), round half up
        idx = np.where(d > 0, (d * gl + (1 << (9 + F))) >> (10 + F), 0)
        idx = np.clip(idx, 0, 1023)
        return np.array(roms.GAMMA_ROM, dtype=np.int32)[idx]

    def lut_at(self, i):
        if i < 0:
            return 0
        return int(self.lut[min(i, (256 << self.F) - 1)])

    # ------------------------------------------------------------------ window helper
    @staticmethod
    def win9(img):
        p = np.pad(img, 1, mode="edge")
        h, w = img.shape
        return np.stack([p[dy:dy + h, dx:dx + w] for dy in range(3) for dx in range(3)]).astype(np.int64)

    # ------------------------------------------------------------------ datapath
    def step(self, frame_u8):
        F = self.F
        raw = np.asarray(frame_u8, dtype=np.int32)
        c = raw << F
        had_prev = self.prev is not None
        self.used = dict(lg=self.lg, sigma_q8=self.sigma_q8, b=self.b, a_q8=self.a_q8, lam_q4=self.lam_q4,
                         sharp_q4=self.sharp_q4, core_q4=self.core_q4, lut=self.lut.copy())
        sig_eff = max(self.sigma_q8, 128)
        # --- temporal (frame store, raw domain)
        if self.prev is None:
            p_new = c.astype(np.int64)
        else:
            sad9 = np.abs(self.win9(c) - self.win9(self.prev)).sum(axis=0)
            k_mot = rdiv(1 << (28 - F), 9 * sig_eff)
            u = np.minimum(63, (sad9 * k_mot) >> 16)
            f_q8 = np.array(roms.MOTION_F, dtype=np.int64)[u]
            alpha = self.a_q8 + (((256 - self.a_q8) * f_q8 + 128) >> 8)
            diff = c.astype(np.int64) - self.prev
            p_new = self.prev + ((alpha * diff + 128) >> 8)
        self.prev = p_new.astype(np.int32)
        # --- spatial sigma filter
        w = self.win9(self.prev)
        cen = w[4]
        thr = ((sig_eff * 5 << F) + 256) >> 9
        sel = np.abs(w - cen) <= thr
        cnt = sel.sum(axis=0)
        ssum = (w * sel).sum(axis=0)
        recip = np.array(roms.RECIP, dtype=np.int64)[cnt]
        mean = (ssum * recip + 32768) >> 16
        sp = cen + ((self.lam_q4 * (mean - cen) + 8) >> 4)
        # --- tone map
        v = self.lut[np.clip(sp, 0, (256 << F) - 1)].astype(np.int64)
        out_sum = int(v.sum())
        # --- unsharp
        s9 = self.win9(v.astype(np.int32)).sum(axis=0)
        blur_q4 = (s9 * 1820 + 512) >> 10
        d = (v << 4) - blur_q4
        dc = np.sign(d) * np.maximum(np.abs(d) - self.core_q4, 0)
        out = np.clip(v + ((self.sharp_q4 * dc + 128) >> 8), 0, 255).astype(np.uint8)
        # --- statistics + controller for the next frame
        self.dbg = dict(p_new=self.prev.copy(), sp=sp.astype(np.int32), v=v.astype(np.int32), out=out.copy(),
                        out_sum=out_sum, had_prev=had_prev)
        self.update(raw.astype(np.uint8), out_sum)
        self.dbg["noise_sum"] = self.last_noise_sum
        return out

    # ------------------------------------------------------------------ controller (blanking time)
    def update(self, raw_u8, out_sum):
        self.update_stats(stats.histogram(raw_u8), stats.noise_sum(raw_u8), out_sum)

    def update_stats(self, hist, noise_sum, out_sum):
        """Controller update from the frame statistics only (what nv_ctrl receives): histogram, noise sum, output sum."""
        p1, p50, p99 = stats.percentiles(hist)
        pcap = stats.percentile_from_hist(hist, CAP_PCT, 100)
        self.last_noise_sum = noise_sum
        s_frame = (noise_sum * self.c_sig + (1 << 23)) >> 24
        self.sigma_q8 = s_frame if not self.log else self.sigma_q8 + ((s_frame - self.sigma_q8) >> SIGMA_IIR_SHIFT)
        self.b = min(p1, B_MAX, (self.sigma_q8 + 128) >> 8)       # black level <= ~1 sigma of noise
        mean_q4 = rdiv(out_sum * 16, self.n_pix)
        e = roms.log2_q12(TARGET * 16) - roms.log2_q12(mean_q4)
        if abs(e) < DEADBAND_Q12:
            dlg = 0
        else:
            dlg = min(max(e >> K_SHIFT, -RL_DN_Q12), RL_UP_Q12)
        cap = roms.log2_q12(255) - roms.log2_q12(max(pcap - self.b, 8))
        hi = max(min(cap, LG_MAX), LG_MIN)
        self.lg = min(max(self.lg + dlg, LG_MIN), hi)
        self.lut = self.make_lut(self.lg, self.b)
        # coupling
        i0 = p50 << self.F
        diff = self.lut_at(i0 + (2 << self.F)) - self.lut_at(i0 - (2 << self.F))
        nq = max((self.sigma_q8 * max(diff, 1)) >> 2, 1)          # noise at the output, Q8 levels
        n2 = nq * nq
        self.a_q8 = min(max(rdiv(SIGMA_T2_Q16 * 256, n2), A_FLOOR_Q8), 256)
        self.lam_q4 = min(max((nq + 24) // 48 - 8, 0), 16)      # 16*clip((n/1.5 - 1)/2) with n = nq/256
        self.sharp_q4 = min(max(((3072 - nq) * 16 + 1536) // 3072, 0), 16) if nq < 3072 else 0
        r_q16 = (self.a_q8 << 16) // (512 - self.a_q8)
        s_q8 = math.isqrt(r_q16)
        self.core_q4 = max((nq * s_q8 + 2048) >> 12, 16)
        self.log.append(dict(p1=p1, p50=p50, p99=p99, sigma_q8=self.sigma_q8, mean_q4=mean_q4, lg=self.lg,
                             b=self.b, a_q8=self.a_q8, lam_q4=self.lam_q4, sharp_q4=self.sharp_q4,
                             core_q4=self.core_q4, nq=nq))


def run_clip_int(frames, F=2):
    frames = np.asarray(frames)
    t, h, w = frames.shape
    pipe = IntPipeline(w, h, F)
    return np.stack([pipe.step(f) for f in frames]), pipe
