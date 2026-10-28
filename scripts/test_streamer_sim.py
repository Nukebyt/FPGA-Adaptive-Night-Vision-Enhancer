"""End-to-end test of sw/nv_streamer.c in its simulated-hardware mode (passthrough emulator), launched inside WSL.

Builds the daemon with -DNV_SIM, starts it, connects with the real Python client (sw/host/nvproto.py) and checks:
handshake, 12 frames in a 3-deep window (the same flow control the viewer uses) come back identical (passthrough) with the
right sequence numbers, telemetry fields, histogram window, CSR echo, error handling for a bad handshake, and that the daemon
survives a client that disconnects mid-frame and accepts a second connection afterwards.
Usage: python -I scripts/test_streamer_sim.py        (needs the Ubuntu WSL distro with gcc)
"""
import os
import socket
import struct
import subprocess
import sys
import time

import numpy as np

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, ROOT)
from sw.host import nvproto as P  # noqa: E402

PORT = 5012
HOST = "127.0.0.1"      # replaced by the WSL2 address below (the localhost relay is unreliable for long-lived connections)


def wsl(cmd, **kw):
    return subprocess.run(["wsl.exe", "-d", "Ubuntu", "--", "sh", "-c", cmd], capture_output=True, **kw)


def main():
    global HOST
    ip = wsl("hostname -I").stdout.decode(errors="replace").replace(chr(0), "").split()
    if ip:
        HOST = ip[0]
    print("daemon address", HOST)
    src = "/mnt/f/Projects/FPGA-Adaptive-Night-Vision/sw/nv_streamer.c"
    r = wsl("gcc -std=gnu99 -O2 -Wall -Wextra -DNV_SIM -o /tmp/nv_streamer_sim " + src)
    if r.returncode != 0:
        print("BUILD FAILED", r.stderr.decode(errors="replace")[-600:])
        return 1
    daemon = subprocess.Popen(["wsl.exe", "-d", "Ubuntu", "--", "/tmp/nv_streamer_sim", "--port", str(PORT)],
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    errors = 0
    try:
        for _ in range(50):
            try:
                socket.create_connection((HOST, PORT), timeout=0.5).close()
                break
            except OSError:
                time.sleep(0.2)
        else:
            print("daemon did not start")
            return 1
        time.sleep(0.3)
        c = P.Client(HOST, PORT, 640, 480)
        print("handshake ok, build id 0x%08X" % c.build_id)
        if c.build_id != 0x4E560001:
            errors += 1
        rng = np.random.default_rng(1)
        frames = [rng.integers(0, 256, (480, 640), dtype=np.uint8) for _ in range(12)]
        got = {}
        t0 = time.time()
        for i, f in enumerate(frames):
            c.send_frame(1000 + i, f)
            while c.in_flight >= P.MAX_IN_FLIGHT:
                s, tel, out = c.recv_frame()
                got[s] = (tel, out)
        while c.in_flight:
            s, tel, out = c.recv_frame()
            got[s] = (tel, out)
        dt = time.time() - t0
        for i, f in enumerate(frames):
            tel, out = got[1000 + i]
            if not np.array_equal(out, f):
                print("frame %d differs" % i); errors += 1
            if tel.out_count != i + 1:
                print("out_count %d expected %d" % (tel.out_count, i + 1)); errors += 1
        tel = got[1011][0]
        if tel.lg_q12 != 8192 or tel.a_q8 != 64 or tel.mean_q4 != 2048 or tel.hist64 != tuple(range(64)):
            print("telemetry wrong:", tel); errors += 1
        print("12 frames passthrough in %.2f s (%.1f fps through WSL + loopback)" % (dt, 12 / dt))
        c.csr_write(4 * 11, 0xDEADBEEF)
        if c.csr_read(4 * 11) != 0xDEADBEEF:
            print("CSR echo failed"); errors += 1
        c.close()
        time.sleep(0.3)
        # abrupt disconnect in the middle of a frame, then a new connection must work
        s = socket.create_connection((HOST, PORT), timeout=2)
        P.send_msg(s, P.T_HELLO, 0, struct.pack("<HHHH", 640, 480, 1, 0)); P.recv_msg(s)
        s.sendall(P.HEADER.pack(P.MAGIC, P.VERSION, P.T_FRAME_IN, 7, 640 * 480) + b"\x00" * 1000)
        s.close()
        time.sleep(0.3)
        c2 = P.Client(HOST, PORT, 640, 480)
        c2.send_frame(5, frames[0]); s5, _, o5 = c2.recv_frame()
        if s5 != 5 or not np.array_equal(o5, frames[0]):
            print("second connection failed"); errors += 1
        c2.close()
        # bad handshake sizes are refused
        try:
            P.Client(HOST, PORT, 320, 240)
            print("bad size accepted"); errors += 1
        except P.ProtoError:
            pass
    except Exception as e:
        errors += 1
        print("EXCEPTION:", repr(e))
    finally:
        daemon.kill()
        wsl("pkill nv_streamer_sim")
        try:
            out = daemon.stdout.read().decode(errors="replace").replace(chr(0), "")
            print("--- daemon output ---" + chr(10) + out[-1500:])
        except Exception:
            pass
    print("STREAMER SIM TEST:", "PASS" if errors == 0 else "FAIL (%d)" % errors)
    return 0 if errors == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
