"""Verse app icon (option A1, chosen by Alex 2026-10-14): one thin geometric V, flat terminals and a sharp vertex,
in the spirit of Jaguar's 2024 identity (slim monoline, geometric, symmetric). Constructed here, not taken from
Jaguar's proprietary typeface. Colours are northwind.example's: #eae5ec on #050405.
Usage: python3 make_icon.py   (writes verse-mark-{dark,light}-1024.png, verse-icon-{dark,light}-1024.png, AppIcon.icns)"""
import math, os, subprocess, tempfile
from PIL import Image, ImageDraw
os.chdir(os.path.dirname(os.path.abspath(__file__)))
S = 4096                                   # supersampled canvas
INK, PAPER = (234, 229, 236), (5, 4, 5)
TOP, HEIGHT, HALF_W, STROKE = 0.30, 0.40, 0.24, 0.046   # fractions of the canvas; STROKE 0.046 = "A1"

def mark(dark):
    bg, ink = (PAPER, INK) if dark else (INK, PAPER)
    img = Image.new("RGB", (S, S), bg); d = ImageDraw.Draw(img)
    cx, top, h, a, w = S / 2, S * TOP, S * HEIGHT, S * HALF_W, S * STROKE
    th = math.atan(a / h); t = w / math.cos(th); dd = w / math.sin(th); b = top + h
    d.polygon([(cx - a, top), (cx - a + t, top), (cx, b - dd), (cx + a - t, top), (cx + a, top), (cx, b)], fill=ink)
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
