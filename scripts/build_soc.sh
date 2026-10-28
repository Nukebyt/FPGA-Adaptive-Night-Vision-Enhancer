#!/usr/bin/env bash
# Full build of the DE10-Standard night-vision SoC (HPS + DDR3 + nv_engine). Usage: scripts/build_soc.sh [--generate]
#   --generate  also (re)runs qsys-generate first (about 15 minutes; its DDR3 sequencer step is KNOWN to crash on this machine,
#               scripts/patch_qip.py then restores the five qip lines it dropped, see docs/bug_log.md)
# Order follows the proven GHRD Makefile: map -> cdb --merge -> hps_sdram_p0_pin_assignments.tcl -> full compile -> compressed rbf.
# Checklist: S1 (sta every build; the 25 MHz PLL clock, CLOCK_50 and the DDR3 clocks must APPEAR in the slack tables), 2.4 (rbf
# compression ON, size compared with the last good one).
set -euo pipefail
export PATH="/c/intelFPGA_lite/21.1/quartus/sopc_builder/bin:/c/intelFPGA_lite/21.1/quartus/bin64:$PATH"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT/quartus/soc"
PRJ=DE10_Standard_NV
mkdir -p logs output_files
if [ "${1:-}" = "--generate" ]; then
  echo "== qsys-generate (the sequencer step is expected to report an error)"
  qsys-generate soc_system.qsys --synthesis=VERILOG > logs/qsys_generate.log 2>&1 || echo "   qsys-generate returned non-zero (expected on this machine)"
fi
echo "== patch_qip"
"$ROOT/.venv/Scripts/python.exe" "$ROOT/scripts/patch_qip.py" soc_system/synthesis/soc_system.qip
echo "== quartus_map";  quartus_map $PRJ > logs/map.log 2>&1 || { tail -25 logs/map.log; exit 1; }
echo "== quartus_cdb --merge"; quartus_cdb --merge $PRJ > logs/merge.log 2>&1 || { tail -25 logs/merge.log; exit 1; }
for t in soc_system/synthesis/submodules/*_pin_assignments.tcl; do
  echo "== pin assignments: $t"; quartus_sta -t "$t" $PRJ > logs/pin_assign.log 2>&1 || { tail -25 logs/pin_assign.log; exit 1; }
done
echo "== quartus_sh --flow compile (map, fit, sta, asm)"
quartus_sh --flow compile $PRJ > logs/compile.log 2>&1 || { grep -E "^Error" logs/compile.log | head -20; exit 1; }
if grep -q "127003" logs/compile.log logs/map.log; then echo "FAIL: memory init file missing (warning 127003), see docs/bug_log.md #9"; grep -h 127003 logs/compile.log logs/map.log | head -3; exit 1; fi
echo "== compressed rbf"
quartus_cpf -c -o bitstream_compression=on output_files/$PRJ.sof output_files/$PRJ.rbf > logs/cpf.log 2>&1
ls -l output_files/$PRJ.sof output_files/$PRJ.rbf
"$ROOT/.venv/Scripts/python.exe" "$ROOT/scripts/check_sta.py" output_files/$PRJ.sta.summary CLOCK_50 divclk hps_sdram
