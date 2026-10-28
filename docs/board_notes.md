# Board notes (DE10-Standard, Cyclone V 5CSXFC6D6F31C6)

Facts recorded with their source. "TBD" items need the physical board.

## Verified on this machine (2026-10-25)
- Quartus Prime Lite 21.1.0 Build 842, `C:\intelFPGA_lite\21.1\quartus\bin64`. Questa FSE 21.1 and Icarus 14 on PATH.
- `jtagconfig`: "No JTAG hardware available" (board not connected at the time). TBD: record the chain and the FPGA device index `@N` here before the first `quartus_pgm` (checklist 2.4a). Never use the bare default.
- Bring-up design `quartus/bringup` builds with `scripts/build_quartus.sh quartus/bringup bringup CLOCK_50 divclk`:
  121 ALMs, 186 registers, 96 pins, 1 PLL, 0 block memory bits, compressed `.rbf` 1,956,140 B (the proven `board_check` .rbf is 1,952,720 B).
  STA: all corners positive; clocks in the tables: `CLOCK_50`, PLL `vcoph[0]`, PLL `divclk` (25 MHz, setup slack 35.0 ns at 85C slow).
  `scripts/check_sta.py` fails when a required clock is absent; confirmed by removing `derive_pll_clocks` (tell: "Design is not fully constrained" and `divclk` missing).
- Fitter warning 15714 "Missing drive strength and slew rate" on outputs: defaults are used, same as the Terasic golden top. Accepted.

## Pins
- `quartus/pins/de10_nv_pins.tcl` is generated from the Terasic golden top by `scripts/gen_pins.sh` (96 assignments: CLOCK_50, KEY[3:0], SW[9:0], LEDR[9:0], HEX0-5, VGA).
- CLOCK_50/LEDR/HEX match the pin list the CFAR project's `board_check` design used on this board.
- `SW[*]` are `2.5 V` in the golden top; KEY/LEDR/HEX/VGA/CLOCK_50 are `3.3-V LVTTL`.
- VGA: ADV7123 DAC, 8 bits per channel, `VGA_CLK` is the DAC clock, `VGA_BLANK_N` = active video, `VGA_SYNC_N` tied low.
- Golden top also lists `DRAM_*` (FPGA-side SDRAM): the fallback frame store (roadmap Architecture decision 7).

## Known gaps / decisions
- VGA output timing against the ADV7123 is not constrained in the SDC (same PLL clock for data and `VGA_CLK`, 40 ns period). Revisit with `set_output_delay` if the image shows edge artefacts.
- PLL `locked` gates the design reset (`KEY[0] & pll_locked` through `reset_sync`), so the exposure window the checklist warns about (2.6) does not exist in this design. PLL `rst` is tied low.

## From the CFAR project (reference, not re-verified here)
- Boot-mode switch `SW10 MSEL[4:0]` must be `01010` (FPPx32) for the HPS to load the FPGA image; factory default `10010` silently boots in AS mode.
- Login `root`, empty password; UART J4 (FT232R, 115200 8N1). `de10_ghrd/serial_console.ps1` in the CFAR folder works when PuTTY does not.
- OS image conflict to resolve in task 0.6: checklist says Angstrom 2014 (Python 2.7 only), CFAR bring-up notes say Terasic Ubuntu 16.04 console image. Record what is actually on the SD card, and which compilers exist on the HPS. Plan assumes **C only** on the HPS.
- Proven HPS/DDR3 Qsys base for Phase 3b: `de10_ghrd/soc_system.qsys` and `hps_common_board_info.xml` in the CFAR folder. Lightweight bridge at `0xFF200000`.

## JTAG chain (measured 2026-10-27, cable `DE-SoC [USB-1]`, `-c 1`)
1) 4BA00477 SOCVHPS (HPS)  2) 02D020DD 5CSEBA6/5CSEMA6 (FPGA) -> always program with `@2`.

## Gate A (bring-up design over JTAG, 2026-10-27): PASS per user observation
Programmed `bringup.sof@2`: LEDR[0..3] lit (heartbeats caught on, PLL lock, out of reset), HEX displays counting. LEDR[9:4] mirror SW[9:4], so LEDR4/5/9 on = those switches up (not a fault).

## Board network and memory (measured 2026-10-28)
- Board IP 192.168.137.200 (Windows connection sharing, laptop 192.168.137.1), `ssh root@192.168.137.200` without a password; sshd prints a post-quantum warning, harmless.
- Linux 4.5.0 (2017 image), cmdline `console=ttyS0,115200 root=/dev/mmcblk0p2 rw rootwait`; `/proc/iomem`: System RAM is 00000000-2fffffff (768 MB, set by the device tree), so the 4 MiB rings at 0x30000000 are NOT used by Linux and **no `mem=` change is needed**. DDR3 above 0x30000000 read/write tested through /dev/mem.
- The board has gcc: `scp sw/nv_streamer.c` and compile there (`gcc -std=gnu99 -O2 -o nv_streamer nv_streamer.c`).
- SD card FAT partition (D: on the laptop): socfpga.dtb, u-boot.scr (loads soc_system.rbf), zImage, several soc_system*.rbf backups; the CFAR design is saved as soc_system_CFAR_BACKUP_20261028.rbf.
- The preloader leaves fpgaportrst = 0 (bug 10); the daemon releases it.
