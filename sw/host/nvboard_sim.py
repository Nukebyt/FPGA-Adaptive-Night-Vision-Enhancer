"""Simulated board: serves the streaming protocol with the bit-accurate integer model (no hardware needed).

Used by the tests and by `scripts/nv_viewer.py --sim`. The real board runs sw/nv_streamer.c instead; both speak
docs/streaming.md. Single client at a time, like the real daemon.
"""
import socket
import struct
import threading

import numpy as np

from model import pipeline_int, stats
from . import nvproto as P

BUILD_ID_SIM = 0x51A0C0DE


class SimBoard:
    def __init__(self, host="127.0.0.1", port=0):
        self.srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        self.srv.bind((host, port))
        self.srv.listen(1)
        self.port = self.srv.getsockname()[1]
        self.csr = {}
        self._stop = False
        self.thread = threading.Thread(target=self._serve, daemon=True)
        self.thread.start()

    def close(self):
        self._stop = True
        try:
            socket.create_connection(("127.0.0.1", self.port), timeout=1).close()
        except OSError:
            pass
        self.srv.close()

    def _serve(self):
        while not self._stop:
            try:
                conn, _ = self.srv.accept()
            except OSError:
                return
            if self._stop:
                conn.close()
                return
            conn.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
            try:
                self._handle(conn)
            except (P.ProtoError, OSError):
                pass
            finally:
                conn.close()

    def _handle(self, conn):
        mtype, _, pl = P.recv_msg(conn)
        if mtype != P.T_HELLO:
            P.send_msg(conn, P.T_ERROR, 0, struct.pack("<I", P.ERR_BAD_SIZE))
            return
        w, h, _, _ = struct.unpack("<HHHH", pl)
        if w < 8 or h < 8 or w * h > 4096 * 4096:
            P.send_msg(conn, P.T_ERROR, 0, struct.pack("<I", P.ERR_BAD_SIZE))
            return
        P.send_msg(conn, P.T_HELLO_ACK, 0, struct.pack("<IIHH", 0, BUILD_ID_SIM, w, h))
        pipe = pipeline_int.IntPipeline(w, h)
        n_out = 0
        while True:
            mtype, seq, pl = P.recv_msg(conn)
            if mtype == P.T_FRAME_IN:
                if len(pl) != w * h:
                    P.send_msg(conn, P.T_ERROR, 0, struct.pack("<I", P.ERR_BAD_SIZE))
                    return
                frame = np.frombuffer(pl, dtype=np.uint8).reshape(h, w)
                # telemetry describes the parameters USED for this frame (state before step)
                used = dict(lg=pipe.lg, sigma=pipe.sigma_q8, b=pipe.b, a=pipe.a_q8, lam=pipe.lam_q4,
                            sharp=pipe.sharp_q4, core=pipe.core_q4)
                out = pipe.step(frame)
                lg = pipe.log[-1]
                n_out += 1
                hist = stats.histogram(frame)
                tel = P.Telemetry(out_count=n_out, lg_q12=used["lg"], sigma_q8=used["sigma"], mean_q4=lg["mean_q4"],
                                  a_q8=used["a"], lam_q4=used["lam"], sharp_q4=used["sharp"], core_q4=used["core"],
                                  black=used["b"], flags=0, p1=lg["p1"], p50=lg["p50"], p99=lg["p99"],
                                  hist64=P.hist64_from_hist256(hist))
                P.send_msg(conn, P.T_FRAME_OUT, seq, tel.pack() + out.tobytes())
            elif mtype == P.T_CSR_WRITE:
                a, v = struct.unpack("<II", pl)
                self.csr[a] = v
            elif mtype == P.T_CSR_READ:
                a, = struct.unpack("<I", pl)
                P.send_msg(conn, P.T_CSR_REPLY, seq, struct.pack("<II", a, self.csr.get(a, 0)))
