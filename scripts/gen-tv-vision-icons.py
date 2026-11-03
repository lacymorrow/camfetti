#!/usr/bin/env python3
"""Redraw CamFetti's icon as layers for tvOS and visionOS (Pillow, 4x supersampled).
Confetti pieces are measured from icon-1024.png, then redrawn as clean rectangles.
Run from the repo root: python3 scripts/gen-tv-vision-icons.py"""
import json, math, os, random, shutil, sys
import numpy as np
from PIL import Image, ImageDraw, ImageFont

CAT = "Resources/Assets.xcassets"
SRC = f"{CAT}/AppIcon.appiconset/icon-1024.png"
BG = (18, 18, 26); LENS = (36, 38, 56); PINK = (255, 79, 120); WHITE = (255, 255, 255)
CONF = [(255, 201, 61), (46, 196, 181), (59, 135, 255)]
SS = 4
INFO = {"author": "xcode", "version": 1}


def measure():
    """Return [(color, cx, cy, w, h, angle)] for each confetti piece in the 1024 icon."""
    a = np.array(Image.open(SRC).convert("RGB")).astype(int)
    out = []
    for col in CONF:
        m = np.abs(a - col).sum(2) < 12
        seen = np.zeros_like(m)
        for y, x in zip(*np.nonzero(m)):
            if seen[y, x]:
                continue
            stack = [(y, x)]; seen[y, x] = True; pts = []
            while stack:
                cy, cx = stack.pop(); pts.append((cx, cy))
                for dy, dx in ((1, 0), (-1, 0), (0, 1), (0, -1)):
                    ny, nx = cy + dy, cx + dx
                    if 0 <= ny < 1024 and 0 <= nx < 1024 and m[ny, nx] and not seen[ny, nx]:
                        seen[ny, nx] = True; stack.append((ny, nx)[::-1][::-1])
            if len(pts) < 100:
                continue
            p = np.array(pts, float); c = p.mean(0); q = p - c
            w, v = np.linalg.eigh(np.cov(q.T))
            ax = v[:, 1]; u = q @ v
            L = math.sqrt(12 * w[1]); W = math.sqrt(12 * w[0])
            out.append((col, c[0], c[1], L, W, math.atan2(ax[1], ax[0])))
    return out


PIECES = measure()


def canvas(w, h, bg=None):
    return Image.new("RGBA", (w * SS, h * SS), bg + (255,) if bg else (0, 0, 0, 0))


def done(im, w, h, opaque=False):
    im = im.resize((w, h), Image.LANCZOS)
    return im.convert("RGB") if opaque else im


def rect(d, col, cx, cy, L, W, ang, k=1.0):
    L *= k; W *= k
    ca, sa = math.cos(ang), math.sin(ang)
    pts = [(cx + (sx * L / 2) * ca - (sy * W / 2) * sa, cy + (sx * L / 2) * sa + (sy * W / 2) * ca)
           for sx, sy in ((-1, -1), (1, -1), (1, 1), (-1, 1))]
    d.polygon([(x * SS, y * SS) for x, y in pts], fill=col + (255,))


def circle(d, col, cx, cy, r):
    d.ellipse([(cx - r) * SS, (cy - r) * SS, (cx + r) * SS, (cy + r) * SS], fill=col + (255,))


def ring(d, cx, cy, k, with_hole_bg=BG):
    circle(d, PINK, cx, cy, 300 * k)
    circle(d, with_hole_bg, cx, cy, 222 * k)


def lens(d, cx, cy, k):
    circle(d, LENS, cx, cy, 138 * k)
    circle(d, WHITE, cx - 50 * k, cy - 54 * k, 44 * k)


def hole_ring(im, cx, cy, k):
    """Ring with a real transparent hole (for layers over a background)."""
    d = ImageDraw.Draw(im)
    circle(d, PINK, cx, cy, 300 * k)
    d.ellipse([(cx - 222 * k) * SS, (cy - 222 * k) * SS, (cx + 222 * k) * SS, (cy + 222 * k) * SS], fill=(0, 0, 0, 0))
    # dark disc inside the ring, as in the icon (ring hole shows background color)
    circle(d, BG, cx, cy, 222 * k)


def confetti_original(w, h, k, cx, cy):
    im = canvas(w, h); d = ImageDraw.Draw(im)
    for col, x, y, L, W, ang in PIECES:
        rect(d, col, cx + (x - 512) * k, cy + (y - 512) * k, L, W, ang, 1.0)
    return im


def confetti_wide(w, h, k, keepouts, seed):
    rng = random.Random(seed)
    im = canvas(w, h); d = ImageDraw.Draw(im)
    placed = []; n = int(w / 1024 * 14 * 1.3)
    tries = 0
    while len(placed) < n and tries < 20000:
        tries += 1
        col, _, _, L, W, _ = PIECES[rng.randrange(len(PIECES))]
        s = k * rng.uniform(0.9, 1.3)
        x = rng.uniform(40 * k, w - 40 * k); y = rng.uniform(40 * k, h - 40 * k)
        if any(x0 <= x <= x1 and y0 <= y <= y1 for x0, y0, x1, y1 in keepouts):
            continue
        if any(math.hypot(x - px, y - py) < 110 * k for px, py in placed):
            continue
        placed.append((x, y))
        rect(d, col, x, y, L, W, rng.uniform(0, math.pi), s)
    return im


def lens_layer(w, h, k, cx, cy):
    im = canvas(w, h)
    hole_ring(im, cx, cy, k)
    lens(ImageDraw.Draw(im), cx, cy, k)
    return im


# ---------- asset writers ----------
def wj(path, obj):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        json.dump(obj, f, indent=2); f.write("\n")


def save(im, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    im.save(path, optimize=True)


def fresh(path):
    if os.path.isdir(path):
        shutil.rmtree(path)


def tv_stack(root, w, h, layers, scales):
    """layers: {name: draw(w,h)->Image}; names ordered front to back."""
    fresh(root)
    wj(f"{root}/Contents.json", {"info": INFO, "layers": [{"filename": f"{n}.imagestacklayer"} for n in layers]})
    for n, fn in layers.items():
        ld = f"{root}/{n}.imagestacklayer"
        wj(f"{ld}/Contents.json", {"info": INFO})
        imgs = []
        for sc in scales:
            im = fn(w * sc, h * sc, sc)
            fname = f"{n.lower()}{'' if sc == 1 else '@%dx' % sc}.png"
            save(im, f"{ld}/Content.imageset/{fname}")
            imgs.append({"filename": fname, "idiom": "tv", "scale": f"{sc}x"})
        wj(f"{ld}/Content.imageset/Contents.json", {"images": imgs, "info": INFO})


def icon_layers(w0, h0):
    def back(w, h, sc):
        return done(canvas(w, h, BG), w, h, opaque=True)

    def front(w, h, sc):
        k = h / 1024 * 0.78
        im = confetti_original(w, h, h / 1024, w / 2, h / 2)
        # confetti stretched across the wide canvas instead of cropped
        im = canvas(w, h); d = ImageDraw.Draw(im)
        for col, x, y, L, W, ang in PIECES:
            rect(d, col, w / 2 + (x - 512) * (w / 1024) * 0.92, h / 2 + (y - 512) * (h / 1024) * 0.92, L, W, ang, h / 1024 * 1.1)
        ring_im = canvas(w, h); hole_ring(ring_im, w / 2, h / 2, k)
        lens(ImageDraw.Draw(ring_im), w / 2, h / 2, k)
        im.alpha_composite(ring_im)
        return done(im, w, h)
    return {"Front": front, "Back": back}


def shelf(w, h):
    k = h / 1024 * 0.80
    cx, cy = w * 0.27, h / 2
    font = ImageFont.truetype("/System/Library/Fonts/Supplemental/Arial Rounded Bold.ttf", int(h * 0.30 * SS))
    tw = font.getlength("CamFetti") / SS
    tx = w * 0.46
    ty = h / 2
    keep = [(cx - 330 * k, cy - 330 * k, cx + 330 * k, cy + 330 * k), (tx - 30, ty - h * 0.28, tx + tw + 30, ty + h * 0.28)]
    im = canvas(w, h, BG)
    im.alpha_composite(confetti_wide(w, h, h / 1024, keep, seed=w))
    d = ImageDraw.Draw(im)
    circle(d, PINK, cx, cy, 300 * k); circle(d, BG, cx, cy, 222 * k); lens(d, cx, cy, k)
    d.text((tx * SS, ty * SS), "Cam", font=font, fill=WHITE + (255,), anchor="lm")
    cw = font.getlength("Cam")
    d.text((tx * SS + cw, ty * SS), "Fetti", font=font, fill=PINK + (255,), anchor="lm")
    return done(im, w, h, opaque=True)


def tv_shelf(root, w, h, role):
    fresh(root)
    imgs = []
    for sc in (1, 2):
        fname = f"shelf{'' if sc == 1 else '@2x'}.png"
        save(shelf(w * sc, h * sc), f"{root}/{fname}")
        imgs.append({"filename": fname, "idiom": "tv", "scale": f"{sc}x"})
    wj(f"{root}/Contents.json", {"images": imgs, "info": INFO})


def tvos():
    b = f"{CAT}/App Icon & Top Shelf Image.brandassets"
    fresh(b)
    tv_stack(f"{b}/App Icon.imagestack", 400, 240, icon_layers(400, 240), (1, 2))
    tv_stack(f"{b}/App Icon - App Store.imagestack", 1280, 768, icon_layers(1280, 768), (1,))
    tv_shelf(f"{b}/Top Shelf Image.imageset", 1920, 720, "top-shelf-image")
    tv_shelf(f"{b}/Top Shelf Image Wide.imageset", 2320, 720, "top-shelf-image-wide")
    wj(f"{b}/Contents.json", {"info": INFO, "assets": [
        {"filename": "App Icon - App Store.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "1280x768"},
        {"filename": "App Icon.imagestack", "idiom": "tv", "role": "primary-app-icon", "size": "400x240"},
        {"filename": "Top Shelf Image Wide.imageset", "idiom": "tv", "role": "top-shelf-image-wide", "size": "2320x720"},
        {"filename": "Top Shelf Image.imageset", "idiom": "tv", "role": "top-shelf-image", "size": "1920x720"}]})


def visionos():
    root = f"{CAT}/VisionAppIcon.solidimagestack"
    fresh(root)
    S = 1024
    layers = {}
    back = done(canvas(S, S, BG), S, S, opaque=True)
    mid = canvas(S, S); d = ImageDraw.Draw(mid)
    for col, x, y, L, W, ang in PIECES:
        rect(d, col, x, y, L, W, ang)
    front = lens_layer(S, S, 1.0, 512, 512)
    wj(f"{root}/Contents.json", {"info": INFO, "layers": [
        {"filename": "Front.solidimagestacklayer"}, {"filename": "Middle.solidimagestacklayer"}, {"filename": "Back.solidimagestacklayer"}]})
    for n, im in (("Front", done(front, S, S)), ("Middle", done(mid, S, S)), ("Back", back)):
        ld = f"{root}/{n}.solidimagestacklayer"
        wj(f"{ld}/Contents.json", {"info": INFO})
        save(im, f"{ld}/Content.imageset/{n.lower()}.png")
        wj(f"{ld}/Content.imageset/Contents.json", {"images": [{"filename": f"{n.lower()}.png", "idiom": "vision", "scale": "2x"}], "info": INFO})


if __name__ == "__main__":
    print(len(PIECES), "confetti measured")
    tvos(); visionos()
