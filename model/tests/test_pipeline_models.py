"""The two golden models must agree bit for bit; ROMs and the integer model must track the float design model."""
import numpy as np
import pytest

from model import enh, lowlight_sim as sim, pipeline_int, pipeline_ref, roms, metrics


def random_clip(t, h, w, seed, lo=0, hi=60):
    return np.random.default_rng(seed).integers(lo, hi, (t, h, w), dtype=np.uint8)


def natural_clip(t, h, w, seed, preset="moderate", exposure=0.01):
    still = np.random.default_rng(seed).integers(0, 256, (90, 120), dtype=np.uint8)
    import cv2
    still = cv2.GaussianBlur(still, (0, 0), 3)
    gt, _ = sim.clip_from_still(still, t, seed=seed, size=(w, h), obj=min(24, h // 2))
    return sim.simulate_clip_preset(gt, preset, exposure=exposure, seed=seed)


def both(frames, F=2):
    t, h, w = frames.shape
    a = pipeline_int.IntPipeline(w, h, F)
    b = pipeline_ref.RefPipeline(w, h, F)
    for i in range(t):
        oa = a.step(frames[i])
        ob = np.array(b.step(frames[i].tolist()), dtype=np.uint8)
        assert np.array_equal(oa, ob), "output mismatch frame %d (%d px)" % (i, int((oa != ob).sum()))
        for name, va, vb in (("lg", a.lg, b.lg), ("sigma", a.sigma_q8, b.sigma), ("b", a.b, b.b), ("a", a.a_q8, b.a),
                             ("lam", a.lam_q4, b.lam), ("sharp", a.sharp_q4, b.sharp), ("core", a.core_q4, b.core)):
            assert va == vb, "state mismatch %s frame %d: %s vs %s" % (name, i, va, vb)
        assert list(a.lut) == b.lut, "LUT mismatch frame %d" % i
    return a


@pytest.mark.parametrize("seed", [1, 2])
def test_models_agree_on_random_noise(seed):
    both(random_clip(5, 24, 32, seed))


def test_models_agree_on_natural_video_with_motion():
    both(natural_clip(7, 36, 48, 3))


@pytest.mark.parametrize("F", [0, 1, 3])
def test_models_agree_for_other_fraction_widths(F):
    both(natural_clip(4, 24, 32, 5), F=F)


def test_models_agree_through_exposure_step_and_saturation():
    gt = np.full((8, 24, 32), 200, np.uint8)
    gt[:, 8:16, 8:24] = 255
    exp = np.array([0.008] * 3 + [0.05] * 3 + [0.008] * 2)
    both(sim.simulate_clip(gt, exp, seed=4, full_well=2000.0, read_sigma=2.0))


def test_models_agree_on_extremes():
    both(np.zeros((3, 16, 16), np.uint8))
    both(np.full((3, 16, 16), 255, np.uint8))


def test_comparison_actually_detects_a_difference():
    """Harness check: a one-count perturbation of the reference must be reported."""
    frames = random_clip(2, 16, 16, 9)
    t, h, w = frames.shape
    a = pipeline_int.IntPipeline(w, h)
    b = pipeline_ref.RefPipeline(w, h)
    b.lam = 9                                   # deliberately different from the int model's initial 8
    oa = a.step(frames[0])
    ob = np.array(b.step(frames[0].tolist()), dtype=np.uint8)
    assert not np.array_equal(oa, ob)


# ---------------- ROMs ----------------

def test_rom_ranges_and_accuracy():
    assert len(roms.GAMMA_ROM) == 1024 and roms.GAMMA_ROM[0] == 0 and roms.GAMMA_ROM[1023] == 255
    assert all(a <= b for a, b in zip(roms.GAMMA_ROM, roms.GAMMA_ROM[1:]))
    for x in (1, 2, 3, 7, 100, 255, 1000, 4000, 70000):
        assert roms.log2_q12(x) == pytest.approx(4096 * np.log2(x), abs=12)
    for lg in (0, 4096, 8191, 3 << 12, 5 << 12 | 1234):
        assert roms.exp2_q12(lg) == pytest.approx(4096 * 2 ** (lg / 4096), rel=0.003)
    assert roms.MOTION_F[0] == 0 and roms.MOTION_F[63] == 256 and roms.MOTION_F[24] == 0 and roms.MOTION_F[63] == 256 and roms.MOTION_F[44] in range(130, 135)


# ---------------- integer model vs float design model ----------------

def test_integer_model_tracks_float_model_quality():
    clip = natural_clip(10, 120, 160, 6, preset="moderate", exposure=0.01)
    out_i, _ = pipeline_int.run_clip_int(clip)
    out_f = enh.run_clip(clip)
    # the two should agree closely in the converged state (policy identical, only rounding differs)
    assert metrics.psnr(out_i[-1], out_f[-1]) > 30
    assert abs(float(out_i[-1].mean()) - float(out_f[-1].mean())) < 4


def test_exported_rom_files_match_the_model():
    """The .hex files the RTL will load must be exactly the tables the golden models use."""
    import os
    root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
    for name, table in (("gamma_rom.hex", roms.GAMMA_ROM), ("log2_rom.hex", roms.LOG2_ROM),
                        ("exp2_rom.hex", roms.EXP2_ROM), ("recip_rom.hex", roms.RECIP), ("motion_rom.hex", roms.MOTION_F)):
        words = [int(l, 16) for l in open(os.path.join(root, "rtl", "rom", name)).read().splitlines() if l and not l.startswith("//")]
        assert words == list(table), name
