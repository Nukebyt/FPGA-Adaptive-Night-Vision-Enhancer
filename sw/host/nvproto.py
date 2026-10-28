"""Reference implementation of the laptop <-> board streaming protocol (docs/streaming.md, version 1)."""
import socket
import struct
from dataclasses import dataclass

MAGIC = 0x4449564E          # bytes 'N','V','I','D'
VERSION = 1
HEADER = struct.Struct("<IHHII")
T_HELLO, T_HELLO_ACK, T_FRAME_IN, T_FRAME_OUT, T_CSR_WRITE, T_CSR_READ, T_CSR_REPLY, T_ERROR = range(1, 9)
ERR_BAD_MAGIC, ERR_BAD_VERSION, ERR_BAD_SIZE, ERR_SHORT_READ, ERR_NOMEM, ERR_BUSY, ERR_FPGA_TIMEOUT = range(1, 8)
TELEMETRY = struct.Struct("<IiIIHBBHBB3sB20x64H")
TELEMETRY_BYTES = 176
MAX_PAYLOAD = 16 * 1024 * 1024
MAX_IN_FLIGHT = 3
assert TELEMETRY.size == TELEMETRY_BYTES, TELEMETRY.size


class ProtoError(Exception):
    pass


def recv_exact(sock, n):
    buf = bytearray()
    while len(buf) < n:
        chunk = sock.recv(n - len(buf))
        if not chunk:
            raise ProtoError("peer closed after %d of %d bytes" % (len(buf), n))
        buf += chunk
    return bytes(buf)


def send_msg(sock, mtype, seq=0, payload=b""):
    sock.sendall(HEADER.pack(MAGIC, VERSION, mtype, seq, len(payload)) + payload)


def recv_msg(sock):
    magic, version, mtype, seq, length = HEADER.unpack(recv_exact(sock, HEADER.size))
    if magic != MAGIC:
        raise ProtoError("bad magic 0x%08X" % magic)
    if version != VERSION:
        raise ProtoError("bad version %d" % version)
    if length > MAX_PAYLOAD:
        raise ProtoError("payload too large: %d" % length)
    return mtype, seq, recv_exact(sock, length) if length else b""


@dataclass
class Telemetry:
    out_count: int = 0
    lg_q12: int = 0
    sigma_q8: int = 0
    mean_q4: int = 0
    a_q8: int = 0
    lam_q4: int = 0
    sharp_q4: int = 0
    core_q4: int = 0
    black: int = 0
    flags: int = 0
    p1: int = 0
    p50: int = 0
    p99: int = 0
    hist64: tuple = (0,) * 64

    def pack(self):
        return TELEMETRY.pack(self.out_count, self.lg_q12, self.sigma_q8, self.mean_q4, self.a_q8, self.lam_q4,
                              self.sharp_q4, self.core_q4, self.black, self.flags,
                              bytes((self.p1, self.p50, self.p99)), 0, *self.hist64)

    @staticmethod
    def unpack(b):
        v = TELEMETRY.unpack(b[:TELEMETRY_BYTES])
        return Telemetry(v[0], v[1], v[2], v[3], v[4], v[5], v[6], v[7], v[8], v[9], v[10][0], v[10][1], v[10][2], tuple(v[12:]))

    @property
    def gain(self):
        return 2.0 ** (self.lg_q12 / 4096.0)

    @property
    def sigma(self):
        return self.sigma_q8 / 256.0


def hist64_from_hist256(hist):
    h = [0] * 64
    for i, c in enumerate(hist):
        h[i >> 2] += int(c)
    return tuple(min(65535, c >> 4) for c in h)


class Client:
    """Laptop side: connect, handshake, send frames, receive enhanced frames with telemetry."""

    def __init__(self, host, port=5002, width=640, height=480, timeout=10.0):
        self.w, self.h = width, height
        self.sock = socket.create_connection((host, port), timeout=timeout)
        self.sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        send_msg(self.sock, T_HELLO, 0, struct.pack("<HHHH", width, height, 1, 0))
        mtype, _, pl = recv_msg(self.sock)
        if mtype == T_ERROR:
            raise ProtoError("board error %d" % struct.unpack("<I", pl[:4])[0])
        if mtype != T_HELLO_ACK:
            raise ProtoError("expected HELLO_ACK, got %d" % mtype)
        status, self.build_id, aw, ah = struct.unpack("<IIHH", pl)
        if status != 0 or (aw, ah) != (width, height):
            raise ProtoError("handshake refused: status %d size %dx%d" % (status, aw, ah))
        self.in_flight = 0

    def send_frame(self, seq, frame_u8):
        data = frame_u8.tobytes()
        if len(data) != self.w * self.h:
            raise ValueError("frame size mismatch")
        send_msg(self.sock, T_FRAME_IN, seq, data)
        self.in_flight += 1

    def recv_frame(self):
        import numpy as np
        mtype, seq, pl = recv_msg(self.sock)
        if mtype == T_ERROR:
            raise ProtoError("board error %d" % struct.unpack("<I", pl[:4])[0])
        if mtype != T_FRAME_OUT:
            raise ProtoError("expected FRAME_OUT, got %d" % mtype)
        if len(pl) != TELEMETRY_BYTES + self.w * self.h:
            raise ProtoError("FRAME_OUT size %d" % len(pl))
        self.in_flight -= 1
        return seq, Telemetry.unpack(pl), np.frombuffer(pl[TELEMETRY_BYTES:], dtype=np.uint8).reshape(self.h, self.w).copy()

    def csr_write(self, addr, value):
        send_msg(self.sock, T_CSR_WRITE, 0, struct.pack("<II", addr, value))

    def csr_read(self, addr):
        send_msg(self.sock, T_CSR_READ, 1, struct.pack("<I", addr))
        mtype, _, pl = recv_msg(self.sock)
        if mtype != T_CSR_REPLY:
            raise ProtoError("expected CSR_REPLY")
        return struct.unpack("<II", pl)[1]

    def close(self):
        self.sock.close()
