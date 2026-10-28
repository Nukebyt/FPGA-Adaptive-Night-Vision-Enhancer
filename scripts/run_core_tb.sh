#!/usr/bin/env bash
# Build and run nv_core_tb for one exported vector set. Usage: scripts/run_core_tb.sh <set> [gap_pct] [fgap]
set -euo pipefail
cd "$(dirname "$0")/.."
SET="$1"; GAP="${2:-0}"; FGAP="${3:-8192}"
PY=.venv/Scripts/python.exe
SRC="rtl/ram_sdp.v rtl/win3x3.v rtl/seq_div.v rtl/rom/rom_gamma.v rtl/rom/rom_log2.v rtl/rom/rom_exp2.v rtl/rom/rom_recip.v rtl/rom/rom_motion.v rtl/nv_hist.v rtl/nv_noise.v rtl/nv_temporal.v rtl/nv_spatial.v rtl/nv_tone.v rtl/nv_sharpen.v rtl/nv_ctrl.v rtl/nv_core.v tb/nv_core_tb.v"
M=tb/vec/$SET/meta.json
get() { $PY -c "import json;print(json.load(open('$M'))['$1'])"; }
iverilog -g2005 -Wall -P nv_core_tb.W=$(get W) -P nv_core_tb.H=$(get H) -P nv_core_tb.T=$(get T) -P nv_core_tb.C_SIG=$(get C_SIG) -o work/nv_core_$SET.vvp $SRC
vvp work/nv_core_$SET.vvp +vec=tb/vec/$SET +gap=$GAP +fgap=$FGAP
