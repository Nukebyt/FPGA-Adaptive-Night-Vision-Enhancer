#!/usr/bin/env bash
# Regenerates quartus/pins/de10_nv_pins.tcl from the Terasic DE10-Standard golden top.
# Usage: scripts/gen_pins.sh [path/to/platform_setup.tcl]
# Then cross-checks the shared groups against the proven-on-hardware board_check pin list.
set -euo pipefail
cd "$(dirname "$0")/.."

REF_DIR="C:/Users/priya/OneDrive/Desktop/slop/projects/Matlab_projects/Weibull_CFAR/matlab"
SRC="${1:-$REF_DIR/d10_standard_golden_top/extracted/platform_setup.tcl}"
OUT=quartus/pins/de10_nv_pins.tcl

{
cat <<'EOF'
# DE10-Standard pin + IO-standard assignments for the Adaptive Night-Vision design.
# Source of truth: Terasic DE10_Standard_Golden_Top (platform_setup.tcl, ACDS 17.0),
#   extracted copy at <Weibull_CFAR>/matlab/d10_standard_golden_top/extracted/.
# Only the groups this design uses are copied. HPS pins/DDR3 are NOT here: they come
# from the Platform Designer HPS component (hps_isw_handoff + the GHRD board-info).
# Regenerate with scripts/gen_pins.sh -- do not hand-edit, so the file stays diffable
# against the golden top.
# Note: SW[*] is "2.5 V" and CLOCK3_50 is "2.5 V" in the golden top; the rest are 3.3-V LVTTL.
EOF
grep -E "^set_(location|instance)_assignment .* -to (CLOCK_50|KEY\[[0-3]\]|SW\[[0-9]\]|LEDR\[[0-9]\]|HEX[0-5]\[[0-6]\]|VGA_[A-Z_]+(\[[0-7]\])?)\s*$" "$SRC"
} > "$OUT"

echo "location assignments: $(grep -c location_assignment "$OUT")  (expect 96)"
echo "IO standards:         $(grep -c IO_STANDARD "$OUT")  (expect 96)"

BC="$REF_DIR/board_check/pins.qsf.inc"
if [ -f "$BC" ]; then
  diff <(grep -E "location_assignment.*(CLOCK_50|LEDR|HEX)" "$OUT" | sort) \
       <(grep -E "location_assignment" "$BC" | sort) \
    && echo "cross-check vs board_check (CLOCK_50/LEDR/HEX): identical"
fi
