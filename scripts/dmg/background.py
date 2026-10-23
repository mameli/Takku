"""Draws scripts/dmg/background.tiff, the window of the disk image: the squared paper of takku.app,
a pencil arrow from Takku to Applications and a line of handwriting. Rendered with Google Chrome
at 1× and 2×, joined by tiffutil so Finder picks the sharp one on Retina screens. The icon
positions in release.sh match ICON_Y, TAKKU_X and APPLICATIONS_X.

    python3 scripts/dmg/background.py

Kalam comes from the takku.app repository (../takku.app, or $TAKKU_SITE); without it Chrome
falls back to Bradley Hand.
"""
import math
import os
import random
import subprocess
import tempfile
from pathlib import Path

random.seed(7)
HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
SITE = Path(os.environ.get("TAKKU_SITE", ROOT.parent / "takku.app"))
CHROME = "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome"

WIDTH, HEIGHT = 640, 400
ICON_Y, TAKKU_X, APPLICATIONS_X = 205, 175, 465


def wobble(length, amp):
    waves = [(k, amp * a, random.uniform(0, 2 * math.pi)) for k, a in ((1, 0.55), (2, 0.3), (3, 0.2), (5, 0.12))]
    return lambda t: sum(a * math.sin(2 * math.pi * k * t / length + p) for k, a, p in waves)


def path(points):
    return "M" + "L".join(f"{x:.2f} {y:.2f}" for x, y in points)


def arc(x0, x1, y, rise, amp=0.9, step=3):
    """A pencil stroke that bows upwards between x0 and x1, as a hand draws it."""
    off = wobble(x1 - x0, amp)
    points = []
    for x in range(x0, x1 + 1, step):
        f = (x - x0) / (x1 - x0)
        points.append((x, y - rise * math.sin(math.pi * f) + off(x - x0)))
    return points


def head(tip, angle, size=15, spread=0.5):
    """Two short strokes back from the tip, not quite the same length."""
    strokes = []
    for side in (-1, 1):
        a = angle + math.pi + side * (spread + random.uniform(-0.06, 0.06))
        s = size * random.uniform(0.9, 1.08)
        end = (tip[0] + s * math.cos(a), tip[1] + s * math.sin(a))
        mid = ((tip[0] + end[0]) / 2 + random.uniform(-0.6, 0.6), (tip[1] + end[1]) / 2 + random.uniform(-0.6, 0.6))
        strokes.append(path([end, mid, tip]))
    return strokes


def margin(x):
    off = wobble(HEIGHT, 0.7)
    return path([(x + off(y), y) for y in range(0, HEIGHT + 1, 4)])


shaft = arc(TAKKU_X + 78, APPLICATIONS_X - 82, ICON_Y - 8, 26)
angle = math.atan2(shaft[-1][1] - shaft[-3][1], shaft[-1][0] - shaft[-3][0])
# A second, lighter pass a hair off the first: a coloured pencil, not a pen.
again = [(x + random.uniform(-0.4, 0.4), y + 0.8 + random.uniform(-0.3, 0.3)) for x, y in shaft]
arrow = [path(shaft), *head(shaft[-1], angle)]

font = SITE / "public" / "fonts" / "kalam-700.woff2"
page = f"""<!doctype html>
<html><head><meta charset="utf-8"><style>
  @font-face {{ font-family: "Kalam"; font-weight: 700; src: url("{font.as_uri()}") format("woff2"); }}
  html, body {{ margin: 0; width: {WIDTH}px; height: {HEIGHT}px; overflow: hidden; }}
  body {{
    background-color: #f1f3ee;
    background-image:
      linear-gradient(rgb(64 96 176 / 0.16) 1px, transparent 1px),
      linear-gradient(90deg, rgb(64 96 176 / 0.16) 1px, transparent 1px);
    background-size: 24px 24px;
    background-position: -1px 11px;
  }}
  svg {{ position: absolute; inset: 0; }}
  p {{
    position: absolute; left: 0; right: 0; margin: 0; text-align: center;
    font: 700 25px "Kalam", "Bradley Hand", cursive; color: #3f58ae;
  }}
  .say {{ top: 52px; transform: rotate(-1.5deg); }}
  .then {{ top: 322px; font-size: 18px; color: #5b5e66; transform: rotate(-1deg); }}
</style></head><body>
<svg viewBox="0 0 {WIDTH} {HEIGHT}" fill="none" stroke-linecap="round" stroke-linejoin="round">
  <path d="{margin(40)}{margin(45)}" stroke="#c23b2e" stroke-opacity="0.45" stroke-width="1.2"/>
  <path d="{path(again)}" stroke="#c23b2e" stroke-opacity="0.35" stroke-width="2"/>
  <path d="{''.join(arrow)}" stroke="#c23b2e" stroke-width="3"/>
</svg>
<p class="say">Drag Takku into Applications</p>
<p class="then">then open it from there · takku.app/setup</p>
</body></html>"""

with tempfile.TemporaryDirectory() as tmp:
    html = Path(tmp) / "background.html"
    html.write_text(page)
    pngs = []
    for scale in (1, 2):
        png = Path(tmp) / f"background-{scale}x.png"
        subprocess.run(
            [
                CHROME, "--headless", "--disable-gpu", "--hide-scrollbars", f"--force-device-scale-factor={scale}",
                "--virtual-time-budget=2000", "--allow-file-access-from-files",
                f"--window-size={WIDTH},{HEIGHT}", f"--screenshot={png}", html.as_uri(),
            ],
            check=True,
            capture_output=True,
        )
        pngs.append(str(png))
    # 72 and 144 dpi, so Finder lays both out at 640 × 400 points.
    subprocess.run(["sips", "-s", "dpiWidth", "144", "-s", "dpiHeight", "144", pngs[1]], check=True, capture_output=True)
    subprocess.run(["tiffutil", "-cathidpicheck", *pngs, "-out", str(HERE / "background.tiff")], check=True, capture_output=True)
print(f"background.tiff: {(HERE / 'background.tiff').stat().st_size // 1024} KB")
