#!/usr/bin/env python3
"""Erzeugt das TouchBridge-App-Icon (Entwurf 2 „Multitouch“, Liquid Glass) und den Menüleisten-Glyph.

  Resources/AppIcon.icns          16–1024 px inkl. @2x (PNG-Einträge, wie iconutil)
  Resources/MenuBarIcon.png/@2x   18 pt Template-Glyph (schwarz + Alpha, NSImage.isTemplate)
  Resources/AppIcon-1024.png      Vorschau

Squircle 824 px auf 1024er Canvas (Apple-Raster). 16/32 px nutzen eine vereinfachte Variante
(ohne Glow/Spuren, größere Punkte), damit das Motiv lesbar bleibt.
Abhängigkeiten: pip install cairosvg pillow      Aufruf: python3 scripts/icon/make_icon.py
"""
import io, os, struct, sys
import cairosvg
sys.path.insert(0, os.path.dirname(__file__))
from glass import HEAD, TAIL, pane, touch, red, tube  # Motiv-Bausteine aus dem Entwurfsgenerator

ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RES = os.path.join(ROOT, "Resources")

def full_svg():
    s = pane(210, 250, 604, 440, 70)
    for (x0, y0, x1, y1) in [(300, 620, 380, 410), (470, 650, 512, 350), (640, 630, 650, 430)]:
        d = f"M{x0} {y0} Q{(x0+x1)/2-30} {(y0+y1)/2} {x1} {y1}"
        s += (f'<path d="{d}" fill="none" stroke="#b9a8ff" stroke-opacity=".55" stroke-width="16" '
              f'stroke-linecap="round" stroke-dasharray="2 34"/>') + touch(x1, y1, 40)
    s += red(512, 250, 20) + tube("M512 690 V770 M410 790 H614", 26)
    return HEAD + s + TAIL

def small_svg():
    # gleiche Komposition, aber kräftiger: größere Scheibe, dicker Rand, große Punkte ohne Glow/Spuren
    s = (f'<rect x="180" y="215" width="664" height="500" rx="80" fill="url(#pane)"/>'
         f'<rect x="196" y="231" width="632" height="468" rx="66" fill="none" stroke="#fff" stroke-opacity=".9" stroke-width="32"/>')
    for (x, y) in [(330, 480), (512, 400), (694, 480)]:
        s += f'<circle cx="{x}" cy="{y}" r="68" fill="#fff"/><circle cx="{x}" cy="{y}" r="68" fill="url(#ball)"/>'
    s += f'<circle cx="512" cy="215" r="44" fill="#ff3b4f"/>'
    s += '<path d="M512 715 V800 M380 812 H644" fill="none" stroke="#efe9de" stroke-width="48" stroke-linecap="round"/>'
    return HEAD + s + TAIL

def png(svg, px):
    return cairosvg.svg2png(bytestring=svg.encode(), output_width=px, output_height=px)

# icns-Typen (PNG-Daten): Pixelgröße
TYPES = [("icp4", 16), ("ic11", 32), ("icp5", 32), ("ic12", 64), ("ic07", 128), ("ic13", 256),
         ("ic08", 256), ("ic14", 512), ("ic09", 512), ("ic10", 1024)]

def build():
    full, small = full_svg(), small_svg()
    cache = {}
    def img(px):
        if px not in cache: cache[px] = png(small if px <= 32 else full, px)
        return cache[px]
    body = b"".join(t.encode() + struct.pack(">I", 8 + len(img(px))) + img(px) for t, px in TYPES)
    with open(os.path.join(RES, "AppIcon.icns"), "wb") as f:
        f.write(b"icns" + struct.pack(">I", 8 + len(body)) + body)
    with open(os.path.join(RES, "AppIcon-1024.png"), "wb") as f: f.write(img(1024))
    with open(os.path.join(ROOT, "scripts/icon/AppIcon.svg"), "w") as f: f.write(full)
    with open(os.path.join(ROOT, "scripts/icon/AppIcon-small.svg"), "w") as f: f.write(small)
    # Menüleisten-Glyph: Bildschirm (Scheibe) mit drei Berührungspunkten und Standfuß, 18x18 pt
    glyph = ('<svg xmlns="http://www.w3.org/2000/svg" width="18" height="18" viewBox="0 0 18 18">'
             '<rect x="1.6" y="2.6" width="14.8" height="10.4" rx="2.4" fill="none" stroke="#000" stroke-width="1.4"/>'
             '<circle cx="5.1" cy="8.9" r="1.5"/><circle cx="9" cy="6.5" r="1.5"/><circle cx="12.9" cy="8.9" r="1.5"/>'
             '<path d="M9 13 V15.4 M6 15.6 H12" stroke="#000" stroke-width="1.4" stroke-linecap="round" fill="none"/></svg>')
    with open(os.path.join(ROOT, "scripts/icon/MenuBarIcon.svg"), "w") as f: f.write(glyph)
    for name, px in (("MenuBarIcon.png", 18), ("MenuBarIcon@2x.png", 36)):
        with open(os.path.join(RES, name), "wb") as f:
            f.write(cairosvg.svg2png(bytestring=glyph.encode(), output_width=px, output_height=px))
    print("ok:", ", ".join(f"{t}={px}" for t, px in TYPES))

if __name__ == "__main__":
    build()
