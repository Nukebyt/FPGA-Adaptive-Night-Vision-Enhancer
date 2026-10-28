"""Laptop viewer for the night-vision engine: raw | enhanced split screen with a live statistics overlay.

Sources:  --source clip.mp4 | file.y8 | webcam:0
Engines:  --connect HOST[:PORT]  real board (or any server speaking docs/streaming.md)
          --sim                  in-process simulated board running the bit-accurate integer model (no hardware)
Output:   a window (default), and/or --save out.mp4. --headless disables the window (tests, batch demos).

Examples
  python -I scripts/nv_viewer.py --source data/own_clips/lampstep_iso2000_1-60.mp4 --sim --save docs/results/demo_lampstep.mp4 --stride 3 --headless
  python -I scripts/nv_viewer.py --source webcam:0 --connect 192.168.7.2
Keys in the window: q quit, space pause.
"""
import argparse
import os
import sys
import time

import cv2
import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
sys.path.insert(0, os.path.join(ROOT, "scripts"))
from clip_to_y8 import to_480  # noqa: E402
from sw.host import nvproto as P  # noqa: E402


def frame_source(spec, start=0, count=None, stride=1, rotate=0):
    """Yield 640x480 uint8 luma frames from a video file, a raw .y8 file or a webcam."""
    if spec.startswith("webcam:"):
        cap = cv2.VideoCapture(int(spec.split(":")[1]))
        n = 0
        while count is None or n < count:
            ok, f = cap.read()
            if not ok:
                return
            yield to_480(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY), rotate)
            n += 1
        return
    if spec.endswith(".y8"):
        data = np.fromfile(spec, dtype=np.uint8).reshape(-1, 480, 640)
        for i in range(start, len(data), stride):
            if count is not None and (i - start) // stride >= count:
                return
            yield data[i]
        return
    cap = cv2.VideoCapture(spec)
    if start:
        cap.set(cv2.CAP_PROP_POS_FRAMES, start)
    i = n = 0
    while count is None or n < count:
        ok, f = cap.read()
        if not ok:
            return
        if i % stride == 0:
            yield to_480(cv2.cvtColor(f, cv2.COLOR_BGR2GRAY), rotate)
            n += 1
        i += 1


def tile(img, label, scale=1.0):
    t = cv2.cvtColor(img, cv2.COLOR_GRAY2BGR)
    if scale != 1.0:
        t = cv2.resize(t, None, fx=scale, fy=scale, interpolation=cv2.INTER_AREA)
    cv2.putText(t, label, (8, 22), cv2.FONT_HERSHEY_SIMPLEX, 0.6, (0, 255, 255), 2, cv2.LINE_AA)
    return t


def compose(raw, enh, tel, fps, raw_boost):
    left = tile(np.clip(raw.astype(np.float32) * raw_boost, 0, 255).astype(np.uint8),
                "raw" + (" x%g (for viewing)" % raw_boost if raw_boost != 1 else ""))
    right = tile(enh, "enhanced")
    sheet = np.hstack([left, right])
    h, w = sheet.shape[:2]
    # statistics panel: histogram of the input (64 bins) and the controller state
    panel = np.zeros((110, w, 3), np.uint8)
    hist = np.array(tel.hist64, np.float32)
    if hist.max() > 0:
        bars = (np.sqrt(hist / hist.max()) * 90).astype(int)
        for i, b in enumerate(bars):
            x0 = 10 + i * 5
            cv2.rectangle(panel, (x0, 100 - b), (x0 + 3, 100), (200, 160, 60), -1)
    txt = ["gain %.2f   noise sigma %.2f   black %d" % (tel.gain, tel.sigma, tel.black),
           "temporal floor %.3f   spatial %.2f   sharpen %.2f" % (tel.a_q8 / 256.0, tel.lam_q4 / 16.0, tel.sharp_q4 / 16.0),
           "input p1/p50/p99 = %d / %d / %d   output mean %.0f" % (tel.p1, tel.p50, tel.p99, tel.mean_q4 / 16.0),
           "%.1f fps (viewer)   frame %d" % (fps, tel.out_count)]
    for k, t in enumerate(txt):
        cv2.putText(panel, t, (340, 24 + 24 * k), cv2.FONT_HERSHEY_SIMPLEX, 0.55, (230, 230, 230), 1, cv2.LINE_AA)
    return np.vstack([sheet, panel])


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--source", required=True)
    g = ap.add_mutually_exclusive_group(required=True)
    g.add_argument("--connect")
    g.add_argument("--sim", action="store_true")
    ap.add_argument("--start", type=int, default=0)
    ap.add_argument("--count", type=int, default=None)
    ap.add_argument("--stride", type=int, default=1)
    ap.add_argument("--rotate", type=int, default=0, choices=[0, 90, 180, 270])
    ap.add_argument("--raw-boost", type=float, default=1.0, help="brighten the raw tile for viewing only")
    ap.add_argument("--save")
    ap.add_argument("--save-fps", type=float, default=30.0)
    ap.add_argument("--headless", action="store_true")
    ap.add_argument("--dump", help="write lossless input/output frames to this .npz (for scripts/run_hw_compare.py)")
    a = ap.parse_args()
    dump_raw, dump_enh, dump_tel = [], [], []

    board = None
    if a.sim:
        from sw.host.nvboard_sim import SimBoard
        board = SimBoard()
        host, port = "127.0.0.1", board.port
    else:
        host, _, p = a.connect.partition(":")
        port = int(p) if p else 5002
    client = P.Client(host, port, 640, 480)
    print("connected, board build id 0x%08X" % client.build_id)
    writer = None
    pending = {}
    seq = 0
    done = 0
    t0 = time.time()
    paused = False
    src = frame_source(a.source, a.start, a.count, a.stride, a.rotate)

    def drain_one():
        nonlocal writer, done
        s, tel, enh = client.recv_frame()
        raw = pending.pop(s)
        done += 1
        if a.dump:
            dump_raw.append(np.asarray(raw, np.uint8).copy())
            dump_enh.append(np.asarray(enh, np.uint8).copy())
            dump_tel.append([tel.lg_q12, tel.sigma_q8, tel.mean_q4, tel.a_q8, tel.lam_q4, tel.sharp_q4, tel.black, tel.p1, tel.p50, tel.p99, tel.flags])
        sheet = compose(raw, enh, tel, done / max(time.time() - t0, 1e-6), a.raw_boost)
        if a.save:
            if writer is None:
                os.makedirs(os.path.dirname(os.path.abspath(a.save)), exist_ok=True)
                writer = cv2.VideoWriter(a.save, cv2.VideoWriter_fourcc(*"mp4v"), a.save_fps, (sheet.shape[1], sheet.shape[0]))
            writer.write(sheet)
        if not a.headless:
            cv2.imshow("night-vision engine", sheet)
            k = cv2.waitKey(1) & 0xFF
            return k
        return 255

    try:
        for frame in src:
            pending[seq] = frame
            client.send_frame(seq, frame)
            seq += 1
            while client.in_flight >= P.MAX_IN_FLIGHT:
                if drain_one() == ord("q"):
                    raise KeyboardInterrupt
        while client.in_flight:
            drain_one()
    except KeyboardInterrupt:
        pass
    finally:
        client.close()
        if writer:
            writer.release()
        if a.dump and dump_raw:
            np.savez_compressed(a.dump, raw=np.stack(dump_raw), enh=np.stack(dump_enh),
                                tel=np.asarray(dump_tel, np.int64))
            print("dumped %d frames to %s" % (len(dump_raw), a.dump))
        if board:
            board.close()
        if not a.headless:
            cv2.destroyAllWindows()
    print("%d frames in %.1f s%s" % (done, time.time() - t0, (", saved " + a.save) if a.save else ""))


if __name__ == "__main__":
    main()
