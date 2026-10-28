"""Regression runner: Icarus testbenches + Python unit tests. Plain ASCII on purpose (checklist 3.9).

Verdict rules
  * A testbench passes only if its output contains a line "RESULT: PASS" and no "RESULT: FAIL",
    no "MISMATCH" and no "FAIL" line. Compile error, non-zero exit, timeout or NO verdict line == FAIL.
  * Exit code of the simulator is never used as the pass signal ($error/$display do not set it).
  * --selftest re-runs the testbenches against deliberately broken copies of the RTL and requires FAIL.
    Run it every time this script or a testbench changes.

Usage:  python scripts/run_regression.py [--selftest] [--skip-python]
"""
import argparse
import json
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
IVERILOG = os.environ.get("IVERILOG", "iverilog")
VVP = os.environ.get("VVP", "vvp")

# name -> (rtl sources, testbench)
# the optional 3rd element is a list of vvp argument sets: the testbench runs once per set (gap sweeps, checklist 1.7)
TESTS = {
    "vga_timing_tb": (["rtl/vga_timing.v"], "tb/vga_timing_tb.v"),
    "test_pattern_tb": (["rtl/vga_timing.v", "rtl/test_pattern.v"], "tb/test_pattern_tb.v"),
    "win3x3_tb": (["rtl/ram_sdp.v", "rtl/win3x3.v"], "tb/win3x3_tb.v", [["+gap=0"], ["+gap=30"], ["+gap=70"]]),
}

CORE_SRCS = ["rtl/ram_sdp.v", "rtl/win3x3.v", "rtl/seq_div.v", "rtl/rom/rom_gamma.v", "rtl/rom/rom_log2.v", "rtl/rom/rom_exp2.v",
             "rtl/rom/rom_recip.v", "rtl/rom/rom_motion.v", "rtl/nv_hist.v", "rtl/nv_noise.v", "rtl/nv_temporal.v",
             "rtl/nv_spatial.v", "rtl/nv_tone.v", "rtl/nv_sharpen.v", "rtl/nv_ctrl.v", "rtl/nv_core.v"]
CORE_RUNS = [("small_nat", 0), ("small_nat", 60), ("small_step", 40), ("small_rand", 80), ("small_ext", 0)]   # (vector set, gap %)
ENGINE_SRCS = CORE_SRCS[:-1] + ["rtl/vga_timing.v", "rtl/fifo_64to8.v", "rtl/dma_rd.v", "rtl/dma_wr.v", "rtl/nv_csr.v", "rtl/nv_engine.v", "rtl/nv_core.v"]
ENGINE_RUNS = [("small_nat", 0, 0, 1, 2), ("small_nat", 60, 60, 0, 2), ("small_step", 20, 20, 1, 3), ("small_rand", 50, 30, 1, 2),
               ("small_ext", 10, 70, 0, 2)]   # (vector set, read stall %, write stall %, burst, frames re-run after FRAME_RESET)
ENGINE_QUICK = [("small_nat", 30, 40, 1, 2), ("small_step", 20, 20, 1, 3)]
CTRL_SRCS = ["rtl/seq_div.v", "rtl/rom/rom_gamma.v", "rtl/rom/rom_log2.v", "rtl/rom/rom_exp2.v", "rtl/nv_ctrl.v"]
CTRL_RUNS = ["ctrl_small", "ctrl_full"]
CTRL_SOAK = ["ctrl_soak"]          # 8000 cases: run with --soak (slow); needed to hit rounding ties such as the coring (+2048) one
CTRL_QUICK = ["ctrl_small"]
CORE_QUICK = [("small_nat", 0), ("small_ext", 0)]                                                         # used for fault injection

# (file, old text, new text, testbench that must catch it)
MUTATIONS = [
    ("rtl/test_pattern.v", "18'd102", "18'd103", "test_pattern_tb"),
    ("rtl/test_pattern.v", "BLOCK_STEP = 4", "BLOCK_STEP = 5", "test_pattern_tb"),
    ("rtl/test_pattern.v", "32'h8020_0003", "32'h8020_0007", "test_pattern_tb"),
    ("rtl/vga_timing.v", "H_SYNC   = 96", "H_SYNC   = 95", "vga_timing_tb"),
    ("rtl/vga_timing.v", "V_ACTIVE = 480", "V_ACTIVE = 479", "vga_timing_tb"),
    ("rtl/win3x3.v", "wire [DW-1:0] r_t = lc ? b_t : n_t,", "wire [DW-1:0] r_t = lc ? n_t : n_t,", "win3x3_tb"),
    ("rtl/win3x3.v", "wire fr = (oy == 0);", "wire fr = (oy == 1);", "win3x3_tb"),
    ("rtl/win3x3.v", "if (warm_cnt == W) warm <= 1'b1;", "if (warm_cnt == W - 1) warm <= 1'b1;", "win3x3_tb"),
    ("rtl/win3x3.v", "wire [CW-1:0] raddr    = en ? col_next : col;", "wire [CW-1:0] raddr    = col;", "win3x3_tb"),
    ("rtl/nv_temporal.v", "s2b_sad <= s2a_a + s2a_b + s2a_c;", "s2b_sad <= s2a_a + s2a_b;", "nv_core"),
    ("rtl/nv_temporal.v", "(s5_prod + 18'd128) >> 8", "(s5_prod + 18'd127) >> 8", "nv_core"),
    ("rtl/nv_spatial.v", "sel_f = ({2'b00, d} <= th);", "sel_f = ({2'b00, d} < th);", "nv_core"),
    ("rtl/nv_spatial.v", "(s6_m + 17'sd8) >>> 4", "(s6_m + 17'sd7) >>> 4", "nv_core"),
    ("rtl/nv_sharpen.v", "12'd1820", "12'd1819", "nv_core"),
    ("rtl/nv_sharpen.v", "(s6_p + 20'sd128) >>> 8", "(s6_p + 20'sd127) >>> 8", "nv_core"),
    ("rtl/nv_ctrl.v", "RL_UP     = 24'sd1182", "RL_UP     = 24'sd1183", "nv_core"),
    ("rtl/nv_ctrl.v", "DEADBAND  = 24'sd295", "DEADBAND  = 24'sd293", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "(sigma_b < 20'd16)           ? sigma_b[4:0] : 5'd16;", "(sigma_b < 20'd16)           ? sigma_b[4:0] : 5'd15;", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "gprod1 <= gd0 * $signed({1'b0, gl});", "gprod1 <= gd0 * $signed({1'b0, gl}) + 1;", "nv_ctrl"),
    ("rtl/nv_noise.v", "$signed({4'b0000, s1_c, 2'b00})", "$signed({5'b00000, s1_c, 1'b0})", "nv_core"),
    ("rtl/nv_hist.v", "wire [18:0] base = (v_prev && (a_prev == a1)) ? n_prev : rdata;", "wire [18:0] base = rdata;", "nv_core"),
    ("rtl/nv_core.v", "use_prev <= have_prev & en_temporal;", "use_prev <= en_temporal;", "nv_core"),
    ("rtl/nv_tone.v", "if (v_sof) acc <= {24'd0, v_data};", "if (v_sof) acc <= acc;", "nv_core"),
    ("rtl/nv_ctrl.v", "(gprod1 + 33'sd2048) >>> 12", "(gprod1 + 33'sd2047) >>> 12", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "div_num <= nq + 24;", "div_num <= nq + 23;", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "* 16 + 1536;", "* 16 + 1535;", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "(nq * sq_s + 2048) >> 12", "(nq * sq_s + 2047) >> 12", "nv_ctrl_soak"),
    ("rtl/nv_ctrl.v", "(sig_eff * 9) >> 1", "(sig_eff * 9) >> 2", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "(sig_eff * 20 + 256) >> 9;", "(sig_eff * 20 + 255) >> 9;", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "(NPIX * 95 + 99) / 100", "(NPIX * 95 + 50) / 100", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "(($signed({1'b0, sf}) - $signed({12'b0, sigma}))) >>> 2", "(($signed({1'b0, sf}) - $signed({12'b0, sigma}))) >>> 1", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "({24'd0, p95} - {27'd0, b}) : 32'd8;", "({24'd0, p95} - {27'd0, b}) : 32'd9;", "nv_ctrl"),
    ("rtl/nv_ctrl.v", "lut_wdata <= passthru ? gi3[9:2] : gam_rd;", "lut_wdata <= passthru ? gi3[8:1] : gam_rd;", "nv_ctrl"),
    ("rtl/dma_rd.v", "addr <= addr + 32'd8; issued", "addr <= addr + 32'd16; issued", "nv_engine"),
    ("rtl/dma_wr.v", "waddr <= waddr + 32'd8; end", "waddr <= waddr + 32'd16; end", "nv_engine"),
    ("rtl/dma_wr.v", "({56'd0, in_data} << {pk_cnt, 3'b000})", "({56'd0, in_data} << {3'b000, pk_cnt})", "nv_engine"),
    ("rtl/fifo_64to8.v", "if (bcnt == 3'd7) begin", "if (bcnt == 3'd6) begin", "nv_engine"),
    ("rtl/nv_csr.v", "8'd8:  reg_q <= out_seq;", "8'd8:  reg_q <= in_rd_seq;", "nv_engine"),
    ("rtl/nv_csr.v", "sel_ram_q <= (avs_address[7:6] == 2'b01);", "sel_ram_q <= (avs_address[7:6] == 2'b10);", "nv_engine"),
    ("rtl/nv_engine.v", "if (c_enable && core_ready && (c_in_wr_seq != in_rd_seq)) begin", "if (c_enable && core_ready && (c_in_wr_seq == in_rd_seq)) begin", "nv_engine"),
    ("rtl/nv_engine.v", "s_lg <= t_lg;", "s_lg <= t_sigma;", "nv_engine"),
    ("rtl/nv_engine.v", "if (in_valid && f_empty) st_underrun <= 1'b1;", "if (in_valid) st_underrun <= 1'b1;", "nv_engine"),
    ("rtl/nv_engine.v", "base(c_out_base + {out_seq[1:0], 19'd0})", "base(c_out_base + {out_seq[0], 20'd0})", "nv_engine"),
    ("rtl/nv_engine.v", "go <= 1'b0; pre_start <= 1'b0; in_rd_seq <= 32'd0;", "go <= 1'b0; pre_start <= 1'b0; in_rd_seq <= in_rd_seq;", "nv_engine"),
]


def verdict(text):
    lines = text.splitlines()
    has_pass = any(re.match(r"\s*RESULT:\s*PASS", l) for l in lines)
    bad = any(re.match(r"\s*RESULT:\s*FAIL", l) or "MISMATCH" in l or re.match(r"\s*FAIL", l) for l in lines)
    return has_pass and not bad


def run_tb(name, base):
    srcs, tb = TESTS[name][0], TESTS[name][1]
    argsets = TESTS[name][2] if len(TESTS[name]) > 2 else [[]]
    out = ROOT / "work" / (base + "_" + name + ".vvp")
    out.parent.mkdir(exist_ok=True)
    cmd = [IVERILOG, "-g2005", "-Wall", "-o", str(out)] + [str(base_dir(base) / s) for s in srcs] + [str(ROOT / tb)]
    c = subprocess.run(cmd, capture_output=True, text=True)
    if c.returncode != 0:
        return False, "COMPILE ERROR\n" + c.stdout + c.stderr
    try:
        r = subprocess.run([VVP, str(out)], capture_output=True, text=True, timeout=600)
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    text = r.stdout + r.stderr
    if "timescale" in c.stderr:
        text += "\n(warning: mixed timescale in compile)"
    return verdict(text), text


def run_core(base, vset, gap):
    """Compile nv_core_tb against the sources of `base` and run it on one exported vector set."""
    meta = json.load(open(ROOT / "tb" / "vec" / vset / "meta.json"))
    out = ROOT / "work" / (base + "_core_" + vset + ".vvp")
    out.parent.mkdir(exist_ok=True)
    cmd = [IVERILOG, "-g2005", "-Wall", "-P", "nv_core_tb.W=%d" % meta["W"], "-P", "nv_core_tb.H=%d" % meta["H"],
           "-P", "nv_core_tb.T=%d" % meta["T"], "-P", "nv_core_tb.C_SIG=%d" % meta["C_SIG"], "-o", str(out)]
    cmd += [str(base_dir(base) / f) for f in CORE_SRCS] + [str(ROOT / "tb" / "nv_core_tb.v")]
    c = subprocess.run(cmd, capture_output=True, text=True)
    if c.returncode != 0:
        return False, "COMPILE ERROR\n" + c.stdout + c.stderr
    try:
        r = subprocess.run([VVP, str(out), "+vec=" + str(ROOT / "tb" / "vec" / vset), "+gap=%d" % gap],
                           capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    text = r.stdout + r.stderr
    return verdict(text), text


def run_engine(base, vset, rs, ws, burst, rerun):
    """System-level testbench (nv_engine_tb): HPS-software emulation around nv_engine, memory model with stalls."""
    meta = json.load(open(ROOT / "tb" / "vec" / vset / "meta.json"))
    out = ROOT / "work" / (base + "_engine_" + vset + ".vvp")
    cmd = [IVERILOG, "-g2005", "-Wall", "-P", "nv_engine_tb.W=%d" % meta["W"], "-P", "nv_engine_tb.H=%d" % meta["H"],
           "-P", "nv_engine_tb.T=%d" % meta["T"], "-P", "nv_engine_tb.C_SIG=%d" % meta["C_SIG"], "-o", str(out)]
    srcs = [f for f in dict.fromkeys(ENGINE_SRCS)]
    cmd += [str(base_dir(base) / f) for f in srcs] + [str(ROOT / "tb" / "nv_engine_tb.v")]
    c = subprocess.run(cmd, capture_output=True, text=True)
    if c.returncode != 0:
        return False, "COMPILE ERROR" + chr(10) + c.stdout + c.stderr
    try:
        r = subprocess.run([VVP, str(out), "+vec=" + str(ROOT / "tb" / "vec" / vset), "+rstall=%d" % rs, "+wstall=%d" % ws,
                            "+burst=%d" % burst, "+rerun=%d" % rerun], capture_output=True, text=True, timeout=3600)
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    text = r.stdout + r.stderr
    return verdict(text), text


def run_ctrl(base, vset):
    """Compile nv_ctrl_tb against the sources of `base` and run it on one controller vector set."""
    meta = json.load(open(ROOT / "tb" / "vec" / vset / "meta.json"))
    out = ROOT / "work" / (base + "_ctrl_" + vset + ".vvp")
    cmd = [IVERILOG, "-g2005", "-Wall", "-P", "nv_ctrl_tb.W=%d" % meta["W"], "-P", "nv_ctrl_tb.H=%d" % meta["H"],
           "-P", "nv_ctrl_tb.N=%d" % meta["N"], "-P", "nv_ctrl_tb.C_SIG=%d" % meta["C_SIG"], "-o", str(out)]
    cmd += [str(base_dir(base) / f) for f in CTRL_SRCS] + [str(ROOT / "tb" / "nv_ctrl_tb.v")]
    c = subprocess.run(cmd, capture_output=True, text=True)
    if c.returncode != 0:
        return False, "COMPILE ERROR" + chr(10) + c.stdout + c.stderr
    try:
        r = subprocess.run([VVP, str(out), "+vec=" + str(ROOT / "tb" / "vec" / vset)], capture_output=True, text=True, timeout=1800)
    except subprocess.TimeoutExpired:
        return False, "TIMEOUT"
    text = r.stdout + r.stderr
    return verdict(text), text


def ensure_vectors():
    py = ROOT / ".venv" / "Scripts" / "python.exe"
    exe = str(py) if py.exists() else sys.executable
    for name in ("small_nat", "small_step", "small_rand", "small_ext"):
        if not (ROOT / "tb" / "vec" / name / "meta.json").exists():
            subprocess.run([exe, "-I", str(ROOT / "scripts" / "export_vectors.py"), name], check=True)
    for name in CTRL_RUNS + CTRL_SOAK:
        if not (ROOT / "tb" / "vec" / name / "meta.json").exists():
            subprocess.run([exe, "-I", str(ROOT / "scripts" / "export_ctrl_vectors.py"), name], check=True)


_BASES = {"real": ROOT}


def base_dir(base):
    return _BASES[base]


def run_all(skip_python, soak=False):
    ok = True
    for name in TESTS:
        passed, text = run_tb(name, "real")
        last = [l for l in text.splitlines() if l.strip().startswith("RESULT")]
        print(("PASS  " if passed else "FAIL  ") + name + "   " + (last[-1].strip() if last else "(no verdict line)"))
        if not passed:
            ok = False
            print(text[-2000:])
    ensure_vectors()
    for vset, gap in CORE_RUNS:
        passed, text = run_core("real", vset, gap)
        last = [l for l in text.splitlines() if l.strip().startswith("RESULT")]
        print(("PASS  " if passed else "FAIL  ") + "nv_core_tb %-10s gap %2d%%   " % (vset, gap) + (last[-1].strip() if last else "(no verdict line)"))
        if not passed:
            ok = False
            print(text[-2000:])
    for vset, rs, ws, bu, rr in ENGINE_RUNS:
        passed, text = run_engine("real", vset, rs, ws, bu, rr)
        last = [l for l in text.splitlines() if l.strip().startswith("RESULT")]
        print(("PASS  " if passed else "FAIL  ") + "nv_engine_tb %-10s rd%2d%% wr%2d%% " % (vset, rs, ws) + (last[-1].strip() if last else "(no verdict line)"))
        if not passed:
            ok = False
            print(text[-2000:])
    for vset in CTRL_RUNS + (CTRL_SOAK if soak else []):
        passed, text = run_ctrl("real", vset)
        last = [l for l in text.splitlines() if l.strip().startswith("RESULT")]
        print(("PASS  " if passed else "FAIL  ") + "nv_ctrl_tb %-10s            " % vset + (last[-1].strip() if last else "(no verdict line)"))
        if not passed:
            ok = False
            print(text[-2000:])
    if not skip_python:
        py = ROOT / ".venv" / "Scripts" / "python.exe"
        exe = str(py) if py.exists() else sys.executable
        r = subprocess.run([exe, "-m", "pytest", "-q"], cwd=ROOT, capture_output=True, text=True)
        tail = (r.stdout.strip().splitlines() or ["(no output)"])[-1]
        passed = r.returncode == 0 and " passed" in tail and "failed" not in tail and "error" not in tail
        print(("PASS  " if passed else "FAIL  ") + "pytest   " + tail)
        if not passed:
            ok = False
            print(r.stdout[-2000:])
    return ok


def selftest(only=None):
    print("selftest: regression must report FAIL for every broken RTL variant")
    all_caught = True
    for i, (rel, old, new, tbname) in enumerate(MUTATIONS):
        if only and tbname != only:
            continue
        mdir = ROOT / "work" / ("mut%d" % i)
        if mdir.exists():
            shutil.rmtree(mdir)
        shutil.copytree(ROOT / "rtl", mdir / "rtl", ignore=shutil.ignore_patterns("*.hex"))
        p = mdir / rel
        src = p.read_text()
        if old not in src:
            print("  SELFTEST ERROR: mutation pattern not found: %s in %s" % (old, rel))
            all_caught = False
            continue
        p.write_text(src.replace(old, new, 1))
        _BASES["mut%d" % i] = mdir
        if tbname == "nv_core":
            passed = all(run_core("mut%d" % i, vs, g)[0] for vs, g in CORE_QUICK)
        elif tbname == "nv_ctrl":
            passed = all(run_ctrl("mut%d" % i, vs)[0] for vs in CTRL_QUICK)
        elif tbname == "nv_engine":
            passed = all(run_engine("mut%d" % i, *args)[0] for args in ENGINE_QUICK)
        elif tbname == "nv_ctrl_soak":
            passed = all(run_ctrl("mut%d" % i, vs)[0] for vs in CTRL_SOAK)
        else:
            passed, _ = run_tb(tbname, "mut%d" % i)
        caught = not passed
        print("  %s  %s: %s -> %s  (%s)" % ("CAUGHT" if caught else "MISSED", rel, old, new, tbname))
        all_caught = all_caught and caught
    # also: a testbench that prints nothing must be FAIL
    assert verdict("") is False and verdict("hello") is False and verdict("RESULT: PASS\nMISMATCH x") is False
    print("  verdict(): empty / no-verdict / PASS+MISMATCH -> FAIL ok")
    return all_caught


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--selftest", action="store_true")
    ap.add_argument("--skip-python", action="store_true")
    ap.add_argument("--soak", action="store_true", help="also run the long controller soak vectors")
    ap.add_argument("--mutate-only", help="run only the fault injections aimed at this testbench (win3x3_tb, nv_core, nv_ctrl, ...)")
    a = ap.parse_args()
    ok = True if a.mutate_only else run_all(a.skip_python, a.soak)
    if a.selftest or a.mutate_only:
        ok = selftest(a.mutate_only) and ok
    print("OVERALL: " + ("PASS" if ok else "FAIL"))
    sys.exit(0 if ok else 1)


if __name__ == "__main__":
    main()
