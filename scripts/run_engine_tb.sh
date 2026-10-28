#!/usr/bin/env bash
# Build and run the system-level testbench for one exported vector set.
# Usage: scripts/run_engine_tb.sh <set> [rstall%] [wstall%] [burst 0/1] [rerun frames]
set -euo pipefail
cd "$(dirname "$0")/.."
SET="$1"; RS="${2:-0}"; WS="${3:-0}"; BU="${4:-1}"; RR="${5:-2}"
PY=.venv/Scripts/python.exe; M=tb/vec/$SET/meta.json
get() { $PY -c "import json;print(json.load(open('$M'))['$1'])"; }
SRC="rtl/ram_sdp.v rtl/win3x3.v rtl/seq_div.v rtl/rom/rom_gamma.v rtl/rom/rom_log2.v rtl/rom/rom_exp2.v rtl/rom/rom_recip.v rtl/rom/rom_motion.v rtl/nv_hist.v rtl/nv_noise.v rtl/nv_temporal.v rtl/nv_spatial.v rtl/nv_tone.v rtl/nv_sharpen.v rtl/nv_ctrl.v rtl/nv_core.v rtl/vga_timing.v rtl/fifo_64to8.v rtl/dma_rd.v rtl/dma_wr.v rtl/nv_csr.v rtl/nv_engine.v tb/nv_engine_tb.v"
iverilog -g2005 -Wall -P nv_engine_tb.W=$(get W) -P nv_engine_tb.H=$(get H) -P nv_engine_tb.T=$(get T) -P nv_engine_tb.C_SIG=$(get C_SIG) -o work/nv_engine_$SET.vvp $SRC
vvp work/nv_engine_$SET.vvp +vec=tb/vec/$SET +rstall=$RS +wstall=$WS +burst=$BU +rerun=$RR
