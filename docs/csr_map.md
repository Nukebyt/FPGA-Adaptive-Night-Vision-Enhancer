# CSR map (nv_engine, Avalon-MM slave on the HPS lightweight bridge)

Source of truth: `rtl/nv_csr.v` (header comment) and `sw/nv_streamer.c` (`R_*` defines). Keep all three in sync.
32-bit registers, **word addressed** (byte address = 4 x word). Fixed read latency 1, no wait states. Base address in the
lightweight bridge window: set in Platform Designer (default offset 0 -> physical 0xFF200000 + offset).

| word | name | access | meaning |
|---|---|---|---|
| 0 | VERSION | RO | build id `0x4E560001`. Host software refuses to run on a mismatch (checklist: bitstream/software pairing) |
| 1 | CONTROL | RW | [0] enable, [1] frame_reset (write 1: one-clock pulse, re-initialises core + controller, zeroes IN_WR_SEQ, IN_RD_SEQ, OUT_SEQ), [2] en_temporal, [3] en_spatial, [4] en_sharpen, [5] passthru. Reset value: enable 0, stages 1, passthru 0 |
| 2 | STATUS | RO | [0] ready (controller initialised), [1] ctrl_busy (= not ready), [8] err_overrun, [9] err_notready, [10] underrun, [11] wr_overflow (sticky) |
| 3 | STATUS_CLR | W | any write clears the sticky bits |
| 4 | IN_BASE | RW | physical byte address of the input ring |
| 5 | OUT_BASE | RW | physical byte address of the output ring |
| 6 | IN_WR_SEQ | RW | frames written into the input ring by software (software increments after the copy) |
| 7 | IN_RD_SEQ | RO | frames consumed by the FPGA |
| 8 | OUT_SEQ | RO | frames completed (pixels written and statistics final); frame n is in slot n % 4 |
| 9 | SKIPPED | RO | frame periods with enable set and nothing queued |
| 10 | CLOCK_HZ | RO | 25,000,000 |
| 11 | SCRATCH | RW | echo test |
| 12 | FRAME_CYCLES | RO | clocks per frame period (420,000 for 640x480) |
| 16..29 | telemetry | RO | snapshot taken when OUT_SEQ increments: 16 lg_q12, 17 sigma_q8, 18 black, 19 a_q8, 20 lam_q4, 21 sharp_q4, 22 core_q4, 23 k_mot, 24 thr, 25 p1, 26 p50, 27 p99, 28 mean_q4, 29 flags |
| 64..127 | hist64 | RO | input histogram of the last completed frame, 64 bins of 4 grey levels, each count >> 4 |

Parameters (16..24) are the ones USED for frame n; statistics (25..28 and hist64) were measured on frame n.

## Memory layout (reserved DDR3 region, not used by Linux)
```
ddr_base + 0x000000  input ring, 4 slots x 512 KiB   (slot s at + s*0x80000; 640*480 bytes used per slot)
ddr_base + 0x200000  output ring, 4 slots x 512 KiB
```
Default `ddr_base` 0x30000000 with the kernel booted with `mem=768M`. Access it from the HPS only through an uncached
(`/dev/mem` + `O_SYNC`) mapping: the FPGA writes behind the CPU caches.

## Software protocol for the rings
Writing a frame: copy into slot `IN_WR_SEQ % 4`, memory barrier, then write IN_WR_SEQ + 1. Never have more than 3 frames queued
(IN_WR_SEQ - IN_RD_SEQ <= 3). Reading results: when OUT_SEQ > n, frame n is complete in output slot `n % 4` and the telemetry
registers describe it; read it within 3 frame periods, before the slot is reused.
