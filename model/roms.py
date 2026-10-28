"""Constant ROM tables shared by the bit-accurate models and (later) exported as .hex for the RTL.

Generated with float math once, at import, with explicit round-half-up: deterministic. Sanity bounds
are asserted in model/tests/test_pipeline_models.py. Export with scripts/export_roms.py (Phase 4).

  GAMMA_ROM[k]  k=0..1023   round(255*(x**0.4 for x>=0.05, else x*0.05**-0.6)), x=k/1023   tone curve with linear toe
  LOG2_ROM[j]   j=0..255    round(4096*log2(1 + j/256))               mantissa part of log2, Q12
  EXP2_ROM[j]   j=0..255    round(65536*2**(j/256))                   mantissa part of 2**x, Q16
  RECIP[n]      n=1..9      round(65536/n)                            spatial-filter mean divider
  MOTION_F[u]   u=0..63     clip(round(256*(u - 24)/39), 0, 256)      motion index -> blend factor, Q8 (u=63 -> 1.0 exactly)
"""
import math

GAMMA = 0.4
TOE = 0.0       # optional linear toe below this normalised input (tangent through the origin, caps the dark-end slope).
                # Evaluated at 0.05: costs 0.7 dB PSNR on LOL tuning, benefit on real footage not shown -> disabled (0 = pure gamma).


def _rhu(x):
    return int(math.floor(x + 0.5))


GAMMA_ROM = [_rhu(255.0 * ((k / 1023.0) * TOE ** (GAMMA - 1.0) if (TOE > 0 and k / 1023.0 < TOE) else (k / 1023.0) ** GAMMA)) for k in range(1024)]
LOG2_ROM = [_rhu(4096.0 * math.log2(1.0 + j / 256.0)) for j in range(256)]
EXP2_ROM = [_rhu(65536.0 * 2.0 ** (j / 256.0)) for j in range(256)]
RECIP = [0] + [_rhu(65536.0 / n) for n in range(1, 10)]
MOTION_F = [min(256, max(0, _rhu(256.0 * (u - 24) / 39.0))) for u in range(64)]   # r = u/16: 1.5 .. 3.9375


def log2_q12(x):
    """log2 of a positive integer, Q12 (x<1 treated as 1). Leading-one position + 8-bit mantissa ROM."""
    x = max(int(x), 1)
    ip = x.bit_length() - 1
    mant = ((x << (8 - ip)) if ip < 8 else (x >> (ip - 8))) & 255
    return ip * 4096 + LOG2_ROM[mant]


def exp2_q12(lg):
    """2**(lg/4096) * 4096 as an integer (G in Q12) for lg >= 0 in Q12."""
    ip = lg >> 12
    j = (lg & 4095) >> 4
    return (EXP2_ROM[j] << ip) >> 4
