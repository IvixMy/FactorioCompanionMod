#!/usr/bin/env python3
"""Generates the PLACEHOLDER portrait sprite sheets of the interaction window.

Each animation is ONE horizontal strip: `frames` frames of 256x256 side by side
(graphics/portrait/<animation>.png). Replace any strip by real art of the same size and
the same frame count and nothing else has to change; to add an animation, add it here (or
draw the strip yourself) and add one entry to scripts/portrait_animations.lua.
"""
from PIL import Image, ImageDraw
import math, os

S = 64            # drawn at 64x64 and scaled x4 (chunky pixels)
W = 256
OUT = os.path.join(os.path.dirname(__file__), "..", "graphics", "portrait")

BG   = (18, 38, 34, 255)
SCAN = (24, 50, 44, 255)
SKIN = (233, 190, 150, 255)
SHADE = (200, 150, 112, 255)
HAT  = (236, 140, 20, 255)
HAT2 = (255, 190, 60, 255)
DARK = (40, 30, 30, 255)
WHITE = (245, 245, 240, 255)
RED  = (200, 50, 50, 255)
BLUE = (80, 150, 230, 255)
YEL  = (250, 220, 70, 255)
GREY = (170, 170, 175, 255)

def base():
    im = Image.new("RGBA", (S, S), BG)
    d = ImageDraw.Draw(im)
    for y in range(0, S, 4):
        d.line([(0, y), (S, y)], fill=SCAN)
    # shoulders / overalls
    d.rectangle([8, 52, 56, 63], fill=(60, 90, 140, 255))
    d.rectangle([26, 48, 38, 54], fill=SKIN)
    # head
    d.ellipse([16, 14, 48, 52], fill=SKIN, outline=SHADE)
    # hard hat
    d.pieslice([13, 6, 51, 40], 180, 360, fill=HAT)
    d.rectangle([11, 22, 53, 25], fill=HAT2)
    d.rectangle([29, 7, 35, 14], fill=HAT2)
    return im, d

def eyes(d, mode="open", look=(0, 0)):
    for cx in (25, 39):
        cx += look[0]
        if mode == "open":
            d.ellipse([cx - 3, 31 + look[1], cx + 3, 37 + look[1]], fill=WHITE)
            d.rectangle([cx - 1, 33 + look[1], cx + 1, 35 + look[1]], fill=DARK)
        elif mode == "half":
            d.rectangle([cx - 3, 34, cx + 3, 36], fill=DARK)
        elif mode == "closed":
            d.line([(cx - 3, 35), (cx + 3, 35)], fill=DARK, width=1)
        elif mode == "squint":
            d.line([(cx - 3, 33), (cx + 3, 36)] if cx < 32 else [(cx - 3, 36), (cx + 3, 33)], fill=DARK, width=2)
        elif mode == "happy":
            d.arc([cx - 3, 31, cx + 3, 38], 200, 340, fill=DARK, width=2)

def mouth(d, mode="closed"):
    if mode == "closed":
        d.line([(27, 44), (37, 44)], fill=DARK, width=1)
    elif mode == "open":
        d.ellipse([28, 41, 36, 48], fill=DARK)
    elif mode == "wide":
        d.ellipse([26, 40, 38, 49], fill=DARK)
        d.rectangle([29, 41, 35, 43], fill=WHITE)
    elif mode == "smile":
        d.arc([25, 36, 39, 48], 20, 160, fill=DARK, width=2)
    elif mode == "frown":
        d.arc([26, 43, 38, 53], 200, 340, fill=DARK, width=2)

def brows(d, tilt=0):
    d.line([(21, 28 - tilt), (29, 28 + tilt)], fill=DARK, width=2)
    d.line([(35, 28 + tilt), (43, 28 - tilt)], fill=DARK, width=2)

def gear(d, cx, cy, r, ang):
    for i in range(6):
        a = ang + i * math.pi / 3
        d.line([(cx, cy), (cx + math.cos(a) * (r + 3), cy + math.sin(a) * (r + 3))], fill=GREY, width=3)
    d.ellipse([cx - r, cy - r, cx + r, cy + r], fill=GREY, outline=DARK)
    d.ellipse([cx - 2, cy - 2, cx + 2, cy + 2], fill=BG)

def frames_idle():
    out = []
    for m in ("open", "open", "half", "closed"):
        im, d = base(); eyes(d, m); mouth(d, "closed"); out.append(im)
    return out

def frames_talk():
    out = []
    for m in ("closed", "open", "wide", "open"):
        im, d = base(); eyes(d, "open"); mouth(d, m); out.append(im)
    return out

def frames_working():
    out = []
    for i in range(4):
        im, d = base(); eyes(d, "squint"); brows(d, 1); mouth(d, "closed" if i % 2 else "open")
        gear(d, 53, 12, 5, i * math.pi / 6)
        if i % 2: d.ellipse([46, 30, 49, 35], fill=BLUE)  # sweat
        out.append(im)
    return out

def frames_thinking():
    out = []
    looks = [(-1, -1), (1, -1), (1, -1), (-1, -1)]
    for i in range(4):
        im, d = base(); eyes(d, "open", looks[i]); mouth(d, "closed"); brows(d, 0)
        for k in range(i % 4):
            d.ellipse([46 + k * 5, 8, 49 + k * 5, 11], fill=WHITE)
        out.append(im)
    return out

def frames_happy():
    out = []
    for i in range(4):
        im, d = base(); eyes(d, "happy"); mouth(d, "smile" if i % 2 == 0 else "wide")
        for (x, y) in ((8, 14), (54, 20), (12, 40)):
            s = 2 + ((i + x) % 3)
            d.line([(x - s, y), (x + s, y)], fill=YEL, width=1); d.line([(x, y - s), (x, y + s)], fill=YEL, width=1)
        out.append(im)
    return out

def frames_worried():
    out = []
    for i in range(4):
        im, d = base(); eyes(d, "open", (0, 1)); brows(d, -2); mouth(d, "frown")
        if i % 2 == 0:
            d.rectangle([53, 10, 55, 22], fill=RED); d.rectangle([53, 25, 55, 27], fill=RED)
        out.append(im)
    return out

def frames_tired():
    out = []
    for i in range(4):
        im, d = base(); eyes(d, "closed"); mouth(d, "closed" if i % 2 == 0 else "open")
        for k in range(i + 1):
            d.text((46 + k * 4, 22 - k * 5), "z", fill=WHITE)
        out.append(im)
    return out

ANIMS = {
    "idle": frames_idle, "talk": frames_talk, "working": frames_working, "thinking": frames_thinking,
    "happy": frames_happy, "worried": frames_worried, "tired": frames_tired,
}

if __name__ == "__main__":
    os.makedirs(OUT, exist_ok=True)
    for name, fn in ANIMS.items():
        frames = fn()
        sheet = Image.new("RGBA", (W * len(frames), W))
        for i, f in enumerate(frames):
            sheet.paste(f.resize((W, W), Image.NEAREST), (i * W, 0))
        sheet.save(os.path.join(OUT, name + ".png"))
        print(name, len(frames), "frames")
