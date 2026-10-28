#!/usr/bin/env bash
# Build and run nv_ctrl_tb on one controller vector set. Usage: scripts/run_ctrl_tb.sh <ctrl_small|ctrl_full>
set -euo pipefail
cd "$(dirname "$0")/.."
SET="$1"; PY=.venv/Scripts/python.exe; M=tb/vec/$SET/meta.json
get() { $PY -c "import json;print(json.load(open('$M'))['$1'])"; }
iverilog -g2005 -Wall -P nv_ctrl_tb.W=$(get W) -P nv_ctrl_tb.H=$(get H) -P nv_ctrl_tb.N=$(get N) -P nv_ctrl_tb.C_SIG=$(get C_SIG) \
  -o work/nv_ctrl_$SET.vvp rtl/seq_div.v rtl/rom/rom_gamma.v rtl/rom/rom_log2.v rtl/rom/rom_exp2.v rtl/nv_ctrl.v tb/nv_ctrl_tb.v
vvp work/nv_ctrl_$SET.vvp +vec=tb/vec/$SET
