import struct

import numpy as np
import pytest

from model import pipeline_int
from sw.host import nvproto as P
from sw.host.nvboard_sim import BUILD_ID_SIM, SimBoard


def frames(n, h, w, seed=0):
    return np.random.default_rng(seed).integers(0, 60, (n, h, w), dtype=np.uint8)


def test_telemetry_pack_roundtrip():
    t = P.Telemetry(7, -1234, 700, 4000, 33, 5, 9, 70, 2, 1, 3, 20, 200, tuple(range(64)))
    b = t.pack()
    assert len(b) == P.TELEMETRY_BYTES
    assert P.Telemetry.unpack(b) == t


def test_header_size_and_magic():
    assert P.HEADER.size == 16
    assert struct.pack("<I", P.MAGIC) == b"NVID"


def test_sim_board_matches_integer_model_bit_for_bit():
    board = SimBoard()
    try:
        w, h = 48, 32
        c = P.Client("127.0.0.1", board.port, w, h)
        assert c.build_id == BUILD_ID_SIM
        fr = frames(5, h, w, 3)
        ref = pipeline_int.IntPipeline(w, h)
        for i, f in enumerate(fr):
            c.send_frame(100 + i, f)
            seq, tel, out = c.recv_frame()
            assert seq == 100 + i
            assert np.array_equal(out, ref.step(f))
            assert tel.out_count == i + 1
            assert tel.hist64 == P.hist64_from_hist256(np.bincount(f.ravel(), minlength=256))
        c.close()
    finally:
        board.close()


def test_pipelined_frames_in_flight():
    board = SimBoard()
    try:
        c = P.Client("127.0.0.1", board.port, 32, 24)
        fr = frames(6, 24, 32, 4)
        got = []
        for i, f in enumerate(fr):
            c.send_frame(i, f)
            if c.in_flight >= P.MAX_IN_FLIGHT:
                got.append(c.recv_frame()[0])
        while c.in_flight:
            got.append(c.recv_frame()[0])
        assert got == list(range(6))
        c.close()
    finally:
        board.close()


def test_csr_write_read_and_bad_handshake():
    board = SimBoard()
    try:
        c = P.Client("127.0.0.1", board.port, 16, 16)
        c.csr_write(0x10, 0xABCD)
        assert c.csr_read(0x10) == 0xABCD
        assert c.csr_read(0x14) == 0
        c.close()
        with pytest.raises(P.ProtoError):
            P.Client("127.0.0.1", board.port, 2, 2)       # too small: board answers ERROR
    finally:
        board.close()


def test_bad_magic_is_rejected():
    import io
    class S:
        def __init__(self, b): self.f = io.BytesIO(b)
        def recv(self, n): return self.f.read(n)
    with pytest.raises(P.ProtoError):
        P.recv_msg(S(b"\x00" * 16))
