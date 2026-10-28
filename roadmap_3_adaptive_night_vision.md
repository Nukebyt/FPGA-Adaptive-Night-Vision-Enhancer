# Roadmap 3: Adaptive Night-Vision FPGA Engine (rev 2)

**Board:** Terasic DE10-Standard (Cyclone V SoC `5CSXFC6D6F31C6`: 41,910 ALMs, 112 DSP, 557 M10K = 5,570 Kb, dual-core ARM HPS, 1 GB HPS DDR3, ADV7123 VGA DAC, 10 switches / 4 keys / 6x 7-segment / 10 LEDs)
**Estimated duration:** 12-14 weeks (part-time)
**Toolchain (as installed on the dev machine):** Windows 11, Quartus Prime Lite **21.1** (`C:\intelFPGA_lite\21.1`), Platform Designer, SignalTap, Icarus Verilog 14 (`C:\iverilog`), Questa FSE 21.1 / Questa 2024.1, Python 3.13 venv (`.venv/`), MATLAB (optional second golden model).
**Rulebook:** `fpga_checklist_updated.md` (bug history of three earlier projects on this exact board). Rev 2 of this roadmap builds its rules into the phases as gates; section "Standing rules" lists them. Where a task says **[CL §x]** it is there because of that checklist section.

**How to use:** tick `- [x]` when done (`[~]` = partly done) (or wrap the line in `~~strikethrough~~`). Every phase ends with an **Exit gate**. Do not start the next phase until the gate passes.

**What changed from rev 1 (and why)**

| Change | Reason |
|---|---|
| Fedora/cocotb -> Windows toolchain, vector-file self-checking Icarus testbenches (cocotb optional) | Matches the machine and the two earlier projects that worked; cocotb + the Windows Icarus build is fragile. [CL §3.2] |
| Pipeline clock = VGA pixel clock; datapath is lockstep 1 pixel/clock | Removes pipeline<->VGA CDC and the line FIFO; 25 MHz gives 40 ns/cycle, so Fmax is a non-issue and multipliers can be shared. |
| Frames run at the 60 Hz display cadence, not 30 fps | A 30 fps source on 60 Hz would process every frame twice and corrupt the temporal-filter statistics. Synthetic clips duplicate *scene content* and draw independent noise per frame. |
| Previous-output frame store is **on-chip M10K** (307,200 B = 2.46 Mb = 44% of M10K), updated in place | Removes the frame-writer DMA, the double-buffer ownership scheme and DDR3 read-back latency. The HPS reads it through a bridge window when the pipeline is frozen, which gives a bit-exact hardware-vs-model capture path. |
| Phase 3 split into 3a (VGA + on-chip test source, no HPS) and 3b (HPS DDR3 input DMA) | Gets the PLL, VGA, frame store and timing closed before the riskiest block (HPS F2H SDRAM port). |
| HPS side is C only; clips are decoded on the PC and shipped as raw 8-bit luma files | The stock HPS Linux has no usable Python/OpenCV. [CL §5] |
| Added VERSION/BUILD-ID CSR, `quartus_sta` from first synthesis, Gate-0 reproducibility test | [CL §0 rules 1, 2, 3, 6] |
| Two independent golden models (vectorised numpy + scalar loop reference) | A golden model is as likely to be wrong as the RTL. [CL §3.2] |

---

## Project definition

**One-line pitch:** A real-time video enhancement engine for low-light footage where a **closed-loop controller** reads scene statistics every frame and adapts gain, tone mapping, and denoising strength together, with **motion-aware temporal denoising** so moving objects do not smear.

**Where the novelty is (keep this in mind at every design choice):**
1. The controller couples exposure/gain to **denoise and sharpen strength** (more gain = more noise = stronger denoising, less sharpening).
2. The temporal denoiser is **motion-adaptive**, so it denoises static regions heavily and moving regions lightly.
3. The control loop is stable (no flicker or pumping), and you can prove it with measurements.

**Target specification**

| Item | Target |
|---|---|
| Source | Low-light video/image datasets, synthetic low-light clips, and your own night clips; decoded on the PC, played from HPS DDR3 |
| Resolution / rate | 640x480, **60 Hz** (VGA timing 800x525 total, pixel clock 25.0 MHz from a PLL, 59.5 Hz; 25.175 MHz is an optional refinement) |
| Pixel format | 8-bit luma (Y) first; VGA output drives R=G=B=Y. Colour via chroma passthrough as a stretch |
| Pipeline | Statistics -> controller -> tone mapping -> temporal denoise -> spatial denoise/sharpen -> VGA |
| Clocking | One datapath clock = VGA pixel clock. Blanking intervals (160 clk/line, 45 lines) are the gaps used for controller and LUT work |
| Display | **No VGA monitor is available: the laptop screen is the display.** Enhanced frames are DMA'd into reserved HPS DDR3, a C daemon on the HPS streams them over Ethernet (TCP) to a viewer on the laptop, which also composes the split screen and statistics overlay. The VGA pins stay wired but optional. |
| Headline metrics | PSNR/SSIM on paired data, noise reduction in static regions, flicker metric, ghosting metric, detection accuracy gain (optional), resources/timing/power |

---

## Architecture decisions (frozen for rev 2; reopen only with a written reason)

1. **Lockstep streaming.** VGA timing generator is the master. Every datapath module sees `valid` that is low during blanking (640 on / 160 off per line, 480 of 525 lines). No module may assume gap-free input. [CL §1.7]
2. **Previous-output store.** One 640x480x8 simple-dual-port RAM in its own module (registered read, kept alive). Row `r+1` of the old frame is read into 3-row window line buffers before row `r` of the new output is written back, so the in-place update never reads a pixel it has overwritten. Whether the stored value is post-temporal (default, avoids feeding sharpening back) or post-spatial is fixed in task 2.5 and mirrored in the model.
3. **Controller timing.** Statistics of frame N are accumulated during active video, the controller + LUT generation run in vertical blanking, and the new parameters take effect at the first active pixel of frame N+1. The model implements exactly this one-frame delay. Whether statistics are taken on the input (feed-forward) or on the output (true feedback) is decided in task 2.4 with a stability argument.
4. **Parameters change only at frame boundaries.** Double-buffered LUT and parameter registers swap on `vsync`; there is no mid-frame change path to verify.
5. **HPS input path (Phase 3b).** HPS memcpy's decoded frames into a DDR3 ring; an FPGA-side DMA on the F2H SDRAM port reads one line ahead into a dual-clock FIFO (DMA clock -> pixel clock is the only CDC in the design). Underrun policy: repeat last frame, set a sticky status bit, never stall VGA.
6. **Control/status.** Lightweight HPS-to-FPGA bridge at `0xFF200000`. A read-only `VERSION` CSR holds a build ID; host software refuses to run on a mismatch. [CL §0 rule 2]
7. **Fallback if M10K fit fails** (>85% M10K or unroutable): use the 64 MB FPGA-side SDRAM (the board has it; `DRAM_*` pins are in the golden top) for the previous-output store, or drop to 320x240 working resolution first. Decide with data from task 5.11, not before.
8. **Display / capture path (laptop viewer).** Output pixels (after sharpen) go through a frame-writer DMA into a reserved DDR3 ring; the HPS daemon `sw/nv_streamer.c` (adapted from the CFAR project's `cfar_server.c`: `/dev/mem`, single-connection TCP, magic/version header, error codes) sends frames to `scripts/nv_viewer.py`. The same path is the bit-exact capture channel for Phase 6.2. Protocol in `docs/streaming.md`. Fallback if the DDR3 reservation or write DMA fails: HPS reads the output through a bridge window at reduced frame rate.
9. **Frame-driven core, no VGA dependence.** The enhancement core takes a pixel stream with `valid/sof/eof` and arbitrary gaps and produces a delayed stream; each window stage flushes itself for W+1 clocks after `eof` (bottom/right borders replicate). The 25 MHz timing generator is only the frame pacer. If no new input frame is available at a frame start, the whole frame period is skipped (state unchanged, no statistics), which also handles 30 fps sources. Required spacing between `eof` and the next `sof`: at least 4*(W+2) clocks (flagged by a sticky overrun bit); VGA timing gives 36,000.

---

## Standing rules (from the checklist; apply in every phase)

- **S1 Timing from day one.** `quartus_sta` runs in the build script from the first synthesised module. Read the slow-1100mV-85C setup slack. After any PLL is added: `derive_pll_clocks` is in the SDC, and the PLL clock name must *appear* in the slack tables. PLL `locked` gates the reset of what it clocks. [CL §0.1, §0.6, §2.2, §2.6]
- **S2 One pipeline stage = at most one significant arithmetic operation.** Narrow every intermediate to its real range. Every pipelined module exports its latency as a `localparam`. [CL §1.10]
- **S3 RAM inference.** Memories live in standalone modules, registered read, never inline in a `generate` body, never with a runtime byte-enable loop. After every synthesis, check the map report: memory bits plausible, nothing silently deleted. Iterate with `quartus_map` alone. [CL §1.1]
- **S4 Portable Verilog.** No hierarchical references, no `genvar` in a `for` header, no `localparam` in a `#(...)` port list, no `break`. Write Verilog-2005/plain SV that both Icarus and Quartus accept. Run a `quartus_map` probe of every new module before building on it. [CL §1.9]
- **S5 Fixed-point.** Every port comment states its Q format. Any precision constant changes in RTL and in `pipeline_int.py` in the same commit. Sweep reciprocal-multiply widths in Python before choosing. [CL §1.4]
- **S6 Gaps and stalls.** Every streaming module gets a testbench with randomised input gaps and downstream stalls, gap parameter swept 0..N. Handshake signals are combinational unless there is a written reason; if registered, re-verify under stall. [CL §1.6, §1.7]
- **S7 Test data has entropy.** Acceptance tests use random/natural/noisy stimulus plus a moving object. Smooth ramps are diagnostic only. [CL §3.1]
- **S8 Two golden models** that must agree before either is used to judge RTL. A latency ledger comment sits at the top of every testbench. Compare by absolute stream position plus an explicit latency, not by a skip counter. [CL §3.2, §3.3]
- **S9 Regression harness is verified.** `scripts/run_regression.py` must report FAIL on a deliberately broken DUT/vector before it is trusted, parse the simulator's own error-count line rather than the exit code, and treat "no verdict found" as FAIL. Scripts stay plain ASCII. [CL §3.8, §3.9]
- **S10 Per-frame state has a soft reset.** A CSR `FRAME_RESET` re-arms per-frame control state (histogram bank, motion/temporal warm-up, controller state when requested), and result latches clear with it. [CL §1.8]
- **S11 Hardware gates in order.** Gate 0 (same input 4x -> bit-identical, also from a fresh FPGA configuration), Gate 1 (match model, with latency/offset sweep), Gate 2 (only then measure). Measurement scripts exit non-zero if Gates 0/1 fail. [CL §4]
- **S12 Flashing hygiene.** `.rbf` built with `bitstream_compression=on`; size compared to the last good one; old `.rbf` backed up; JTAG programming always uses an explicit `@N` device index confirmed by `jtagconfig`; bitstream and host software built from the same commit. [CL §2.4, §2.4a]
- **S13 Provenance.** Everything synthesis reads (LUT `.hex`, coefficient tables) is committed, with a header naming the generating script. Duplicated constants are listed in a comment at the primary definition. [CL §7.1, §1.11]
- **S14 Bug log.** `docs/bug_log.md`, fixed format (Symptom / Root cause / Fix / Lesson) with exact numbers. [CL §7.3]
- **S15 Debug visibility.** Internal state exposed as real ports (no hierarchical refs), sticky error latches to LEDs, a heartbeat bit proving clock and reset are alive. Known-good calibration design (blink/echo) before trusting any new measurement path. [CL §4.5, §4.6]

---

## Phase 0: Environment and board bring-up (Week 1)

- [x] **0.1** Repo layout: `rtl/`, `tb/`, `model/`, `sw/`, `quartus/`, `docs/`, `data/` (gitignored), `scripts/`. `git init` done; `.gitignore` in place.
- [x] **0.2** Quartus Prime Lite 21.1 present; `quartus_sh --version` verified (21.1.0 Build 842). Questa FSE 21.1 and Icarus 14 on PATH.
- [x] **0.3** Python 3.13 venv with `numpy scipy scikit-image opencv-python matplotlib pytest` (`.venv/`, `requirements.txt`). cocotb is optional and is not on the critical path.
- [x] **0.4** [done 2026-10-27: chain = HPS @1, FPGA @2] Plug in the board: `jtagconfig` lists the cable and **both** taps (HPS and FPGA). Record the FPGA device index for `@N` in `docs/board_notes.md`. (Currently: "No JTAG hardware available", board not connected.) [CL §2.4a]
- [x] **0.5a** Pin file generated from the Terasic golden top and cross-checked against the proven `board_check` pins: `quartus/pins/de10_nv_pins.tcl` (96 assignments, `scripts/gen_pins.sh`).
- [x] **0.5b (build side)** Own bring-up design `quartus/bringup/`: PLL 50 -> 25 MHz, VGA test patterns (ramp / checker + moving block / LFSR noise / flat), HEX frame counter, LED heartbeats. `scripts/build_quartus.sh` runs map -> fit -> sta -> asm -> compressed rbf and `scripts/check_sta.py` fails if the PLL clock is missing from the slack tables (negative-tested). 121 ALMs, all corners positive, 25 MHz slack 35.0 ns. **Still to do on hardware:** program it and see the pattern on a monitor. (Replaces "run a Terasic VGA demo": same proof, and it is the seed of the real top level.)
- [x] **0.6** [done 2026-10-28: Linux 4.5 boots the new rbf, ssh at 192.168.137.200] Boot the Linux SD image over UART (`serial_console.ps1` from the CFAR project works), check `SW10 MSEL = 01010` first, confirm SSH. **Record which OS image is on the card** (earlier notes disagree: Angstrom 2014 with Python 2.7 vs Ubuntu 16.04) in `docs/board_notes.md` and what compilers and tools are present on the HPS.
- [~] **0.7** (pins done, rest pending) Collect references into `docs/`: DE10-Standard user manual (PDF exists in the CFAR folder), pin file, HPS bridge map, the proven GHRD Qsys (`soc_system.qsys`, `hps_common_board_info.xml`) copied in as the Phase 3b starting point.
- [x] **0.8** `docs/bug_log.md` and `docs/board_notes.md` created.

**Exit gate:** a custom bitstream loads over JTAG with the correct `@N`, VGA shows the pattern, STA slack is positive and the 25 MHz clock appears in it, Linux boots, SSH works.

---

## Phase 1: Datasets and metrics (Weeks 2-3)

- [x] **1.1** LOL downloaded (485 train + 15 eval pairs, 400x600, verified paired) into `data/lol/`. SID is not used (raw data, tens of GB).
- [x] **1.2** Low-light video: 11 own clips recorded and verified (`data/own_clips/`, 1080p ~58 fps, ISO 2000 1/60 f1.7 locked; `docs/results/own_clips_summary.md`): lens-covered, 3 static scenes (mean luma 6 / 23 / 27), lights-on ground truth for the dim scene (mean 93, ISO 200), lamp step, slow/fast hand and tape-roll motion, bright light source. Finding: the phone's processing and H.264 encoding left very little noise (temporal std ~1.2 grey levels on the dim clip, spatial sigma 0.25 at 1080p), so the real clips resemble the `lol` preset, not `moderate`/`harsh`. BVI-RLV (IEEE login) was not used; the quantitative video work uses synthetic clips from LOL stills with exact ground truth.
- [ ] **1.3** Optional: ExDark or similar for the **downstream detection** test.
- [x] **1.4** **Synthetic low-light generator** `model/lowlight_sim.py`: linearise well-lit frames, scale by an exposure schedule, apply Poisson-Gaussian noise (shot + read), re-encode and quantise. Per-frame exposure schedules (lights on/off, headlights), 30->60 fps content duplication with independent noise per frame, and three **noise presets calibrated against LOL** (`lol` sigma ~1.4 vs real 1.0; `moderate` ~5.5; `harsh` ~12; `docs/results/sim_calibration.md`). LOL itself is very clean, so results are quoted per preset, never pooled.
- [x] **1.5** Metrics `model/metrics.py`: PSNR, SSIM, LOE; static-patch temporal noise; flicker; ghosting/smear vs. a no-temporal baseline. Unit-tested in `model/tests/`.
- [x] **1.6** Benchmarks frozen. Images: 50 LOL pairs (15 eval15 + 35 seeded from our485) plus a separate 100-pair tuning split, sha256 in `data/benchmark_manifest.json` (`scripts/make_benchmark.py`). Video: 10 synthetic clips x 60 frames (3 noise presets, steady / pulse / step exposure schedules, static and panning background, exact motion masks) from the first 10 benchmark images, generated deterministically with checksums in `data/video_benchmark_manifest.json` (`scripts/make_video_benchmark.py --check`). Tune only on the tuning split.
- [x] **1.7** `scripts/run_metrics.py`: one command, verifies checksums, prints and saves the table for every method (`docs/results/metrics_benchmark.md`). The engine is added as another entry in `METHODS` in Phase 7.

**Exit gate:** a frozen benchmark set and a one-command metrics script.

---

## Phase 2: Algorithm design in Python (Weeks 3-6)

- [x] **2.1** Scene statistics `model/stats.py`: 256-bin luma histogram, mean, integer-exact percentiles from the histogram (p1, p50, p99; defined as the RTL will compute them), noise estimate (Immerkaer: sum of |3x3 Laplacian-of-Laplacian|, which is one accumulator in hardware).
- [x] **2.2** Baseline tone mappers `model/baselines.py`: gamma, histogram equalisation, CLAHE.
- [x] **2.3** Tone mapper: gain + gamma LUT, `y = 255*clip(G*(v-B)/255,0,1)^0.4`, black level B = min(p1, 16), applied to the denoised sensor-domain value with 2 fractional bits (10-bit LUT index). Chosen because the Phase 4 hardware becomes a 1024-entry table plus a generator. gamma 0.4 and target 128 tuned on the LOL tuning split (`model/enh.py`).
- [x] **2.4** Closed-loop controller in float (`enh.py`) and integer (`pipeline_int.py`): multiplicative integrator in the log2 domain on the measured output mean, k = 0.5, rate limit (+0.20 / -0.40 ln per frame), +/-5% deadband, highlight clamp on the 95th percentile, black level <= ~1 sigma of the noise estimate, G in [1, 64], one-frame delay. Stability argument in `docs/controller.md` (stable for k*gamma_eff < 2; tuned design 0.2; k = 5 oscillates every frame, measured in `docs/results/step_response_moderate.png`). Real lamp-step clip: gain tracks each step within ~0.15 s and the output mean stays at 108-138 against a target of 128 (`docs/results/real_lampstep_trace.png`); each step causes a one-frame overshoot spike from the frame of delay.
- [x] **2.5** Motion-adaptive temporal denoiser in the raw domain with the frame store holding pre-tone-map data (a gain change cannot fake motion). Motion = 3x3 mean |cur - prev| / sigma mapped through a 64-entry curve (1.5 sigma -> 0, 3.94 sigma -> full replacement); blend floor set by the predicted output noise. A test caught that the curve topped out at 98% (ghost after a cut); fixed.
- [x] **2.6** Spatial sigma filter (3x3, neighbours within 2.5 sigma of the centre, reciprocal-ROM mean, mixed by the coupling strength).
- [~] **2.7** Gain-aware unsharp mask with coring implemented; finding: at the moderate and harsh presets the coupling switches it off entirely (predicted output noise > 12 levels), so it only acts on clean footage. Revisit with the retuning below.
- [x] **2.8** Closed loop run on synthetic exposure steps and on the real lamp-step, dim-room, slow-hand, bright-source and very-dark clips (`scripts/real_clip_test.py`, montages in `docs/results/real_*.png`). Real footage found and fixed three defects the synthetic data had hidden: black-level crushing of real dark detail, the highlight clamp pinning gain at 1.0 when a lamp was visible, and a steep dark-end gamma (optional linear toe tested: -0.7 dB on LOL, disabled). Border handling fixed as replicate everywhere.
- [x] **2.9** Ablation (`docs/results/ablation_*.md`, `adaptivity_*.md`, `retune*.md`): temporal + spatial denoising cut static noise from 49 to 1.8 (moderate) and 100 to ~3 (harsh) grey levels with +4.6 to +7 dB PSNR. Noise coupling, with retuned constants (sigma_t 1.5, blend floor 1/8), versus fixed strengths with an exposure step inside one clip: the coupled design ties for best SSIM in all 6 (noise preset x dark/bright) cases and is within 0.16 dB PSNR of the best everywhere; the best single fixed setting loses SSIM in 4 of 6 (up to 0.06) and a heavy fixed setting loses on clean footage. The margin over a well-tuned fixed compromise is modest (<= +0.06 SSIM, <= 0.2 dB); report it that way. Sharpening only acts on clean footage. Known weakness: error around moving objects is 1.3-1.4x a no-temporal baseline at moderate noise. Final table with the last constants is in `docs/results/ablation_*.md` (static noise 8.5 / 1.8 / 3.1 grey levels after the full pipeline vs 8.5 / 49 / 100 for tone map only; lol / moderate / harsh). Open item carried to Phase 5: ghost error near moving objects.
- [x] **2.10** Bit widths swept (`docs/results/bitwidth.md`): the integer model matches the float model to 45-55 dB at F = 2 fractional bits (10-bit frame store, 54% of M10K); F = 1 (9-bit, 49%) is the fallback, F = 0 loses up to 0.3 dB. Chosen: F = 2.
- [~] **2.11** Two independent bit-accurate models agree bit for bit (`pipeline_int.py` vectorised, `pipeline_ref.py` scalar loops; 40 tests: random noise, natural video with motion, exposure step, saturation, extremes, F = 0/1/3) and the exported ROM `.hex` files (`rtl/rom/`, `scripts/export_roms.py --check`) match the models. Constants retuned this phase: sigma_t 1.5, blend floor 1/8, highlight percentile 95, black level <= sigma. To freeze: the last ablation, then tag the constants; test-vector exporter for the RTL testbenches (Phase 4).

**Exit gate:** a frozen, bit-accurate pipeline (two agreeing models) that beats the baselines on your metrics and is stable in the closed loop.

---

## Phase 3a: Display path and frame store, no HPS (Weeks 4-6, parallel with Phase 2)

- [x] **3a.1** Top level skeleton with PLL (50 -> 25 MHz), reset synchroniser gated by PLL `locked`, VGA timing generator (640x480 @ 59.5 Hz, 420,000 clk/frame, 36,000 clk vblank), SDC with `derive_pll_clocks`. Verified by `tb/vga_timing_tb.v` and STA. [S1]
- [~] **3a.2** On-chip test source `rtl/test_pattern.v` (ramp, checker + moving block, LFSR noise re-seeded per frame, flat) verified pixel-exact over 2.1M pixels incl. blanking by `tb/test_pattern_tb.v`. Still to do: emit the same LFSR/pattern frames from `model/` so Python and RTL agree, and move to a `valid/sop/eop` stream interface.
- [x] **3a.3** Previous-output frame store (`nv_temporal`: in-place 10-bit store, reads run W+1 pixels ahead of writes, standalone `ram_sdp`), verified bit-exact in the core and system testbenches; 3,072,000 bits = 54% of the device's block memory, inferred as real RAM in Quartus.
- [x] **3a.4** CSR block `nv_csr` (Avalon-MM slave, `docs/csr_map.md`): VERSION, CONTROL (enable, frame_reset, stage enables, passthru), sticky STATUS, ring bases and sequence counters, telemetry snapshot, hist64 window, SCRATCH echo. Verified in `nv_engine_tb`.
- [ ] **3a.5** Board UI: switches/keys select stage enables and manual overrides, HEX shows current gain, LEDs show status. The raw / enhanced / split-screen / overlay views are composed in the laptop viewer (no monitor on the board).
- [x] **3a.6** Testbenches with random gaps and stalls: win3x3 (0-70% gaps), core (0-80% gaps), controller (random + directed + 8,000-case soak), system (memory read/write stalls up to 70%, serial and burst software, FRAME_RESET reproducibility). 40+ injected faults, all caught except proven-equivalent mutants (bug log #8).
- [x] **3a.7** Synthesis check on the real 640x480 core (`quartus/core`): 2,323 ALMs (6%), 17 DSP (15%), 56% block memory, 8 corners positive, setup slack +25.0 ns at 25 MHz (about 65 MHz possible), `clk` present in every slack table.

**Exit gate:** test pattern -> frame store -> VGA, timing closed with the 25 MHz clock visible in STA, passthrough pixel-exact in simulation and on the monitor.

---

## Phase 3b: HPS video input (Weeks 6-8)

- [x] **3b.1** Replaced by `sw/nv_streamer.c` (HPS, C) + `scripts/nv_viewer.py` (laptop): clips are decoded on the PC and streamed over Ethernet; nothing is copied to the SD card.
- [x] **3b.2** (built 2026-10-27: fit OK, 14% ALM, 56% block memory, 17 DSP, STA PASS incl. DDR3 clocks, min setup slack +1.73 ns on the HPS DDR3 clock, +10.6 ns on the 25 MHz clock; compressed rbf 3.3 MB; hardware untested) Platform Designer system derived from the proven GHRD `soc_system.qsys`: add the F2H SDRAM port and the CSR slave. Treat `qsys-generate` as risky: re-apply and document any `.qip` patch after each regeneration, hand-edits to generated files are recorded. [CL §2.3]
- [x] **3b.3** Frame-reader DMA `dma_rd` + `fifo_64to8` (credit-based pipelined single-beat reads, byte serialiser). Datapath, DMAs and CSR share the 25 MHz clock, so there is no CDC FIFO at all. Verified under read stalls in `nv_engine_tb`.
- [x] **3b.4** CDC audit: one clock domain for engine, DMAs, CSR and the HPS bridge ports (25 MHz PLL, lock-gated reset); the only crossings are the HPS-internal bridge/SDRAM clock crossings inserted by Platform Designer. `scripts/build_soc.sh` requires `CLOCK_50`, the PLL `divclk` and the DDR3 clocks in the STA tables.
- [ ] **3b.5** Verify: pixel-exact passthrough of a real clip, no dropped frames over 10,000 frames, no tearing, deliberate underrun is flagged and recovers.
- [x] **3b.6** Frame-writer DMA `dma_wr` (packer + 16-word FIFO, accepted-write completion, overflow flag), slot selected by OUT_SEQ % 4; reserved-DDR3 mechanics in `docs/bringup.md` (to verify on the board).
- [x] **3b.7** `sw/nv_streamer.c`: builds natively, for ARM (`arm-linux-gnueabihf-gcc`) and in a simulated-hardware mode; passes the end-to-end simulation test (`scripts/test_streamer_sim.py`: handshake, 12-frame passthrough with flow control, telemetry, CSR echo, mid-frame disconnect, second connection, bad size). Hardware run pending.
- [x] **3b.8** `scripts/nv_viewer.py`: split screen with live statistics overlay, source = clip or webcam, engine = real board or the simulated board; demo videos rendered from the real clips.

**Exit gate:** a clip streams laptop -> HPS -> DDR3 -> FPGA -> frame store -> DDR3 -> HPS -> laptop viewer with exact passthrough (all stages bypassed) and no dropped frames.

---

## Phase 4: Statistics and controller RTL (Weeks 6-8)

- [x] **4.1** Histogram engine `nv_hist`: 256 x 19-bit RAM, read-modify-write with same-bin forwarding (fault-injected: removing it is caught by the constant-image vectors), self-clearing after reset.
- [x] **4.2** End-of-frame logic: single bank, scanned and cleared by the controller in the blanking (36,000 clocks available, about 2,500 needed), so ping-pong banks were not necessary; the tests require at least 4*(W+2) clocks between frames and flag an overrun otherwise.
- [x] **4.3** Mean and percentiles: one sequential pass over the 256 bins (p1, p50, p95, p99, 4-bin telemetry groups) and an exact sequential divider for the mean; bit-exact to the model.
- [x] **4.4** Noise estimator `nv_noise` (integer Immerkaer sum over interior pixels, bit-exact).
- [x] **4.5** Controller `nv_ctrl` (log2-domain integrator, rate limit, deadband, headroom clamp, black level, noise coupling, derived frame constants); 13 injected faults on it are caught by `nv_ctrl_tb` (random + directed + soak). Note: the headroom clamp's floor of 8 limits the real maximum gain to about 32, not 64.
- [x] **4.6** Tone-LUT generator: 1024 entries into the shadow bank in the blanking, double-buffered RAM swapped at the first pixel of the next frame, identity table for passthrough.
- [x] **4.7** Bit-exact testbenches against `pipeline_int.py`: stage streams, controller state and all 1024 LUT entries after every frame (`nv_core_tb`), controller alone (`nv_ctrl_tb`, 8,840 cases), whole system (`nv_engine_tb`).
- [x] **4.8** Controller behaviour in RTL equals the model bit for bit over exposure steps (`small_step`), dark/bright/ultra-dark regimes and clamps; the stability argument and measured step responses are in `docs/controller.md`.

**Exit gate:** statistics, controller, and LUT generation are bit-exact to both models and stable; synthesis map/STA clean.

---

## Phase 5: Enhancement datapath RTL (Weeks 7-10)

- [x] **5.1** Tone-mapping stage (`nv_tone`, one-clock LUT read, 10-bit index).
- [x] **5.2** Line buffers and 3x3 window generator `win3x3` (replicate borders, self-flush, arbitrary gaps), shared by four stages.
- [x] **5.3** Motion measure (3x3 SAD, fixed-latency pipeline) in `nv_temporal`.
- [~] **5.4** Alpha: fixed 64-entry motion ROM plus the controller-supplied floor; a CSR-programmable table was not implemented (not needed so far).
- [x] **5.5** Temporal blend (one multiply per stage) writing back in place.
- [x] **5.6** Latency alignment between current and previous-frame paths verified by exact comparison on random and natural video with motion (not only gradients).
- [x] **5.7** Spatial sigma filter `nv_spatial` (reciprocal ROM, exact bypass at lam = 0).
- [x] **5.8** Gain-aware unsharp mask `nv_sharpen` (exact bypass at sharp = 0).
- [~] **5.9** Bypass controls via CSR (temporal, spatial, sharpen, passthrough with identity LUT); a per-stage freeze was not implemented.
- [x] **5.10** Full-datapath testbench bit-exact vs `pipeline_int.py` with random gaps, plus fault injection (`scripts/run_regression.py --selftest`).
- [x] **5.11** Synthesised on the real device (see 3a.7): memory inferred as RAM (3.16 Mb), no optimizer crash, timing positive.

**Exit gate:** the full datapath is bit-exact in simulation and STA is clean (positive setup slack on the slow 85C corner, every clock present in the tables).

---

## Phase 6: System integration and tuning on hardware (Weeks 10-12)

- [x] **6.1** [done 2026-10-28: full chain runs on the board, ~25 frames/s end to end over Ethernet] Connect `DMA read -> statistics -> tone map -> temporal -> spatial -> sharpen -> VGA`, the frame store and the controller feedback loop.
- [x] **6.2** [done 2026-10-28 on hardware: 11 own clips x 90 frames bit-exact vs the integer model, 120-frame repeat identical; see bug 10] **Gate 0:** same clip 4x -> bit-identical captures, including after a fresh FPGA configuration. **Gate 1:** capture output frames (freeze, read the frame-store window over the bridge) and compare with `pipeline_int.py`, with a latency/offset sweep before declaring a value mismatch. Must match bit for bit. [S11]
- [ ] **6.3** Run real night clips. Tune only **controller parameters and LUT tables** through CSRs, not RTL.
- [ ] **6.4** Difficult scenes: sudden lights (car headlights), complete darkness (noise only), bright light sources in dark scenes (saturation and blooming), fast motion.
- [ ] **6.5** **Auto/manual mode** with the ARM able to override the controller.
- [ ] **6.6** **Statistics overlay** in the viewer (live histogram bars, gain, noise estimate from the per-frame telemetry).
- [ ] **6.7** Soak test: 1+ hour looped playback, no hangs, no sticky error flags, no controller drift, Gate 0 repeated at the end.
- [ ] **6.8** Timing and CDC re-audit on the full design (STA with every clock named in the tables).

**Exit gate:** a night clip plays enhanced on VGA with stable brightness, low noise, and no visible ghosting, and hardware output matches the model bit for bit.

---

## Phase 7: Evaluation and benchmarking (Weeks 12-13)

- [x] **7.1** **Paired-image quality:** PSNR/SSIM/LOE on LOL for raw, gamma, HE, CLAHE, and your engine (hardware output). *[2026-10-28: board output, 50 LOL images, all baselines; docs/results/hw_eval_lol.md]*
- [~] **7.2** **Video quality on synthetic clips:** PSNR/SSIM per frame vs. ground truth, with and without the temporal stage. *[synthetic-clip PSNR/SSIM with and without the temporal stage is in docs/results/ablation_*.md (float model); on hardware only the real-clip noise ablation was run]*
- [~] **7.3** **Noise reduction:** static-patch noise std before and after, as a function of controller gain. Plot it. *[static noise std measured on the board for 3 clips and all stage combinations (hw_eval_ablation.md); the noise-vs-gain curve is not plotted]*
- [x] **7.4** **Flicker and stability:** luma variation over time for scene-change tests. Show the controller step response. *[2026-10-28: lamp-step brightness and gain read back from the board, docs/img/fig_lampstep.png; step response in docs/results/step_response_moderate.md]*
- [~] **7.5** **Ghosting/smear:** quantify around moving objects with motion adaptation on vs. off. *[ghost ratio only in the simulated ablations; not quantified on hardware (visual montage only)]*
- [x] **7.6** **Ablation table:** every stage on/off, and denoise-strength coupling on/off. *[2026-10-28: hardware stage ablation + simulated ablation including noise-coupling on/off]*
- [ ] **7.7** (Optional) **Downstream test:** pretrained detector on raw vs. enhanced frames. *[not done]*
- [ ] **7.8** **ARM baseline:** the same pipeline in C on the HPS (NEON optional). Report fps and CPU load vs. the FPGA's fixed 60 fps. Check that any latency number moves when the DUT speed changes before trusting it. [CL §4.5] *[not done]*
- [~] **7.9** **Resources, Fmax, power:** final Quartus numbers; Power Analyzer estimate (and measured board power if you have a meter). Fmax is reported as measured slack at 25 MHz plus the limit from a one-off higher-clock sweep with its own constraint set confirmed in the tables. *[resources and STA done (README); power estimate and measured power not done]*
- [x] **7.10** Collect plots and logs in `docs/results/` with the scripts that produced them; every measurement script embeds Gates 0/1 and exits non-zero on failure. [S11] *[scripts/evaluate_board.py refuses to report unless the board output is bit-identical to the model]*

**Exit gate:** every number you plan to quote has a script and log behind it.

---

## Phase 8: Documentation and demo (Weeks 13-14)

- [x] **8.1** README: problem, architecture diagram, control loop explanation, build/run steps, results table, limitations. *[2026-10-28: README.md with mermaid diagrams, results, limitations]*
- [x] **8.2** Block diagram and the **control-loop timing diagram** (statistics frame N -> controller during blanking -> applied at frame N+1). *[sequence diagram in README (frame N statistics -> controller in blanking -> applied at frame N+1)]*
- [x] **8.3** Design doc: bit widths, memory map, CSR table, frame-store scheme, clock/reset map. *[docs/csr_map.md, docs/controller.md, docs/streaming.md, docs/board_notes.md; bit widths in docs/results/bitwidth.md]*
- [~] **8.4** Demo video: split-screen raw vs. enhanced, stage toggles live, lights on and off, then the noise-vs-gain plot. *[docs/media/demo_*.gif and .mp4 (side by side, lamp step); no live stage-toggle recording and no noise-vs-gain plot]*
- [ ] **8.5** 3-minute live demo script with a fallback clip. *[not done]*
- [ ] **8.6** Tag a release: `.sof`, compressed `.rbf`, host software built from the same commit, checksums of every generated input, one-command run steps. [S12, S13] *[not done: bitstream and host software are built, but no tagged release or checksum manifest yet]*
- [ ] **8.7** One-page portfolio and resume summary. *[not done]*

---

## Stretch goals (only after Phase 8)

- [ ] **S.1** **Colour pipeline** (enhance luma, adapt chroma saturation and chroma denoising).
- [ ] **S.2** **Live camera input** (ADV7180 composite or D8M camera) so the loop controls real sensor exposure.
- [ ] **S.3** **Optical flow or motion vectors** to make the temporal denoiser motion-compensated.
- [ ] **S.4** **Dehazing** (dark channel prior) as a switchable mode.

---

## Risks and fallbacks

| Risk | Fallback |
|---|---|
| Closed loop oscillates or pumps | Lower loop gain, add hysteresis and a rate limiter, update every N frames |
| Temporal denoiser causes ghosting | Tighten the motion-to-alpha curve, add per-pixel motion-history mask |
| On-chip frame store does not fit or route (M10K > ~85%) | 64 MB FPGA SDRAM for the store, or 320x240 working resolution |
| HPS F2H DMA / Qsys regeneration problems | Phase 3a already gives a complete demo from the on-chip source; fall back to HPS pushing lines over the bridge at reduced rate |
| Quartus optimizer crash on large arithmetic (`aggressive_adder_balancing`) | Keep multipliers small and shared (25 MHz allows time-multiplexing); never use global `OPTIMIZATION_TECHNIQUE AREA` or `AUTO_DSP_RECOGNITION OFF` as a fix without a fresh STA run [CL §2.1] |
| Simulation passes, hardware wrong | Follow the CL §4.4 ladder in order: reproducibility, which bitstream, host/bitstream version, offset sweep, STA, what hardware does that testbenches do not |
| Result looks like generic Retinex/CLAHE | Lead the report with the **ablation of the adaptive coupling** and the control-loop stability results |
| Real night clips are noisy in unexpected ways | Rely on the synthetic generator for quantitative results; use real clips for demos |
| No Ethernet cable / network between board and laptop | Direct cable with static IPs (192.168.7.x); UART is far too slow for video |
| HPS cannot reserve DDR3 or the write DMA misbehaves | Bridge-window readout of the frame store at reduced frame rate; the viewer protocol does not change |
| Board unavailable / not connected | Phases 1, 2, 3a-3b RTL simulation, 4 and 5 are simulation-only and proceed without it |
