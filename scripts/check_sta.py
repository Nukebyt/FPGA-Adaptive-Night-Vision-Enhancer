"""Fail unless STA is clean AND the clocks we care about actually appear in the slack tables.
Usage: check_sta.py <file.sta.summary> [required_clock_substring ...]
Checklist 0.6 / 2.2: a clean exit code does not prove a PLL domain was analysed.
"""
import re
import sys

path, required = sys.argv[1], sys.argv[2:]
text = open(path).read()
entries = re.findall(r"Type\s*:\s*(.+?)\s*'(.+?)'\s*\nSlack\s*:\s*(-?[\d.]+)\s*\nTNS\s*:\s*(-?[\d.]+)", text)
if not entries:
    print("FAIL: no slack entries parsed from", path)
    sys.exit(1)
ok = True
clocks = sorted({e[1] for e in entries})
print("clocks in slack tables:", clocks)
for typ, clk, slack, tns in entries:
    bad = float(slack) < 0 or float(tns) < 0
    if "Setup" in typ or "Hold" in typ:
        print("%-5s %-40s %-26s slack %8s  TNS %8s" % ("BAD" if bad else "ok", clk[:40], typ, slack, tns))
        ok = ok and not bad
for r in required:
    if not any(r in c for c in clocks):
        print("FAIL: required clock '%s' never appears in the slack tables (unconstrained?)" % r)
        ok = False
worst = [e for e in entries if "Slow 1100mV 85C Model Setup" in e[0]]
if not worst:
    print("FAIL: slow 1100mV 85C setup entry missing")
    ok = False
print("STA:", "PASS" if ok else "FAIL")
sys.exit(0 if ok else 1)
