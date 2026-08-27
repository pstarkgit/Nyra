#!/usr/bin/env python3
from pathlib import Path
from PIL import Image, ImageDraw, ImageFilter

ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "Resources"
ICONSET = OUT / "AppIcon.iconset"
OUT.mkdir(exist_ok=True)
ICONSET.mkdir(exist_ok=True)
S = 1024

base = Image.new("RGBA", (S, S), (0, 0, 0, 0))
orb = Image.new("RGBA", (S, S), (0, 0, 0, 0))
pix = orb.load()
cx = cy = S / 2
radius = 440
for y in range(S):
    for x in range(S):
        d = ((x-cx)**2 + (y-cy)**2) ** 0.5
        if d <= radius:
            t = d / radius
            hi = max(0, 1 - (((x-380)**2 + (y-330)**2) ** 0.5) / 520)
            pix[x, y] = (int(12+16*hi), int(14+12*hi), int(28+34*(1-t)), 255)

glow = Image.new("RGBA", (S, S), (0,0,0,0))
gd = ImageDraw.Draw(glow)
gd.ellipse((72,72,952,952), outline=(105,74,255,180), width=18)
gd.ellipse((90,90,934,934), outline=(36,184,255,110), width=7)
glow = glow.filter(ImageFilter.GaussianBlur(14))
base.alpha_composite(glow)
base.alpha_composite(orb)

draw = ImageDraw.Draw(base)
draw.ellipse((72,72,952,952), outline=(139,110,255,220), width=8)
levels = [0.24,0.52,0.90,0.42,0.90,0.52,0.24]
bar_w, gap = 68, 18
total = 7*bar_w + 6*gap
left = (S-total)/2
content_h = 520
topline = 512 - (content_h*0.90)/2
for i, level in enumerate(levels):
    h = max(bar_w, content_h*level)
    x0 = left + i*(bar_w+gap)
    y0 = topline if i == 3 else 512-h/2
    y1 = y0+h
    color = (226,81,181,255) if i == 3 else (119,80,255,255)
    draw.rounded_rectangle((x0,y0,x0+bar_w,y1), radius=bar_w/2, fill=color)

base.save(OUT / "codex-voice-orb-1024.png")
for points, scale in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)]:
    px=points*scale
    base.resize((px,px), Image.Resampling.LANCZOS).save(ICONSET / f"icon_{points}x{points}{'@2x' if scale==2 else ''}.png")
