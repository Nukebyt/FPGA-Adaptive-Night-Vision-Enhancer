"""Build the README demo media from frames captured on the board (scripts/evaluate_board.py capture).

  python -I scripts/make_demo_media.py

Writes docs/media/*.gif (small, plays inline in the GitHub README) and docs/media/*.mp4 (H.264, full quality; needs imageio-ffmpeg).
Every panel is a real board output: left = raw camera frame (brightened x4/x8 for display only, label says so), right = FPGA output.
"""
import os
import sys

import cv2
import numpy as np
from PIL import Image

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CAP = os.path.join(ROOT, "data", "hw_eval")
OUT = os.path.join(ROOT, "docs", "media")

# name, capture file, frame step (source frames are 60 fps; lampstep was captured every 3rd frame), first, last, display boost for raw
MAX_GIF_FRAMES = 72
CLIPS = [
    ("lampstep", "lampstep_iso2000_1-60", 1, 0, None, 1.0, "lamp switched on: gain falls, no flicker"),
    ("dimroom", "static_dimroom_iso2000_1-60", 3, 40, 280, 1.0, "dim room, ISO 2000"),
    ("verydark", "static_verydark_iso2000_1-60", 3, 40, 280, 1.0, "very dark scene"),
    ("motion", "move_slow_hand_iso2000_1-60", 3, 40, 280, 1.0, "moving hand: no ghosting"),
]


def label(img, text, y=18):
    cv2.putText(img, text, (6, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, 0, 3, cv2.LINE_AA)
    cv2.putText(img, text, (6, y), cv2.FONT_HERSHEY_SIMPLEX, 0.5, 255, 1, cv2.LINE_AA)


def panel(raw, enh, boost, gain, scale):
    raw, enh = np.ascontiguousarray(np.rot90(raw, 1)), np.ascontiguousarray(np.rot90(enh, 1))       # the camera was held sideways: display upright
    l = np.clip(raw.astype(np.float32) * boost, 0, 255).astype(np.uint8)
    l = cv2.resize(l, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    r = cv2.resize(enh, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    label(l, "camera raw" + (" (x%g for display)" % boost if boost != 1 else " (as recorded)"))
    label(r, "FPGA engine   gain x%.1f" % gain)
    return np.hstack([l, np.full((l.shape[0], 2), 255, np.uint8), r])


def lol_demo(have_ffmpeg, iio):
    """The controller brightening real LOL images frame by frame, from the board capture (24 identical input frames per image)."""
    d = np.load(os.path.join(CAP, "lol.npz"))
    names = [str(n) for n in d["names"]]
    pick = [names.index(n) for n in ("22.png", "493.png", "669.png") if n in names] or [0, 20, 40]
    small, full = [], []
    for i in pick:
        for k in range(d["enh"].shape[1]):
            gain = 2.0 ** (d["tel"][i, k, 0] / 4096.0)
            for scale, out in ((0.5, small), (1.0, full)):
                l = cv2.resize(d["low"][i], None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
                e = cv2.resize(d["enh"][i, k], None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
                g = cv2.resize(d["high"][i], None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
                label(l, "low-light input"); label(e, "FPGA engine  frame %d  gain x%.1f" % (k + 1, gain)); label(g, "ground truth")
                sep = np.full((l.shape[0], 2), 255, np.uint8)
                out.append(np.hstack([l, sep, e, sep, g]))
        for _ in range(8):                      # hold the settled frame
            small.append(small[-1]); full.append(full[-1])
    palette = [v for k in range(32) for v in (k * 8 + 4,) * 3] + [0] * (768 - 96)
    frames = []
    for f in small:
        im = Image.fromarray((f // 8).astype(np.uint8), "P")
        im.putpalette(palette)
        frames.append(im)
    path = os.path.join(OUT, "demo_lol_brightening.gif")
    frames[0].save(path, save_all=True, append_images=frames[1:], duration=int(1000 / 8), loop=0, optimize=True)
    print("lol          %3d GIF frames  %.1f MB" % (len(frames), os.path.getsize(path) / 1e6), flush=True)
    if have_ffmpeg:
        mp = os.path.join(OUT, "demo_lol_brightening.mp4")
        w = iio.get_writer(mp, fps=8, codec="libx264", quality=None, ffmpeg_params=["-crf", "24", "-preset", "slow"], macro_block_size=2)
        for f in full:
            w.append_data(np.stack([f] * 3, axis=-1))
        w.close()
        print("lol          mp4 %.1f MB" % (os.path.getsize(mp) / 1e6), flush=True)


def main():
    os.makedirs(OUT, exist_ok=True)
    try:
        import imageio_ffmpeg  # noqa: F401
        import imageio.v2 as iio
        have_ffmpeg = True
    except Exception:
        have_ffmpeg = False
        print("imageio-ffmpeg missing: only GIFs will be written")
    only = set(sys.argv[1:])
    if not only or "lol" in only:
        lol_demo(have_ffmpeg, iio if have_ffmpeg else None)
    for tag, cap, step, first, last, boost, _ in CLIPS:
        if "lol" in only and len(only) == 1 or (only and tag not in only):
            continue
        d = np.load(os.path.join(CAP, cap + ".npz"))
        idx = list(range(first, len(d["raw"]) if last is None else last, step))
        if tag == "lampstep":
            idx = idx[::1]
        gains = 2.0 ** (d["tel"][:, 0] / 4096.0)
        # GIF: 0.5x panels, 12 fps; mp4: full resolution, 20 fps
        small = [panel(d["raw"][i], d["enh"][i], boost, gains[i], 0.5) for i in idx]
        gif_step = 7 if tag == "lampstep" else 1      # lampstep: spread 72 GIF frames over the whole 23 s clip
        max_frames = MAX_GIF_FRAMES
        # 32 grey levels and one shared palette keep sensor noise from blowing up the GIF size (the mp4 below is full quality)
        palette = [v for k in range(32) for v in (k * 8 + 4,) * 3] + [0] * (768 - 96)
        frames = []
        for f in small[::gif_step][:max_frames]:
            im = Image.fromarray((f // 8).astype(np.uint8), "P")
            im.putpalette(palette)
            frames.append(im)
        path = os.path.join(OUT, "demo_%s.gif" % tag)
        frames[0].save(path, save_all=True, append_images=frames[1:], duration=int(1000 / 12), loop=0, optimize=True)
        print("%-12s %3d GIF frames  %.1f MB" % (tag, len(frames), os.path.getsize(path) / 1e6), flush=True)
        if have_ffmpeg:
            full = [panel(d["raw"][i], d["enh"][i], boost, gains[i], 1.0) for i in idx]
            mp = os.path.join(OUT, "demo_%s.mp4" % tag)
            w = iio.get_writer(mp, fps=20, codec="libx264", quality=None, ffmpeg_params=["-crf", "27", "-preset", "slow"],
                               macro_block_size=2)
            for f in full:
                w.append_data(np.stack([f] * 3, axis=-1))
            w.close()
            print("%-12s mp4 %.1f MB" % (tag, os.path.getsize(mp) / 1e6), flush=True)


if __name__ == "__main__":
    main()
