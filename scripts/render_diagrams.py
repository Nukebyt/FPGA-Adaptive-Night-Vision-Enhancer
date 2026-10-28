"""Render docs/diagrams/*.mmd (Mermaid sources) to docs/img/diagram_<name>.png with a real browser engine.

GitHub renders Mermaid blocks in its own sandboxed viewer, which fails in some browser setups ("Unable to render rich display"),
so the README embeds these PNGs and keeps the sources here. Needs Microsoft Edge or Chrome and the Mermaid bundle:

    npm install mermaid@11            (anywhere; pass the path of node_modules/mermaid/dist/mermaid.min.js)
    python -I scripts/render_diagrams.py --mermaid path/to/mermaid.min.js [--browser path/to/msedge.exe]
"""
import argparse
import html
import os
import subprocess
import sys
import tempfile

from PIL import Image, ImageChops

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "docs", "diagrams")
OUT = os.path.join(ROOT, "docs", "img")
BROWSERS = [r"C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe", r"C:\Program Files\Microsoft\Edge\Application\msedge.exe",
            r"C:\Program Files\Google\Chrome\Application\chrome.exe", "/usr/bin/chromium", "/usr/bin/google-chrome"]


def crop_white(path, margin=24):
    im = Image.open(path).convert("RGB")
    bbox = ImageChops.difference(im, Image.new("RGB", im.size, (255, 255, 255))).getbbox()
    if bbox:
        l, t, r, b = bbox
        im = im.crop((max(l - margin, 0), max(t - margin, 0), min(r + margin, im.width), min(b + margin, im.height)))
    im.save(path, optimize=True)
    return im.size


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--mermaid", required=True)
    ap.add_argument("--browser")
    a = ap.parse_args()
    browser = a.browser or next((b for b in BROWSERS if os.path.exists(b)), None)
    if not browser:
        sys.exit("no Edge/Chrome found, pass --browser")
    lib = os.path.abspath(a.mermaid).replace("\\", "/")
    os.makedirs(OUT, exist_ok=True)
    for fn in sorted(os.listdir(SRC)):
        if not fn.endswith(".mmd"):
            continue
        src = open(os.path.join(SRC, fn), encoding="utf-8").read()
        page = ('<!doctype html><meta charset="utf-8"><body style="margin:0;background:#fff">'
                '<pre class="mermaid" style="margin:16px">%s</pre><script src="file:///%s"></script>'
                '<script>mermaid.initialize({startOnLoad:true,securityLevel:"strict",theme:"default",flowchart:{useMaxWidth:false},sequence:{useMaxWidth:false}});</script>'
                % (html.escape(src, quote=False), lib))
        out = os.path.join(OUT, "diagram_%s.png" % fn[:-4])
        with tempfile.TemporaryDirectory() as td:
            hp = os.path.join(td, "d.html")
            open(hp, "w", encoding="utf-8").write(page)
            subprocess.run([browser, "--headless=new", "--disable-gpu", "--allow-file-access-from-files", "--force-device-scale-factor=2",
                            "--virtual-time-budget=20000", "--window-size=2400,3200", "--screenshot=" + out, "file:///" + hp.replace("\\", "/")],
                           check=True, capture_output=True)
        print("%-28s %s" % (os.path.basename(out), crop_white(out)))


if __name__ == "__main__":
    main()
