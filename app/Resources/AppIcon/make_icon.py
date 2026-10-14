"""Verse app icon: the "v" of the northwind.example wordmark (direction B "Orbit", the owner's own geometric monoline
outlines, portfolio2-media/design/wordmark/dir-B/nav/wordmark-w124.json), stacked like the Trailhead R: the front
letter, graded side layers, and a back copy. Colours are the site's: #eae5ec on #050405.
Usage: python3 make_icon.py   (writes verse-mark-{dark,light}-1024.png, verse-icon-{dark,light}-1024.png, AppIcon.icns)"""
import os, subprocess, tempfile
from PIL import Image, ImageDraw
os.chdir(os.path.dirname(os.path.abspath(__file__)))
V = [(1992, -520), (2125.5, -520), (2227, -264.9), (2328.5, -520), (2462, -520), (2255, 0), (2199, 0)]  # w124 cut
INK, PAPER = (234, 229, 236), (5, 4, 5)
S = 4096                                        # supersampled canvas

def mark(dark, fit=0.50, depth=0.085, layers=48, ang=(1.0, -0.42)):
    bg, ink = (PAPER, INK) if dark else (INK, PAPER)
    x0 = min(p[0] for p in V); y0 = min(p[1] for p in V)
    w = max(p[0] for p in V) - x0; h = max(p[1] for p in V) - y0
    sc = S * fit / w; dep = S * depth
    ox = (S - w * sc - dep * ang[0]) / 2; oy = (S - h * sc) / 2 + dep * abs(ang[1]) / 2
    img = Image.new("RGB", (S, S), bg); d = ImageDraw.Draw(img)
    def poly(off, c):
        d.polygon([(ox + (x - x0) * sc + off * ang[0], oy + (y - y0) * sc + off * ang[1]) for x, y in V], fill=c)
    for i in range(layers, 0, -1):
        k = i / layers
        if i == layers: c = ink                                   # back copy in the same ink as the front
        else:                                                     # side faces: mid grey, lighter toward the front
            t = 0.35 + 0.4 * (1 - k)
            c = tuple(int(bg[j] + (ink[j] - bg[j]) * t) for j in range(3))
        poly(dep * k, c)
    poly(0, ink)
    return img.resize((1024, 1024), Image.LANCZOS)

for name, dark in (("dark", True), ("light", False)):
    src = mark(dark); src.save(f"verse-mark-{name}-1024.png")
    tile = src.resize((824, 824), Image.LANCZOS)                  # macOS grid: 824 square, radius ~185, in 1024
    m = Image.new("L", (3296, 3296), 0); ImageDraw.Draw(m).rounded_rectangle((0, 0, 3295, 3295), radius=740, fill=255)
    out = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0)); out.paste(tile, (100, 100), m.resize((824, 824), Image.LANCZOS))
    out.save(f"verse-icon-{name}-1024.png")
with tempfile.TemporaryDirectory() as t:
    iconset = os.path.join(t, "AppIcon.iconset"); os.mkdir(iconset)
    base = Image.open("verse-icon-dark-1024.png")
    for s in (16, 32, 128, 256, 512):
        base.resize((s, s), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}.png")
        base.resize((s * 2, s * 2), Image.LANCZOS).save(f"{iconset}/icon_{s}x{s}@2x.png")
    subprocess.run(["iconutil", "-c", "icns", iconset, "-o", "AppIcon.icns"], check=True)
