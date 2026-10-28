# Laptop <-> board video streaming protocol (version 1)

Why: there is no VGA monitor, so enhanced frames travel over Ethernet to a viewer on the laptop. Same pattern as the CFAR
project's `cfar_server.c` (C daemon on the HPS owns `/dev/mem`, laptop talks TCP): the HPS image has no usable Python, so the
boundary moves, not the language. Reference implementations: `sw/host/nvproto.py` (Python), `sw/nv_streamer.c` (HPS, C),
`sw/host/nvboard_sim.py` (simulated board running the integer model, used for tests and demos without hardware).

Transport: one TCP connection, laptop = client, board = server (default port 5002), `TCP_NODELAY`, single client at a time
(there is one FPGA). All integers little-endian.

## Message header (16 bytes)
| field | type | |
|---|---|---|
| magic | u32 | bytes `N V I D` = 0x4449564E |
| version | u16 | 1 |
| type | u16 | see below |
| seq | u32 | frame id for frame messages, request id for CSR messages |
| length | u32 | payload bytes that follow |

## Types
| type | name | direction | payload |
|---|---|---|---|
| 1 | HELLO | laptop -> board | u16 width, u16 height, u16 flags (bit0: request telemetry), u16 reserved |
| 2 | HELLO_ACK | board -> laptop | u32 status (0 ok), u32 build_id, u16 width, u16 height |
| 3 | FRAME_IN | laptop -> board | width*height bytes, 8-bit luma, raster order |
| 4 | FRAME_OUT | board -> laptop | 176-byte telemetry, then width*height bytes enhanced luma; `seq` = the FRAME_IN seq it came from |
| 5 | CSR_WRITE | laptop -> board | u32 address (byte offset in the CSR block), u32 value |
| 6 | CSR_READ | laptop -> board | u32 address |
| 7 | CSR_REPLY | board -> laptop | u32 address, u32 value (seq echoes the request) |
| 8 | ERROR | board -> laptop | u32 code (1 bad magic, 2 bad version, 3 bad size, 4 short read, 5 no memory, 6 busy, 7 fpga timeout) |

Flow control: the laptop keeps at most 3 frames in flight (FRAME_IN sent minus FRAME_OUT received). The board never queues more than that,
so memory use is bounded and latency stays under about 4 frame times.

## Telemetry (176 bytes at the start of every FRAME_OUT payload)
Parameters (lg, sigma, a, lam, sharp, core, black) are the ones the datapath USED for this frame; statistics (mean, p1/p50/p99, hist64) are measured on this frame and feed the NEXT frame's parameters.

| offset | type | field | meaning |
|---|---|---|---|
| 0 | u32 | out_count | frames produced since reset |
| 4 | i32 | lg_q12 | log2 gain, Q12 (G = 2^(lg/4096)) USED for this frame |
| 8 | u32 | sigma_q8 | noise estimate used for this frame, Q8 grey levels |
| 12 | u32 | mean_q4 | mean of this frame's tone-mapped output (before sharpening), Q4; the controller's measurement |
| 16 | u16 | a_q8 | temporal blend floor, Q8 |
| 18 | u8 | lam_q4 | spatial mix, Q4 |
| 19 | u8 | sharp_q4 | sharpen amount, Q4 |
| 20 | u16 | core_q4 | sharpen coring, Q4 |
| 22 | u8 | black | black level B |
| 23 | u8 | flags | bit0 underrun, bit1 overrun, bit2 stage bypass active, bit3 manual gain |
| 24 | u8 x3 | p1, p50, p99 | input percentiles of this frame |
| 27 | u8 | reserved | |
| 28 | u32 x 5 | reserved | |
| 48 | u16 x 64 | hist64 | input histogram of this frame, bins of 4 grey levels, each count >> 4 saturated at 65535 |

`build_id` in HELLO_ACK is the VERSION CSR of the loaded bitstream; the viewer prints it and refuses to run if it does not match the expected build
(checklist rule: never pair a bitstream with newer host software).

## Pacing and the 60 Hz core
The core processes one frame per FRAME_IN. If the laptop sends 30 fps the core processes at 30 fps (a frame period with no new input frame is
skipped entirely: no state change, no statistics). The viewer therefore never needs to duplicate frames.
