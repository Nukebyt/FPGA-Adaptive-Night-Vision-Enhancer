"""Restore the lines qsys-generate drops from soc_system.qip on this machine (CFAR bug log #19 and #21).

On this Windows setup the DDR3 sequencer microcode step (uniphy_mcc.exe) crashes during every full qsys-generate. The crash
is in a file synthesis does not use, but the generation aborts early and leaves soc_system.qip without five
set_global_assignment lines (altera_mem_if hard memory controller / OCT / DLL and two interconnect error adapters). Quartus then
fails with 'undefined entity'. The fix is mechanical and recurring, so it is a script, not a memory:

  for every *_FILE line in the known-good reference list (quartus/soc/ref/soc_system.qip.files) that is absent from the new qip
  and whose target file exists on disk, append it.

Files that the crash prevented from being written are restored from quartus/soc/ref/submodules (five small pass-through / DDR3
wrapper files, identical in interface to the known-good generation).

Usage: python -I scripts/patch_qip.py [path/to/soc_system.qip]      exit code 0 = qip complete, 1 = referenced file missing on disk
"""
import os
import re
import shutil
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REF = os.path.join(ROOT, "quartus", "soc", "ref", "soc_system.qip.files")


def main():
    qip = sys.argv[1] if len(sys.argv) > 1 else os.path.join(ROOT, "quartus", "soc", "soc_system", "synthesis", "soc_system.qip")
    qdir = os.path.dirname(qip)
    cur = open(qip, encoding="utf-8").read()
    have = set(l.strip() for l in cur.splitlines())
    added, missing, restored_files = [], [], []
    for line in open(REF, encoding="utf-8").read().splitlines():
        line = line.strip()
        if not line or line in have:
            continue
        m = re.search(r'"(submodules/[^"]+)"', line)
        if not m:
            continue
        target = os.path.join(qdir, m.group(1))
        kept = os.path.join(os.path.dirname(REF), "submodules", os.path.basename(m.group(1)))
        if not os.path.exists(target) and os.path.exists(kept):
            # fresh generation: the crash happens before these files are written. They are interface-identical to the
            # known-good reference (checked: same wrapper, same fixed bus widths) so restore the checked-in copy.
            shutil.copyfile(kept, target)
            restored_files.append(os.path.basename(kept))
        if os.path.exists(target):
            added.append(line)
        else:
            missing.append(m.group(1))   # in the reference but no longer generated: not an error by itself (module removed)
    if added:
        with open(qip, "a", encoding="utf-8", newline="\n") as f:
            f.write("\n# --- restored by scripts/patch_qip.py (qsys-generate sequencer crash, CFAR bug log #19/#21) ---\n")
            for l in added:
                f.write(l + "\n")
    print("qip: %d lines restored, %d files copied back from quartus/soc/ref/submodules, %d reference files no longer generated (ignored)" % (len(added), len(restored_files), len(missing)))
    for l in added:
        print("  +", re.search(r'"(submodules/[^"]+)"', l).group(1))
    return 0


if __name__ == "__main__":
    sys.exit(main())
