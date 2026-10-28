# Bug log

Format (checklist 7.3): Symptom / Root cause / Fix / Lesson. Exact numbers. Record wrong hypotheses too.

### 1. Build script reported success up to `asm`, then `quartus_cpf` failed on a missing .sof

**Symptom:** `scripts/build_quartus.sh` printed `== quartus_asm bringup` and then nothing; `cpf.log`: `File name "output_files/bringup.sof" does not exist`.
**Root cause:** the project had no `PROJECT_OUTPUT_DIRECTORY`, so Quartus wrote `bringup.sof`, `.sta.summary` etc. into the project root while the script looked in `output_files/`. Every Quartus step had succeeded; only the script's assumed paths were wrong.
**Fix:** `set_global_assignment -name PROJECT_OUTPUT_DIRECTORY output_files` in the .qsf; step logs moved to `logs/`.
**Lesson:** a flow script must fail loudly on a missing artefact rather than rely on a later tool to notice (the failure surfaced only because `quartus_cpf` happened to run last). Check the output paths of any new project once by hand.

### 2. (caught before first run) testbench raced on a shared counter between two `always` blocks

**Symptom:** none observed; found on review of the first draft of `tb/test_pattern_tb.v` (frame hash closed in one block using `fcnt`, which a second block incremented with a blocking assignment on the same edge).
**Root cause:** two processes on the same clock edge with a blocking write and a read of the same variable: order is scheduler-dependent (checklist 3.6).
**Fix:** one clocked process owns all testbench state; reads and writes ordered explicitly in the body.
**Lesson:** if a testbench has more than one process touching the same variable, merge them before the first run. The final testbench was then checked by `run_regression.py --selftest`, which injects five RTL faults and requires FAIL on each.

### 3. Motion-to-blend curve never reached 1.0, so a scene cut would leave a ghost

**Symptom:** `test_rom_ranges_and_accuracy` failed: `MOTION_F[63] == 250`, expected 256.
**Root cause:** the curve was specified as `(r - 1.5)/2.5` with `r = u/16`, which reaches 1.0 at `u = 64`, one past the last table entry (the index saturates at 63). Maximum blend factor 0.977, so after a hard cut about 2.3% of the old frame (about 5 grey levels at full contrast) would persist in the frame store for several frames.
**Fix:** curve is now `(u - 24)/39`, exactly 1.0 at `u = 63`; float model uses `r1 = 63/16 = 3.9375` to match. Both golden models re-checked bit-exact (39 tests).
**Lesson:** assert the end points of every lookup table, and check that a saturating index can actually reach the value the maths says it reaches.

### 4. Noise-coupled denoise strengths did not beat the best fixed strengths (resolved, with a modest margin)

**Symptom:** first ablation (`docs/results/ablation_moderate.md`): coupled 17.37 dB / SSIM 0.619 / static noise 1.31; best fixed 17.50 dB / 0.643 / 2.89. Ghost error 1.45x the no-temporal baseline. Sharpening inactive at moderate and harsh noise.
**Root cause (hypothesis, untested):** sigma_t = 3 output levels is more aggressive than the PSNR optimum, so the coupled version trades detail for noise; the 1.5-sigma motion threshold lets small motion through as static.
**Plan:** retune sigma_t, r0, a_floor on the LOL tuning split only, rerun the ablation, and report the result whichever way it goes.

**Resolution:** the first retune grid started at sigma_t = 3 (the grid edge was the optimum, which I did not question), and the real-footage run exposed more defects. After lowering sigma_t to 1.5, raising the blend floor to 1/8 and fixing the black level and highlight clamp (see 5), the coupled design ties for best SSIM in all 6 regimes of `docs/results/adaptivity_*.md` and is within 0.16 dB PSNR of the best everywhere. A single fixed setting cannot do that (best fixed loses up to 0.06 SSIM, heavy fixed loses on clean footage). Margin over a tuned fixed compromise is small and is reported as such.
**Lesson:** when the best value of a tuned constant sits on the edge of the grid, extend the grid before concluding anything.

### 5. Real footage exposed three defects invisible on synthetic clips

**Symptom:** on the recorded dim-room clip, hard black patches in dark detail; on the lamp-step clip, gain stuck at 1.0 and output mean 68-120 (target 128) whenever the lamp was in frame.
**Root cause:** (a) black level was the frame's 1st percentile, which crushes real detail when the footage is clean; (b) the highlight clamp used the 99th percentile, so a saturated lamp covering more than 1% of the frame protected pixels that were already clipped; (c) gamma 0.4 has unbounded slope at zero, so neighbouring dark 8-bit codes land far apart (banding).
**Fix:** (a) black level <= round(sigma estimate); (b) clamp on the 95th percentile; (c) optional linear toe implemented (`roms.TOE`), disabled by default because it cost 0.7 dB on LOL with no demonstrated benefit. LOL held-out PSNR unchanged by (a) and (b) (21.08 vs 21.10 dB); real clips now keep the detail and the lamp-step output mean is 108-138.
**Lesson:** synthetic data cannot stand in for the real input. Run the real clips as soon as they exist, before freezing constants.

### 6. Two always blocks drove the same registers: Icarus accepted it, Quartus rejected it

**Symptom:** the first Quartus run of the 640x480 core failed in `quartus_map`: `Error (10028): Can't resolve multiple constant drivers for net "gen_active"` (and `gen_i[10:0]`) in `nv_ctrl.v`. Every simulation (core, controller, system) passed.
**Root cause:** the LUT-generation pipeline block and the main FSM block both assigned `gen_active`/`gen_i`. Verilog simulators let the last writer win; synthesis does not.
**Fix:** one driver per register: the FSM only pulses `gen_start`; the pipeline block owns `gen_active` and `gen_i`. Re-simulated (bit-exact) and re-synthesised: 2,323 ALMs, 17 DSP, 56% block memory, setup slack +25.0 ns at 25 MHz.
**Lesson:** run `quartus_map` on every new multi-block module right after its first passing simulation (checklist 1.9, 4-minute probe), not after the whole system exists.

### 7. A fresh `qsys-generate` does not just drop qip lines, it omits the files

**Symptom:** after generating the night-vision system into an empty directory the five hard-IP files named in CFAR bug #19/#21 were missing on disk, not only missing from `soc_system.qip` (the CFAR directory still held them from an earlier, further-progressing generation, which is why copying lines was enough there).
**Root cause:** the DDR3 sequencer step crashes, and generation stops before writing `altera_mem_if_{hard_memory_controller_top,oct,dll}_cyclonev.sv` and the two interconnect error adapters.
**Fix:** checked-in reference copies in `quartus/soc/ref/submodules/` (provenance, checklist 7.1), used only after verifying that the adapter wrappers are byte-identical to the working system and that the adapters are fixed-width pass-throughs (34 and 258 bits); `scripts/patch_qip.py` restores files and lines, idempotently, and `scripts/build_soc.sh` runs it every time.
**Lesson:** re-check the assumption behind a recurring workaround whenever its preconditions change (fresh directory vs. leftover files).

### 8. Fault injection found five blind spots in otherwise passing test suites

Injecting 40+ single-point faults into the new RTL showed vector sets that passed with first-time 100% results were not exercising: exact deadband edges, the black-level clamp at 16, LUT-index rounding ties, coring rounding ties, the headroom floor in very dark scenes, and the `frame_reset` counter clear (a stale `IN_RD_SEQ` happened to land on the right slot because 8 frames = 2 x 4 slots). Fixes: a controller-only testbench driven by random and directed statistics (including an 8,000-case soak), new regimes (ultra-dark, clean-noise stretch), odd frame sizes, and post-reset counter checks. Two mutants were proven equivalent (cannot change any output) and replaced. See `scripts/run_regression.py --selftest`.
**Lesson:** a first-time pass is evidence about the testbench only after it has failed on a known-bad design.

### 9. The first SoC build passed STA with the DDR3 sequencer ROMs initialised to zero

**Symptom:** `build_soc.sh` finished green (fit OK, STA PASS, 3.3 MB compressed rbf) but the Quartus log held critical warning 127003: "Can't find Memory Initialization File hps_inst_ROM.hex / hps_AC_ROM.hex -- setting all initial values to 0" (in `hps_sdram_p0_acv_hard_memphy.v`).
**Root cause:** the same crashed generation step that drops the hard-IP files (bug 7) never wrote the two sequencer ROM images, and `patch_qip.py` ignored their qip lines because the target files did not exist ("reference files no longer generated"). Timing analysis cannot notice zero-filled memory; on the board this would show up as failed DDR3 calibration.
**Fix:** copies of the two files from the proven GHRD generation are in `quartus/soc/ref/submodules/` and `patch_qip.py` restores them with their `SOURCE_FILE` lines. Checked first that `hps_sdram*.v/sv` and `hps_sdram_p0_acv_hard_memphy.v` are byte-identical to the proven system, so the DDR3 parameters (and therefore the ROM contents) are the same. Rebuilt.
**Lesson:** a green build is not proof; read the critical warnings of every build and compare them with the last known-good build. `build_soc.sh` should fail on warning 127003 (added).

### 10. HPS-to-FPGA works but every F2H SDRAM access hangs: the SD-card preloader leaves the ports in reset

**Symptom:** CSR block answered (Gate C passed) but the first frame never came back. `IN_RD_SEQ` advanced (the scheduler runs on its own pacing), `OUT_SEQ` stayed 0, sticky underrun and write-overflow flags set, telemetry all zero. Marker words (0xFFFFFFFF) planted in the output ring were never overwritten, so no write reached DDR3; the old data seen there earlier was stale from a previous design.
**Root cause:** `fpgaportrst` (SDR controller 0xFFC25080) read 0: all FPGA-to-SDRAM ports held in reset. The preloader/u-boot on the card was built for the older CFAR design and did not release them (its other port mapping registers already matched the same `hps.xml`, which is byte-identical to the proven one). The bitstream and RTL were fine; STA cannot see this.
**Fix:** writing 0x3FFF to 0xFFC25080 from Linux; `sw/nv_streamer.c` now does it at start-up and prints the before/after value. The permanent fix is a preloader/u-boot rebuilt from `quartus/soc/hps_isw_handoff` (not done: needs SoC EDS).
**Lesson:** when a hardware master "does nothing", look at the HPS side (reset registers) before the RTL; and a marker pattern in the destination memory distinguishes 'wrote the wrong thing' from 'never wrote'.
