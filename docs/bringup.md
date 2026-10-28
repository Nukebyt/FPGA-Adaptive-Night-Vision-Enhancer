# Board bring-up procedure (DE10-Standard)

Follow in order. Every step is a gate on the next (checklist 4). Stop at the first failure and record it in `docs/bug_log.md`.
Items marked (verify) rest on information I could not check without the board.

## 0. What is built (all on this PC, before touching the board)
| artefact | produced by | proof it works |
|---|---|---|
| `quartus/bringup/output_files/bringup.sof` | `scripts/build_quartus.sh quartus/bringup bringup CLOCK_50 divclk` | simulation + STA; **hardware test pending** |
| `quartus/soc/output_files/DE10_Standard_NV.sof` and compressed `.rbf` | `scripts/build_soc.sh` | simulation of every module, bit-exact vs the Python model; STA with DDR3 clocks in the tables |
| `sw/nv_streamer` (ARM) | `arm-linux-gnueabihf-gcc -std=gnu99 -O2 -o nv_streamer sw/nv_streamer.c` | tested against a simulated board |
| `scripts/nv_viewer.py` | - | tested against the simulated board |

## 1. Board and cable
1. Power, USB-Blaster II (J? mini-USB "Blaster"), Ethernet cable board <-> laptop (or router), UART mini-USB (J4).
2. `SW10` (MSEL[4:0]) must be **01010** so the HPS loads the FPGA image from the SD card (CFAR notes: the factory default silently boots AS mode).
3. `jtagconfig`: must list both taps (HPS and FPGA). Write the FPGA device index into `docs/board_notes.md`; all `quartus_pgm` calls use `@N`.

## 2. Gate A: the bring-up design over JTAG (no HPS, no SD card)
`quartus_pgm --mode=jtag -o "p;quartus/bringup/output_files/bringup.sof@<N>"`
Expect: LEDR[0] and LEDR[1] blinking (~1.3 s), LEDR[2] on (PLL locked), HEX0..5 counting frames (about 60 per second, HEX0 too fast to read, HEX2 about 4 per second).
There is no VGA monitor, so the pattern itself cannot be seen: the frame counter on HEX is the proof the 25 MHz clock and timing generator run.

## 3. Gate B: Linux boots with the new FPGA image
1. Back up the SD card's `soc_system.rbf` first (checklist 2.4): copy the FAT partition's current file to `soc_system.rbf.bak`.
2. Build: `scripts/build_soc.sh` (about an hour; add `--generate` if the Qsys system changed). Check the output: `.rbf` is compressed and its size is close to the last good one (about 1.9 MB for a DE10 SoC design; an uncompressed one is ~2.4x larger and will not load).
3. Copy `quartus/soc/output_files/DE10_Standard_NV.rbf` to the SD card FAT partition as `soc_system.rbf`.
4. Reserve DDR3 for the engine (VERIFIED, nothing to do: the device tree already limits Linux to 768 MB, `/proc/iomem` ends at 0x2fffffff). Original plan, not needed: the engine's rings need 4 MiB that Linux must not touch. Edit the SD card's u-boot script / extlinux bootargs to add `mem=768M`; the default ring base 0x30000000 then lies above Linux memory. After boot, `cat /proc/iomem` must show System RAM ending below 0x30000000.
5. Boot, UART at 115200: log in as root, `ip addr` (set a static address if no DHCP: `ifconfig eth0 192.168.7.2`; laptop 192.168.7.1).

## 4. Gate C: the CSR block answers (checklist 4.5-4.6, calibrate before measuring)
On the board (as root):
```
devmem 0xFF210000                  # VERSION   expect 0x4E560001
devmem 0xFF21002C 32 0x12345678    # SCRATCH write
devmem 0xFF21002C                  # echo      expect 0x12345678
devmem 0xFF210008                  # STATUS    bit0 (ready) must be 1 within ~1 s of FPGA configuration
devmem 0xFF210028                  # CLOCK_HZ  expect 25000000 (0x017D7840)
```
(`devmem` = busybox; address = 0xFF200000 + 0x10000 + 4*word; see `docs/csr_map.md`.)
If VERSION is 0 or the scratch echo fails: the wrong bitstream is loaded, the lightweight bridge is not enabled, or `SW10` is wrong.
The same registers can be read from the PC through System Console (`fpga_only_master` is wired to the CSR).

## 5. Gate D: Gate 0, reproducibility (checklist 4.1), then the stream
1. On the board: `./nv_streamer --ddr-base 0x30000000` (copy the ARM binary with scp).
2. On the PC: `python -I scripts/nv_viewer.py --source data/own_clips/static_dimroom_iso2000_1-60.mp4 --connect 192.168.7.2 --count 120 --headless --dump run1.npz --save docs/results/hw_run1.mp4`
3. Run it a second time with `--dump run2.npz` (the daemon issues `FRAME_RESET` at every connection), then `python -I scripts/run_hw_compare.py --repro run1.npz run2.npz`: must print `RESULT: PASS`, or stop.
4. Compare with the model: `python -I scripts/run_hw_compare.py --model run1.npz` runs the integer model on the dumped input frames and diffs frame by frame, with a +/- 2 frame offset sweep before declaring a value mismatch (checklist 4.2). Its logic is self-tested (`--selftest`).
5. Only then look at the pictures and measure.

## 6. If hardware and simulation disagree (checklist 4.4, in this order)
1 reproducible? 2 is the bitstream the one you built (date, size, `VERSION`)? 3 host software from the same commit? 4 offset sweep, 5 STA slack,
6 what does hardware do that no testbench does (memory latency, stalls, cold chip), 7 only then the RTL logic.
