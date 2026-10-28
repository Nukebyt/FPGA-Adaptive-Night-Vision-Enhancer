import numpy as np
import pytest

from model import baselines, lowlight_sim as sim, metrics, stats


# ---------- stats ----------

def test_hist_sums_to_pixels():
    img = np.random.default_rng(0).integers(0, 256, (48, 64), dtype=np.uint8)
    assert stats.histogram(img).sum() == img.size


def _brute_percentile(img, num, den):
    flat = np.sort(img.ravel())
    k = max(1, -(-flat.size * num // den))      # ceil
    return int(flat[k - 1])


@pytest.mark.parametrize("num,den", [(1, 100), (50, 100), (99, 100), (1, 1000), (999, 1000)])
def test_percentile_matches_bruteforce_definition(num, den):
    rng = np.random.default_rng(num * 7 + den)
    for _ in range(20):
        img = np.clip(rng.normal(rng.integers(10, 240), rng.integers(1, 60), (30, 40)), 0, 255).astype(np.uint8)
        assert stats.percentile_from_hist(stats.histogram(img), num, den) == _brute_percentile(img, num, den)


def test_percentile_constant_image():
    img = np.full((8, 8), 77, np.uint8)
    assert stats.percentiles(stats.histogram(img)) == (77, 77, 77)


def test_mean_from_hist_is_floor_of_mean():
    img = np.random.default_rng(3).integers(0, 256, (40, 40), dtype=np.uint8)
    assert stats.mean_from_hist(stats.histogram(img)) == int(img.astype(np.int64).sum() // img.size)


def test_noise_estimator_recovers_gaussian_sigma():
    rng = np.random.default_rng(5)
    for sigma in (2.0, 5.0, 10.0):
        img = np.clip(128 + rng.normal(0, sigma, (240, 320)), 0, 255)
        est = stats.noise_sigma(np.rint(img).astype(np.uint8))
        assert est == pytest.approx(sigma, rel=0.08)


def test_noise_estimator_ignores_smooth_gradient():
    ramp = np.tile(np.linspace(0, 255, 320).astype(np.uint8), (240, 1))
    assert stats.noise_sigma(ramp) < 1.0


# ---------- simulator ----------

def test_simulator_is_deterministic_and_seed_sensitive():
    gt = np.full((1, 32, 32), 180, np.uint8)
    a = sim.simulate_clip(gt, 0.05, seed=1)
    b = sim.simulate_clip(gt, 0.05, seed=1)
    c = sim.simulate_clip(gt, 0.05, seed=2)
    assert np.array_equal(a, b) and not np.array_equal(a, c)


def test_simulator_darkens_and_adds_noise():
    gt = np.full((4, 64, 64), 200, np.uint8)
    out = sim.simulate_clip(gt, 0.03, seed=0)
    assert out.mean() < 0.5 * gt.mean()
    assert out.std(axis=0, ddof=1).mean() > 0.5


def test_noise_is_signal_dependent_in_linear_domain():
    """Shot noise: variance of the *linear* signal grows with brightness."""
    rng = np.random.default_rng(0)
    p = sim.SensorParams(exposure=1.0, full_well=400.0, read_sigma=2.0)
    var = {}
    for level in (60, 120, 240):
        gt = np.full((128, 128), level, np.uint8)
        frames = np.stack([sim.simulate_frame(gt, p, rng) for _ in range(8)])
        lin = sim.to_linear(frames)
        var[level] = lin.var(axis=0, ddof=1).mean()
    assert var[60] < var[120] < var[240]


def test_duplicate_content_repeats_frames():
    gt = np.arange(3 * 4 * 4, dtype=np.uint8).reshape(3, 4, 4)
    d = sim.duplicate_content(gt, 2)
    assert d.shape[0] == 6 and np.array_equal(d[0], d[1]) and np.array_equal(d[2], d[3])
    noisy = sim.simulate_clip(np.full((2, 64, 64), 200, np.uint8), 0.05, seed=4)
    assert not np.array_equal(noisy[0], noisy[1])   # independent noise per output frame


def test_synth_clip_shapes_and_motion():
    gt, mask = sim.synth_clip(6, 120, 160, seed=1)
    assert gt.shape == (6, 120, 160) and mask.shape == gt.shape
    assert mask.any() and not np.array_equal(mask[0], mask[3])


@pytest.mark.parametrize("kind", ["steady", "step_up", "step_down", "pulse"])
def test_exposure_schedule_kinds(kind):
    e = sim.exposure_schedule(30, kind)
    assert e.shape == (30,)
    assert (e.min() == e.max()) == (kind == "steady")


# ---------- metrics ----------

def test_psnr_ssim_identity_and_ordering():
    img = np.random.default_rng(0).integers(0, 256, (64, 64), dtype=np.uint8)
    assert metrics.psnr(img, img) == float("inf")
    assert metrics.ssim(img, img) == pytest.approx(1.0)
    noisy = np.clip(img + np.random.default_rng(1).normal(0, 20, img.shape), 0, 255).astype(np.uint8)
    noisier = np.clip(img + np.random.default_rng(1).normal(0, 60, img.shape), 0, 255).astype(np.uint8)
    assert metrics.psnr(img, noisy) > metrics.psnr(img, noisier)
    assert metrics.ssim(img, noisy) > metrics.ssim(img, noisier)


def test_psnr_known_value():
    a = np.zeros((4, 4), np.uint8)
    b = np.full((4, 4), 10, np.uint8)       # mse 100
    assert metrics.psnr(a, b) == pytest.approx(10 * np.log10(255 ** 2 / 100))


def test_loe_zero_for_monotonic_map_and_positive_for_inversion():
    img = np.random.default_rng(0).integers(0, 256, (100, 100), dtype=np.uint8)
    assert metrics.loe(img, img) == 0.0
    assert metrics.loe(img, (img // 2 + 3).astype(np.uint8)) < 0.01   # near-monotonic remap
    assert metrics.loe(img, 255 - img) > 0.4


def test_static_noise_and_flicker():
    rng = np.random.default_rng(0)
    clip = np.clip(100 + rng.normal(0, 6, (40, 32, 32)), 0, 255)
    assert metrics.static_noise(clip, (0, 32, 0, 32)) == pytest.approx(6.0, rel=0.1)
    assert metrics.flicker(np.full((10, 8, 8), 90.0)) == 0.0
    alt = np.stack([np.full((8, 8), 90.0 + (5 if i % 2 else 0)) for i in range(10)])
    assert metrics.flicker(alt) == pytest.approx(5.0)


def test_ghost_error_ratio_detects_smear():
    gt, mask = sim.synth_clip(4, 96, 128, seed=2)
    baseline = gt.copy()
    smeared = gt.copy()
    smeared[mask] = 128                      # wrong values exactly on the moving object
    mo, mb, ratio = metrics.ghost_error(smeared, gt, mask, baseline)
    assert mb == 0.0 and ratio == float("inf") and mo > 0
    mo2, mb2, r2 = metrics.ghost_error(baseline + 1, gt, mask, baseline + 2)
    assert r2 < 1.0


# ---------- baselines ----------

def test_baselines_shapes_and_brighten_dark_input():
    gt, _ = sim.synth_clip(1, 120, 160, seed=3)
    dark = sim.simulate_clip(gt, 0.03, seed=0)[0]
    for fn in (baselines.gamma_correct, baselines.hist_eq, baselines.clahe):
        out = fn(dark)
        assert out.shape == dark.shape and out.dtype == np.uint8
        assert out.mean() > dark.mean()


# ---------- presets and still-based clips ----------

def test_presets_are_ordered_by_noise():
    gt = np.full((3, 96, 128), 150, np.uint8)
    s = {}
    for p in ("lol", "moderate", "harsh"):
        clip = sim.simulate_clip_preset(gt, p, seed=0)
        s[p] = stats.noise_sigma(clip[0])
    assert s["lol"] < s["moderate"] < s["harsh"]


def test_clip_from_still_static_background_and_exact_mask():
    rng = np.random.default_rng(1)
    still = rng.integers(0, 256, (200, 300), dtype=np.uint8)
    frames, masks = sim.clip_from_still(still, 8, seed=3, size=(160, 120), pan=(0, 0))
    assert frames.shape == (8, 120, 160) and masks.shape == frames.shape
    assert masks.any(axis=(1, 2)).all()
    assert not np.array_equal(masks[0], masks[4])                  # the object moves
    outside = ~(masks[0] | masks[4])
    assert np.array_equal(frames[0][outside], frames[4][outside])  # static background is identical


def test_clip_from_still_pan_moves_background():
    rng = np.random.default_rng(2)
    still = rng.integers(0, 256, (200, 300), dtype=np.uint8)
    frames, masks = sim.clip_from_still(still, 6, seed=3, size=(160, 120), pan=(2, 0))
    outside = ~(masks[0] | masks[3])
    assert not np.array_equal(frames[0][outside], frames[3][outside])
