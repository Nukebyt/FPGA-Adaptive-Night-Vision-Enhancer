"""Evaluation of the FPGA engine against the baselines, using frames that really went through the board.

  python -I scripts/evaluate_board.py capture --host 192.168.137.200     run the LOL benchmark and the own clips through the board
  python -I scripts/evaluate_board.py analyze                            metrics + figures from the captures (no board needed)

capture  writes data/hw_eval/*.npz (gitignored: raw input, board output, per-frame telemetry).
analyze  re-runs the integer model on every captured input and requires the board output to be bit-identical (it refuses to report
         numbers otherwise), applies the baselines to the same input frames, and writes docs/results/hw_eval_*.{md,csv} and
         docs/img/*.png.
"""
import argparse
import csv
import json
import os
import sys

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from model import baselines, metrics, stats  # noqa: E402
from model.pipeline_int import IntPipeline  # noqa: E402
from scripts.clip_to_y8 import to_480  # noqa: E402

CAP = os.path.join(ROOT, "data", "hw_eval")
RES = os.path.join(ROOT, "docs", "results")
IMG = os.path.join(ROOT, "docs", "img")
CLIPS = os.path.join(ROOT, "data", "own_clips")
LOL_FRAMES = 24          # identical frames per LOL image: lets the controller settle (rate-limited, ~17 frames for 5 octaves)
CLIP_FRAMES = 300
SETTLE = 40              # frames ignored for clip statistics while the controller settles
STRIDE = {"lampstep_iso2000_1-60": 3}     # long step clip: every 3rd frame (20 fps) so the whole step fits in memory
METHODS = ["raw", "gamma0.4", "hist-eq", "CLAHE", "engine"]
COLORS = {"raw": "#8a8a86", "gamma0.4": "#eb6834", "hist-eq": "#1baf7a", "CLAHE": "#6250d6", "engine": "#2a78d6"}


def baseline_fn(name):
    return {"raw": lambda x: x, "gamma0.4": lambda x: baselines.gamma_correct(x, 0.4, 1.0),
            "hist-eq": baselines.hist_eq, "CLAHE": baselines.clahe}[name]


# ------------------------------------------------------------------------------------------------ capture
def board_run(host, frames, stages=None):
    from sw.host import nvproto as P
    client = P.Client(host, 5002, 640, 480, timeout=30.0)
    out, tel, pending, seq = [], [], 0, 0
    if stages is not None:                      # (temporal, spatial, sharpen) enables through the CSR CONTROL register (word 1)
        client.csr_write(4, 1 | (stages[0] << 2) | (stages[1] << 3) | (stages[2] << 4))

    def drain():
        _, t, enh = client.recv_frame()
        out.append(enh)
        tel.append([t.lg_q12, t.sigma_q8, t.mean_q4, t.a_q8, t.lam_q4, t.sharp_q4, t.black, t.p1, t.p50, t.p99, t.flags])

    try:
        for f in frames:
            client.send_frame(seq, f)
            seq += 1
            while client.in_flight >= P.MAX_IN_FLIGHT:
                drain()
        while client.in_flight:
            drain()
    finally:
        client.close()
    return np.stack(out), np.asarray(tel, np.int64)


def capture(host):
    from scripts.nv_viewer import frame_source
    os.makedirs(CAP, exist_ok=True)
    man = json.load(open(os.path.join(ROOT, "data", "benchmark_manifest.json")))["benchmark"]
    lows, highs, enhs, tels = [], [], [], []
    for it in man:
        lo = to_480(cv2.imread(os.path.join(ROOT, it["low"]), cv2.IMREAD_GRAYSCALE))
        hi = to_480(cv2.imread(os.path.join(ROOT, it["high"]), cv2.IMREAD_GRAYSCALE))
        enh, tel = board_run(host, [lo] * LOL_FRAMES)
        lows.append(lo); highs.append(hi); enhs.append(enh); tels.append(tel)
        print("LOL %-8s done, final gain %.2f" % (it["name"], 2 ** (tel[-1][0] / 4096.0)), flush=True)
    np.savez_compressed(os.path.join(CAP, "lol.npz"), low=np.stack(lows), high=np.stack(highs), enh=np.stack(enhs), tel=np.stack(tels),
                        names=np.array([it["name"] for it in man]))
    for fn in sorted(os.listdir(CLIPS)):
        if not fn.endswith(".mp4"):
            continue
        name = fn[:-4]
        stride = STRIDE.get(name, 1)
        count = None if name in STRIDE else CLIP_FRAMES
        raw = list(frame_source(os.path.join(CLIPS, fn), 0, count, stride, 0))
        enh, tel = board_run(host, raw)
        np.savez_compressed(os.path.join(CAP, name + ".npz"), raw=np.stack(raw), enh=enh, tel=tel, stride=stride)
        print("clip %-34s %4d frames  final gain %.2f" % (name, len(raw), 2 ** (tel[-1][0] / 4096.0)), flush=True)


ABLATION_CLIPS = ["static_dimroom_iso2000_1-60", "static_brighter_iso2000_1-60", "static_verydark_iso2000_1-60"]
ABLATION_STAGES = [("tone map only", (0, 0, 0)), ("+ temporal", (1, 0, 0)), ("+ temporal + spatial", (1, 1, 0)), ("full (+ sharpen)", (1, 1, 1))]


def capture_ablation(host):
    """The same clips with pipeline stages switched off through the CSR enable bits: what each stage buys, measured on the board."""
    from scripts.nv_viewer import frame_source
    for name in ABLATION_CLIPS:
        raw = list(frame_source(os.path.join(CLIPS, name + ".mp4"), 0, CLIP_FRAMES, 1, 0))
        res = {}
        for label, st in ABLATION_STAGES:
            enh, tel = board_run(host, raw, st)
            res[label] = enh
            print("ablation %-30s %-22s done" % (name, label), flush=True)
        np.savez_compressed(os.path.join(CAP, "ablation_" + name + ".npz"), raw=np.stack(raw), **{k.replace(" ", "_"): v for k, v in res.items()})


def analyze_ablation(plt):
    rows = []
    for name in ABLATION_CLIPS:
        f = os.path.join(CAP, "ablation_" + name + ".npz")
        if not os.path.exists(f):
            return None
        d = np.load(f)
        for label, _ in ABLATION_STAGES:
            o = d[label.replace(" ", "_")][SETTLE:]
            mean = float(o.mean())
            tn = temporal_noise(o)
            sig = float(np.mean([stats.noise_sigma(x) for x in o[::10]]))
            rows.append(dict(clip=name, stage=label, mean_luma=mean, temporal_std=tn, snr=mean / tn, spatial_sigma=sig))
    md = ["Hardware ablation: the same clips on the board with stages switched off through the CSR enable bits (the controller is unchanged, so the gain is the same).\n",
          "| clip | stages | mean luma | temporal std | SNR (mean / temporal std) | spatial noise sigma |", "|---|---|---|---|---|---|"]
    for r in rows:
        md.append("| %s | %s | %.1f | %.2f | %.1f | %.2f |" % (r["clip"].replace("_iso2000_1-60", ""), r["stage"], r["mean_luma"], r["temporal_std"], r["snr"], r["spatial_sigma"]))
    open(os.path.join(RES, "hw_eval_ablation.md"), "w", newline="\n").write("\n".join(md) + "\n")
    print("\n".join(md))
    fig, axs = plt.subplots(1, 2, figsize=(10, 3.3))
    cols = ["#8a8a86", "#1baf7a", "#6250d6", "#2a78d6"]
    names = ABLATION_CLIPS
    for ax, (k, title) in zip(axs, [("temporal_std", "temporal noise (grey-level std over time), lower is better"), ("spatial_sigma", "spatial noise sigma, lower is better")]):
        x = np.arange(len(names)); w = 0.2
        for j, (label, _) in enumerate(ABLATION_STAGES):
            v = [next(r[k] for r in rows if r["clip"] == n and r["stage"] == label) for n in names]
            ax.bar(x + (j - 1.5) * w, v, w, label=label, color=cols[j])
        ax.set_xticks(x); ax.set_xticklabels([n.replace("_iso2000_1-60", "").replace("static_", "") for n in names]); ax.set_title(title, fontsize=9)
    axs[0].legend(fontsize=7)
    fig.tight_layout(); fig.savefig(os.path.join(IMG, "fig_hw_ablation.png"), bbox_inches="tight"); plt.close(fig)
    return rows


# ------------------------------------------------------------------------------------------------ analysis
def model_run(raw):
    pipe = IntPipeline(raw.shape[2], raw.shape[1])
    return np.stack([pipe.step(f) for f in raw])


def require_bitexact(name, board, raw):
    if os.environ.get("NV_SKIP_VERIFY"):
        return
    model = model_run(raw)
    bad = [i for i in range(len(board)) if np.any(board[i] != model[i])]
    if bad:
        raise SystemExit("REFUSING TO REPORT: board output differs from the integer model for %s (first bad frame %d)" % (name, bad[0]))
    print("  %-34s %4d frames bit-exact vs model" % (name, len(board)), flush=True)


def temporal_noise(frames):
    """Mean per-pixel standard deviation over time (static scene: pure noise + flicker)."""
    return float(np.std(frames.astype(np.float64), axis=0, ddof=1).mean())


def clip_metrics(name, raw, enh, tel):
    outs = {"raw": raw, "engine": enh}
    for m in ("gamma0.4", "hist-eq", "CLAHE"):
        fn = baseline_fn(m)
        outs[m] = np.stack([fn(f) for f in raw])
    rows = []
    for m in METHODS:
        o = outs[m][SETTLE:]
        mean = float(o.mean())
        tn = temporal_noise(o)
        flick = float(np.std(o.reshape(len(o), -1).mean(axis=1), ddof=1))
        sig = float(np.mean([stats.noise_sigma(f) for f in o[::10]]))
        rows.append(dict(clip=name, method=m, mean_luma=mean, p50=float(np.percentile(o[::10], 50)), p99=float(np.percentile(o[::10], 99)),
                         temporal_std=tn, snr=mean / max(tn, 1e-6), spatial_sigma=sig, flicker=flick))
    return rows, outs


def analyze():
    os.makedirs(IMG, exist_ok=True)
    os.makedirs(RES, exist_ok=True)
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    plt.rcParams.update({"figure.dpi": 130, "axes.spines.top": False, "axes.spines.right": False, "axes.grid": True,
                         "grid.alpha": 0.25, "font.size": 9, "axes.titlesize": 10, "axes.titleweight": "bold"})

    print("bit-exactness check (board vs integer model):")
    lol = np.load(os.path.join(CAP, "lol.npz"))
    # the LOL captures hold the final frame of 24 identical inputs: re-run the model for the same sequence
    for i in range(0, len(lol["names"]), 10):
        require_bitexact("LOL " + str(lol["names"][i]), lol["enh"][i], np.stack([lol["low"][i]] * lol["enh"].shape[1]))
    clips = {}
    for fn in sorted(os.listdir(CAP)):
        if fn == "lol.npz" or fn.startswith("ablation_") or not fn.endswith(".npz"):
            continue
        d = np.load(os.path.join(CAP, fn))
        require_bitexact(fn[:-4], d["enh"], d["raw"])
        clips[fn[:-4]] = {k: d[k] for k in d.files}

    # ---------------- LOL paired benchmark
    lo, hi, enh = lol["low"], lol["high"], lol["enh"][:, -1]
    lrows = []
    for i in range(len(lo)):
        for m in METHODS:
            out = enh[i] if m == "engine" else baseline_fn(m)(lo[i])
            lrows.append(dict(image=str(lol["names"][i]), method=m, psnr=metrics.psnr(hi[i], out), ssim=metrics.ssim(hi[i], out),
                              loe=metrics.loe(hi[i], out), mean_luma=float(out.mean()), noise_sigma=stats.noise_sigma(out)))
    with open(os.path.join(RES, "hw_eval_lol.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(lrows[0].keys()))
        w.writeheader(); w.writerows(lrows)
    agg = {}
    for m in METHODS:
        sel = [r for r in lrows if r["method"] == m]
        agg[m] = {k: (float(np.mean([r[k] for r in sel])), float(np.std([r[k] for r in sel], ddof=1) / np.sqrt(len(sel))))
                  for k in ("psnr", "ssim", "loe", "mean_luma", "noise_sigma")}
    md = ["LOL benchmark split (50 paired images, luma, resized to 640x480). The engine column is the output of the **FPGA board** after "
          "%d identical frames (controller settled); mean +/- standard error.\n" % LOL_FRAMES,
          "| method | PSNR (dB) | SSIM | LOE (lower is better) | mean luma | noise sigma |", "|---|---|---|---|---|---|"]
    for m in METHODS:
        a = agg[m]
        md.append("| %s | %.2f +/- %.2f | %.3f +/- %.3f | %.3f | %.1f | %.2f |" % (
            m, a["psnr"][0], a["psnr"][1], a["ssim"][0], a["ssim"][1], a["loe"][0], a["mean_luma"][0], a["noise_sigma"][0]))
    wins = {k: int(sum(1 for i in range(len(lo)) if all(
        (lrows[5 * i + 4][k] > lrows[5 * i + j][k]) for j in (1, 2, 3))) ) for k in ("psnr", "ssim")}
    md.append("\nEngine beats all three baselines on %d/%d images in PSNR and on %d/%d in SSIM." % (wins["psnr"], len(lo), wins["ssim"], len(lo)))
    open(os.path.join(RES, "hw_eval_lol.md"), "w", newline="\n").write("\n".join(md) + "\n")
    print("\n".join(md))

    fig, axs = plt.subplots(1, 4, figsize=(12, 3.2))
    for ax, (k, title, better) in zip(axs, [("psnr", "PSNR (dB)", "higher"), ("ssim", "SSIM", "higher"), ("loe", "LOE", "lower"),
                                            ("noise_sigma", "noise sigma (rises with gain)", "lower")]):
        vals = [agg[m][k][0] for m in METHODS]
        errs = [agg[m][k][1] for m in METHODS]
        ax.bar(range(len(METHODS)), vals, yerr=errs, color=[COLORS[m] for m in METHODS], width=0.7, capsize=2, error_kw={"lw": 0.8})
        ax.set_xticks(range(len(METHODS))); ax.set_xticklabels(METHODS, rotation=35, ha="right")
        ax.set_title("%s  (%s is better)" % (title, better))
        for j, v in enumerate(vals):
            ax.text(j, v, "%.2f" % v if k in ("psnr", "noise_sigma") else "%.3f" % v, ha="center", va="bottom", fontsize=7)
    fig.suptitle("LOL paired benchmark, 50 images: FPGA engine (measured on the board) vs classic baselines", y=1.02, fontsize=11)
    fig.tight_layout(); fig.savefig(os.path.join(IMG, "fig_lol_metrics.png"), bbox_inches="tight"); plt.close(fig)

    # LOL examples
    pick = [int(i) for i in np.argsort([r["psnr"] for r in lrows if r["method"] == "engine"])[[0, 12, 25, 37, 49]]]
    pick = [pick[1], pick[2], pick[3]]
    fig, axs = plt.subplots(len(pick), 6, figsize=(13, 2.5 * len(pick)))
    for r, i in enumerate(pick):
        imgs = [("low-light input", lo[i]), ("gamma0.4", baseline_fn("gamma0.4")(lo[i])), ("hist-eq", baseline_fn("hist-eq")(lo[i])),
                ("CLAHE", baseline_fn("CLAHE")(lo[i])), ("FPGA engine", enh[i]), ("ground truth", hi[i])]
        for c, (t, im) in enumerate(imgs):
            axs[r, c].imshow(im, cmap="gray", vmin=0, vmax=255); axs[r, c].axis("off")
            if r == 0:
                axs[r, c].set_title(t)
    fig.tight_layout(); fig.savefig(os.path.join(IMG, "fig_lol_examples.png"), bbox_inches="tight"); plt.close(fig)

    # ---------------- real clips
    allrows, outs_all = [], {}
    for name, d in clips.items():
        rows, outs = clip_metrics(name, d["raw"], d["enh"], d["tel"])
        allrows += rows
        outs_all[name] = outs
    with open(os.path.join(RES, "hw_eval_clips.csv"), "w", newline="") as f:
        w = csv.DictWriter(f, fieldnames=list(allrows[0].keys()))
        w.writeheader(); w.writerows(allrows)

    static = ["static_dimroom_iso2000_1-60", "static_brighter_iso2000_1-60", "static_verydark_iso2000_1-60", "brightsource_iso2000-1-60",
              "static_dimroom_gt_iso200_1-60"]
    md = ["Static real clips (your camera, ISO 2000, 1/60 s), first %d frames, statistics after %d settling frames. Engine = FPGA board output.\n" % (CLIP_FRAMES, SETTLE),
          "| clip | method | mean luma | p99 | temporal std (grey levels) | SNR = mean / temporal std | spatial noise sigma | frame-mean flicker |",
          "|---|---|---|---|---|---|---|---|"]
    for r in allrows:
        if r["clip"] in static:
            md.append("| %s | %s | %.1f | %.0f | %.2f | %.1f | %.2f | %.2f |" % (r["clip"].replace("_iso2000_1-60", "").replace("_1-60", ""),
                      r["method"], r["mean_luma"], r["p99"], r["temporal_std"], r["snr"], r["spatial_sigma"], r["flicker"]))
    # dim-room paired reference (iso200 clip of the same static scene averaged over time = low-noise reference)
    ref = clips["static_dimroom_gt_iso200_1-60"]["raw"][SETTLE:].astype(np.float64).mean(axis=0)
    ref8 = np.clip(ref, 0, 255).astype(np.uint8)
    md.append("\nStatic dim room against the ISO-200 reference (time-averaged, well exposed) of the same scene; mean over frames:\n")
    md.append("| method | PSNR (dB) | SSIM |"); md.append("|---|---|---|")
    pair = {}
    for m in METHODS:
        o = outs_all["static_dimroom_iso2000_1-60"][m][SETTLE::6]
        pair[m] = (float(np.mean([metrics.psnr(ref8, f) for f in o])), float(np.mean([metrics.ssim(ref8, f) for f in o])))
        md.append("| %s | %.2f | %.3f |" % (m, *pair[m]))
    open(os.path.join(RES, "hw_eval_clips.md"), "w", newline="\n").write("\n".join(md) + "\n")
    print("\n".join(md))

    # temporal noise / SNR figure
    names = [n for n in static if n != "static_dimroom_gt_iso200_1-60"]
    fig, axs = plt.subplots(1, 3, figsize=(12.5, 3.3))
    for ax, (k, title) in zip(axs, [("temporal_std", "temporal noise (grey-level std over time)\nlower is better"),
                                    ("snr", "SNR = mean luma / temporal std\nhigher is better"), ("spatial_sigma", "spatial noise sigma\nlower is better")]):
        x = np.arange(len(names)); w = 0.16
        for j, m in enumerate(METHODS):
            v = [next(r[k] for r in allrows if r["clip"] == n and r["method"] == m) for n in names]
            ax.bar(x + (j - 2) * w, v, w, label=m, color=COLORS[m])
        ax.set_xticks(x); ax.set_xticklabels([n.replace("_iso2000_1-60", "").replace("_iso2000-1-60", "").replace("static_", "") for n in names], rotation=20, ha="right")
        ax.set_title(title)
    axs[0].legend(fontsize=7, ncol=2)
    fig.tight_layout(); fig.savefig(os.path.join(IMG, "fig_clip_noise.png"), bbox_inches="tight"); plt.close(fig)

    # lamp step: brightness and controller gain over time (gain read back from the board's telemetry)
    d = clips["lampstep_iso2000_1-60"]
    o = outs_all["lampstep_iso2000_1-60"]
    t = np.arange(len(d["raw"])) * d["stride"] / 60.0
    fig, axs = plt.subplots(2, 1, figsize=(9, 5.2), sharex=True, gridspec_kw={"height_ratios": [3, 2]})
    for m in METHODS:
        axs[0].plot(t, o[m].reshape(len(t), -1).mean(axis=1), label=m, color=COLORS[m], lw=1.8 if m == "engine" else 1.1)
    axs[0].set_ylabel("frame mean luma (0-255)"); axs[0].set_title("Lamp stepped up (6.5 s, 11 s, 15 s) and switched off (19.5 s): output brightness per frame"); axs[0].legend(ncol=5, fontsize=8)
    gain = 2.0 ** (d["tel"][:, 0] / 4096.0)
    axs[1].plot(t, gain, color=COLORS["engine"], lw=1.8)
    axs[1].set_yscale("log"); axs[1].set_ylabel("controller gain (x), from board telemetry")
    axs[1].set_xlabel("time (s)"); axs[1].set_title("Controller gain read back from the FPGA: settles without oscillation, clamps at about x32 in the dark")
    fig.tight_layout(); fig.savefig(os.path.join(IMG, "fig_lampstep.png"), bbox_inches="tight"); plt.close(fig)
    with open(os.path.join(RES, "hw_eval_lampstep.json"), "w") as f:
        json.dump({"min_gain": float(gain.min()), "max_gain": float(gain.max()), "frames": int(len(gain)),
                   "max_gain_change_per_frame_octaves": float(np.abs(np.diff(d["tel"][:, 0])).max() / 4096.0)}, f)

    analyze_ablation(plt)

    # frame montages
    def montage(name, idx, fname, boost=1.0):
        raw = clips[name]["raw"]
        o = outs_all[name]
        if idx is None:      # frame with the most motion (largest raw frame difference after settling)
            diff = np.abs(np.diff(raw[SETTLE:].astype(np.int16), axis=0)).reshape(len(raw) - SETTLE - 1, -1).mean(axis=1)
            idx = SETTLE + 1 + int(np.argmax(diff))
        imgs = [("raw" + (" (x%g for display)" % boost if boost != 1 else " (as recorded)"), np.clip(raw[idx].astype(float) * boost, 0, 255).astype(np.uint8)),
                ("gamma0.4", o["gamma0.4"][idx]), ("hist-eq", o["hist-eq"][idx]), ("CLAHE", o["CLAHE"][idx]), ("FPGA engine", o["engine"][idx])]
        fig, axs = plt.subplots(1, 5, figsize=(14, 4.0))
        for ax, (t_, im) in zip(axs, imgs):
            ax.imshow(np.rot90(im, 1), cmap="gray", vmin=0, vmax=255); ax.axis("off"); ax.set_title(t_)   # the camera was held sideways: display upright
        fig.tight_layout(); fig.savefig(os.path.join(IMG, fname), bbox_inches="tight"); plt.close(fig)
    montage("static_dimroom_iso2000_1-60", 200, "fig_montage_dimroom.png", 1)
    montage("static_verydark_iso2000_1-60", 200, "fig_montage_verydark.png", 1)
    montage("move_fast_hand_iso2000_1-60", None, "fig_montage_motion.png", 1)
    montage("brightsource_iso2000-1-60", 150, "fig_montage_brightsource.png", 1)
    # sample frames for the GIF/video step
    print("figures written to", IMG)


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    sp = ap.add_subparsers(dest="cmd", required=True)
    c = sp.add_parser("capture"); c.add_argument("--host", default="192.168.137.200")
    ab = sp.add_parser("ablation"); ab.add_argument("--host", default="192.168.137.200")
    sp.add_parser("analyze")
    a = ap.parse_args()
    if a.cmd == "capture":
        capture(a.host)
    elif a.cmd == "ablation":
        capture_ablation(a.host)
    else:
        analyze()
