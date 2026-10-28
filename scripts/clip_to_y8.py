"""Convert a video clip to 640x480 8-bit luma (roadmap task 3b.1 host side).

Pipeline: decode -> BT.601 gray -> optional rotation -> centre crop to 4:3 -> INTER_AREA resize to 640x480.
Library use:  load_clip_480(path, start=0, count=None, stride=1, rotate=0) -> (T,480,640) uint8
CLI:          python -I scripts/clip_to_y8.py in.mp4 out.y8 [--start N] [--count N] [--stride N] [--rotate 0|90|180|270]
Output .y8 = raw frames back to back, 307200 bytes each, no header; out.y8.json records the source,
parameters, frame count and sha256, so the HPS feeder and the Python models read identical bytes.
"""
import argparse
import hashlib
import json
import os

import cv2
import numpy as np

ROT = {0: None, 90: cv2.ROTATE_90_CLOCKWISE, 180: cv2.ROTATE_180, 270: cv2.ROTATE_90_COUNTERCLOCKWISE}


def to_480(gray, rotate=0):
    if ROT[rotate] is not None:
        gray = cv2.rotate(gray, ROT[rotate])
    h, w = gray.shape
    if w * 3 > h * 4:                      # wider than 4:3: crop the sides
        cw = h * 4 // 3
        x0 = (w - cw) // 2
        gray = gray[:, x0:x0 + cw]
    elif w * 3 < h * 4:                    # taller than 4:3: crop top/bottom
        ch = w * 3 // 4
        y0 = (h - ch) // 2
        gray = gray[y0:y0 + ch, :]
    return cv2.resize(gray, (640, 480), interpolation=cv2.INTER_AREA)


def load_clip_480(path, start=0, count=None, stride=1, rotate=0):
    cap = cv2.VideoCapture(path)
    if start:
        cap.set(cv2.CAP_PROP_POS_FRAMES, start)
    frames, i = [], 0
    while count is None or len(frames) < count:
        ok, f = cap.read()
        if not ok:
            break
        if i % stride == 0:
            frames.append(to_480(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY), rotate))
        i += 1
    cap.release()
    return np.stack(frames)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("src")
    ap.add_argument("dst")
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--count", type=int, default=None)
    ap.add_argument("--stride", type=int, default=1)
    ap.add_argument("--rotate", type=int, default=0, choices=[0, 90, 180, 270])
    a = ap.parse_args()
    clip = load_clip_480(a.src, a.start, a.count, a.stride, a.rotate)
    data = clip.tobytes()
    with open(a.dst, "wb") as f:
        f.write(data)
    meta = dict(source=os.path.basename(a.src), start=a.start, count=len(clip), stride=a.stride, rotate=a.rotate,
                width=640, height=480, bytes=len(data), sha256=hashlib.sha256(data).hexdigest())
    json.dump(meta, open(a.dst + ".json", "w"), indent=1)
    print("wrote %d frames, %d bytes -> %s" % (len(clip), len(data), a.dst))


if __name__ == "__main__":
    main()
