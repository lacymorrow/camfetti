#!/usr/bin/env python3
"""Add the Mac sizes to AppIcon: the 1024 icon inside Apple's Mac grid (824pt rounded square on a
1024 canvas, with a soft shadow). The App Store rejects a Mac app without them.
Run from the repo root: python3 scripts/gen-mac-icon.py"""
import json
from PIL import Image, ImageDraw, ImageFilter

SET = "Resources/Assets.xcassets/AppIcon.appiconset"
SIZES = [(16, 1), (16, 2), (32, 1), (32, 2), (128, 1), (128, 2), (256, 1), (256, 2), (512, 1), (512, 2)]
SS = 4

src = Image.open(f"{SET}/icon-1024.png").convert("RGBA")
side = 824 * SS
mask = Image.new("L", (side, side), 0)
ImageDraw.Draw(mask).rounded_rectangle((0, 0, side - 1, side - 1), radius=185 * SS, fill=255)
mask = mask.resize((824, 824), Image.LANCZOS)

art = src.resize((824, 824), Image.LANCZOS)
art.putalpha(mask)
canvas = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
shadow = Image.new("RGBA", (1024, 1024), (0, 0, 0, 0))
shadow.paste((0, 0, 0, 90), (100, 112), mask)
canvas = Image.alpha_composite(canvas, shadow.filter(ImageFilter.GaussianBlur(14)))
canvas.alpha_composite(art, (100, 100))

doc = json.load(open(f"{SET}/Contents.json"))
doc["images"] = [i for i in doc["images"] if i.get("idiom") != "mac"]
for size, scale in SIZES:
    px = size * scale
    name = f"mac-{size}@{scale}x.png"
    canvas.resize((px, px), Image.LANCZOS).save(f"{SET}/{name}")
    doc["images"].append({"filename": name, "idiom": "mac", "scale": f"{scale}x", "size": f"{size}x{size}"})
json.dump(doc, open(f"{SET}/Contents.json", "w"), indent=2)
