"""Second, independently written golden model (roadmap task 2.11): scalar per-pixel loops, plain Python ints.

Written from the specification in model/pipeline_int.py's header and in model/enh.py's docstring, NOT by
transcribing the vectorised code: no numpy in the datapath, every pixel computed one at a time, every window
tap fetched through a bounds-clamping accessor. Slow (use small frames in tests). It shares only the ROM
tables (model/roms.py) and the statistics helpers' *definitions*, which are re-implemented here.
"""
import math

from . import roms

# constants re-stated here on purpose (see pipeline_int.py for their meaning)
TARGET, B_MAX = 128, 16
RL_UP, RL_DN, DEAD = 1182, 2364, 295
LG_INIT, LG_MAX = 2 << 12, 6 << 12


def clamp(v, lo, hi):
    return lo if v < lo else hi if v > hi else v


def rhu_div(a, b):
    return (a + b // 2) // b


class RefPipeline:
    def __init__(self, width, height, F=2):
        self.W, self.H, self.F = width, height, F
        self.c_sig = int(round((1 << 24) * 256 * math.sqrt(math.pi / 2.0) / (6.0 * (width - 2) * (height - 2))))
        self.prev = None
        self.passthru = False
        self.lg = LG_INIT
        self.sigma = 3 * 256
        self.b = 0
        self.lam, self.sharp, self.core, self.a = 8, 8, 16, 64
        self.frames_done = 0
        self.lut = self.build_lut()

    # ---- helpers
    @staticmethod
    def at(img, y, x, h, w):
        return img[clamp(y, 0, h - 1)][clamp(x, 0, w - 1)]

    def build_lut(self):
        F = self.F
        if self.passthru:
            return [i >> F for i in range(256 << F)]
        g_q12 = roms.exp2_q12(self.lg)
        gl = rhu_div(g_q12 * 1023, 1020)
        out = []
        for i in range(256 << F):
            d = i - (self.b << F)
            if d <= 0:
                idx = 0
            else:
                idx = clamp(((d * gl) + (1 << (9 + F))) >> (10 + F), 0, 1023)
            out.append(roms.GAMMA_ROM[idx])
        return out

    # ---- one frame
    def step(self, frame):
        H, W, F = self.H, self.W, self.F
        sig = max(self.sigma, 128)
        cur = [[frame[y][x] << F for x in range(W)] for y in range(H)]
        # temporal
        if self.prev is None:
            tmp = [row[:] for row in cur]
        else:
            k_mot = rhu_div(1 << (28 - F), 9 * sig)
            tmp = [[0] * W for _ in range(H)]
            for y in range(H):
                for x in range(W):
                    sad = 0
                    for dy in (-1, 0, 1):
                        for dx in (-1, 0, 1):
                            sad += abs(self.at(cur, y + dy, x + dx, H, W) - self.at(self.prev, y + dy, x + dx, H, W))
                    u = min(63, (sad * k_mot) >> 16)
                    f = roms.MOTION_F[u]
                    alpha = self.a + (((256 - self.a) * f + 128) >> 8)
                    p = self.prev[y][x]
                    tmp[y][x] = p + ((alpha * (cur[y][x] - p) + 128) >> 8)
        self.prev = tmp
        # spatial sigma filter
        thr = ((sig * 5 * (1 << F)) + 256) >> 9
        sp = [[0] * W for _ in range(H)]
        for y in range(H):
            for x in range(W):
                c = tmp[y][x]
                n, s = 0, 0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        q = self.at(tmp, y + dy, x + dx, H, W)
                        if abs(q - c) <= thr:
                            n += 1
                            s += q
                mean = (s * roms.RECIP[n] + 32768) >> 16
                sp[y][x] = c + ((self.lam * (mean - c) + 8) >> 4)
        # tone map
        v = [[self.lut[clamp(sp[y][x], 0, (256 << F) - 1)] for x in range(W)] for y in range(H)]
        out_sum = sum(sum(r) for r in v)
        # unsharp
        out = [[0] * W for _ in range(H)]
        for y in range(H):
            for x in range(W):
                tot = 0
                for dy in (-1, 0, 1):
                    for dx in (-1, 0, 1):
                        tot += self.at(v, y + dy, x + dx, H, W)
                blur_q4 = (tot * 1820 + 512) >> 10
                d = v[y][x] * 16 - blur_q4
                mag = max(abs(d) - self.core, 0)
                dc = mag if d > 0 else -mag
                out[y][x] = clamp(v[y][x] + ((self.sharp * dc + 128) >> 8), 0, 255)
        self.stats_and_control(frame, out_sum)
        return out

    # ---- statistics and controller
    def stats_and_control(self, frame, out_sum):
        H, W = self.H, self.W
        hist = [0] * 256
        for row in frame:
            for p in row:
                hist[p] += 1
        acc = 0
        for y in range(1, H - 1):
            for x in range(1, W - 1):
                a = lambda dy, dx: frame[y + dy][x + dx]  # noqa: E731
                r = (a(-1, -1) + a(-1, 1) + a(1, -1) + a(1, 1)
                     - 2 * (a(-1, 0) + a(1, 0) + a(0, -1) + a(0, 1)) + 4 * a(0, 0))
                acc += abs(r)
        self.control(hist, acc, out_sum)

    def control(self, hist, acc, out_sum):
        H, W = self.H, self.W
        n = H * W

        def pct(num, den):
            need = max(1, -(-n * num // den))
            run = 0
            for k in range(256):
                run += hist[k]
                if run >= need:
                    return k
            return 255

        p1, p50, p99 = pct(1, 100), pct(50, 100), pct(99, 100)
        pcap = pct(95, 100)
        s_frame = (acc * self.c_sig + (1 << 23)) >> 24
        self.sigma = s_frame if self.frames_done == 0 else self.sigma + ((s_frame - self.sigma) >> 2)
        self.b = min(p1, B_MAX, (self.sigma + 128) >> 8)
        mean_q4 = rhu_div(out_sum * 16, n)
        e = roms.log2_q12(TARGET * 16) - roms.log2_q12(mean_q4)
        if abs(e) < DEAD:
            step = 0
        else:
            step = clamp(e >> 1, -RL_DN, RL_UP)
        cap = roms.log2_q12(255) - roms.log2_q12(max(pcap - self.b, 8))
        self.lg = clamp(self.lg + step, 0, clamp(cap, 0, LG_MAX))
        self.lut = self.build_lut()
        i0 = p50 << self.F
        hi_i, lo_i = i0 + (2 << self.F), i0 - (2 << self.F)
        top = len(self.lut) - 1
        l_hi = self.lut[min(hi_i, top)] if hi_i >= 0 else 0
        l_lo = self.lut[min(lo_i, top)] if lo_i >= 0 else 0
        nq = max((self.sigma * max(l_hi - l_lo, 1)) >> 2, 1)
        self.a = clamp(rhu_div(147456 * 256, nq * nq), 32, 256)
        self.lam = clamp((nq + 24) // 48 - 8, 0, 16)
        self.sharp = 0 if nq >= 3072 else clamp(((3072 - nq) * 16 + 1536) // 3072, 0, 16)
        ratio = (self.a << 16) // (512 - self.a)
        self.core = max((nq * math.isqrt(ratio) + 2048) >> 12, 16)
        self.frames_done += 1
