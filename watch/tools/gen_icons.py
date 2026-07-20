#!/usr/bin/env python3
"""
Generate WatchBridge app icons ("bridge + pulse" motif) for iOS and Wear OS.

Motif: a suspension-bridge silhouette whose roadway is a heartbeat/ECG pulse line,
on a diagonal indigo -> cyan gradient. Re-runnable; overwrites existing assets.

Requires Pillow (PIL). Run from anywhere:
    python3 tools/gen_icons.py
"""
import os
import math
from PIL import Image, ImageDraw

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))  # the watch/ dir
REPO = os.path.dirname(ROOT)  # repo root (watch_bridge/)
# iOS icons live in the real Xcode project at <repo>/WatchBridge/WatchBridge/.
IOS_ICONSET = os.path.join(REPO, "WatchBridge", "WatchBridge", "Assets.xcassets", "AppIcon.appiconset")
ANDROID_RES = os.path.join(ROOT, "wearos", "WatchBridge", "app", "src", "main", "res")

# ---- palette ---------------------------------------------------------------
INDIGO = (79, 70, 229)      # #4F46E5
CYAN = (6, 182, 212)        # #06B6D4
INDIGO_DARK = (49, 46, 129)  # #312E81
CYAN_DARK = (14, 116, 144)   # #0E7490
WHITE = (255, 255, 255)

# Supersample factor for crisp anti-aliased edges.
SS = 4


def lerp(a, b, t):
    return tuple(int(round(a[i] + (b[i] - a[i]) * t)) for i in range(3))


def diagonal_gradient(size, c0, c1):
    """Diagonal (top-left -> bottom-right) gradient image."""
    img = Image.new("RGB", (size, size))
    px = img.load()
    maxd = (size - 1) * 2 or 1
    for y in range(size):
        for x in range(size):
            t = (x + y) / maxd
            px[x, y] = lerp(c0, c1, t)
    return img


def _round(draw, xy, r, fill):
    draw.ellipse([xy[0] - r, xy[1] - r, xy[0] + r, xy[1] + r], fill=fill)


def thick_polyline(draw, pts, width, fill):
    """Polyline with round caps + joints (PIL joint='curve' is unreliable across versions)."""
    draw.line(pts, fill=fill, width=width, joint="curve")
    r = width // 2
    for p in pts:
        _round(draw, p, r, fill)


def parabola(x0, y0, x1, y1, dip, n=48):
    """Points along a downward-dipping cable from (x0,y0) to (x1,y1)."""
    pts = []
    for i in range(n + 1):
        t = i / n
        x = x0 + (x1 - x0) * t
        y = y0 + (y1 - y0) * t + dip * math.sin(math.pi * t)
        pts.append((x, y))
    return pts


def draw_motif(size, mono=False, content_scale=1.0, cx=0.5, cy=0.5):
    """
    Draw the bridge+pulse motif onto a transparent RGBA layer of `size`.
    content_scale < 1 keeps the motif inside a safe zone (Android adaptive fg).
    """
    layer = Image.new("RGBA", (size, size), (0, 0, 0, 0))
    d = ImageDraw.Draw(layer)

    def P(fx, fy):
        # map design fractions into a centered box scaled by content_scale
        x = (cx + (fx - 0.5) * content_scale) * size
        y = (cy + (fy - 0.5) * content_scale) * size
        return (x, y)

    line = WHITE if not mono else (235, 235, 235)
    cable = (255, 255, 255, 220) if not mono else (210, 210, 210, 220)
    tower = (255, 255, 255, 235) if not mono else (225, 225, 225, 235)

    unit = size * content_scale
    tower_w = max(2, int(0.030 * unit))
    cable_w = max(2, int(0.018 * unit))
    pulse_w = max(3, int(0.055 * unit))
    susp_w = max(1, int(0.010 * unit))

    tx0, tx1 = 0.26, 0.74
    top = 0.28
    base = 0.60  # roadway / pulse baseline

    # main cables (parabola dipping between towers) + back-stays to deck ends
    cab = parabola(*P(tx0, top), *P(tx1, top), dip=0.20 * unit)
    d.line(cab, fill=cable, width=cable_w, joint="curve")
    d.line([P(0.10, base), P(tx0, top)], fill=cable, width=cable_w)
    d.line([P(tx1, top), P(0.90, base)], fill=cable, width=cable_w)

    # vertical suspenders from cable down to roadway
    for fx in (0.34, 0.42, 0.50, 0.58, 0.66):
        # y on parabola at fx
        t = (fx - tx0) / (tx1 - tx0)
        ty = top + (top - top) * t + 0.20 * math.sin(math.pi * max(0, min(1, t)))
        d.line([P(fx, ty), P(fx, base)], fill=cable, width=susp_w)

    # towers
    for tx in (tx0, tx1):
        x, y0 = P(tx, top)
        _, y1 = P(tx, 0.68)
        d.line([(x, y0), (x, y1)], fill=tower, width=tower_w)

    # the heartbeat roadway (hero element)
    pulse = [P(0.10, base), P(0.34, base), P(0.42, 0.44),
             P(0.50, 0.76), P(0.58, 0.30), P(0.66, base), P(0.90, base)]
    thick_polyline(d, pulse, pulse_w, line)

    return layer


def render(size, bg0, bg1, mono=False, transparent_bg=False, content_scale=1.0, cx=0.5, cy=0.5):
    s = size * SS
    if transparent_bg:
        base = Image.new("RGBA", (s, s), (0, 0, 0, 0))
    else:
        base = diagonal_gradient(s, bg0, bg1).convert("RGBA")
    motif = draw_motif(s, mono=mono, content_scale=content_scale, cx=cx, cy=cy)
    base.alpha_composite(motif)
    return base.resize((size, size), Image.LANCZOS)


def circle_mask(size):
    m = Image.new("L", (size * SS, size * SS), 0)
    ImageDraw.Draw(m).ellipse([0, 0, size * SS - 1, size * SS - 1], fill=255)
    return m.resize((size, size), Image.LANCZOS)


def save(img, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    img.save(path)
    print("  wrote", os.path.relpath(path, ROOT))


# ---- iOS -------------------------------------------------------------------
def gen_ios():
    print("iOS icons:")
    # App Store / device: full-bleed 1024, no alpha (iOS applies the mask).
    save(render(1024, INDIGO, CYAN).convert("RGB"),
         os.path.join(IOS_ICONSET, "icon-1024.png"))
    save(render(1024, INDIGO_DARK, CYAN_DARK).convert("RGB"),
         os.path.join(IOS_ICONSET, "icon-1024-dark.png"))
    # Tinted: grayscale content on dark; system applies its own tint.
    save(render(1024, (20, 22, 30), (20, 22, 30), mono=True).convert("RGB"),
         os.path.join(IOS_ICONSET, "icon-1024-tinted.png"))

    contents = '''{
  "images" : [
    {
      "filename" : "icon-1024.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "dark"
        }
      ],
      "filename" : "icon-1024-dark.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    },
    {
      "appearances" : [
        {
          "appearance" : "luminosity",
          "value" : "tinted"
        }
      ],
      "filename" : "icon-1024-tinted.png",
      "idiom" : "universal",
      "platform" : "ios",
      "size" : "1024x1024"
    }
  ],
  "info" : {
    "author" : "xcode",
    "version" : 1
  }
}
'''
    with open(os.path.join(IOS_ICONSET, "Contents.json"), "w") as f:
        f.write(contents)
    print("  wrote", os.path.relpath(os.path.join(IOS_ICONSET, "Contents.json"), ROOT))


# ---- Android / Wear OS -----------------------------------------------------
# Legacy launcher sizes and adaptive foreground sizes per density.
LEGACY = {"mdpi": 48, "hdpi": 72, "xhdpi": 96, "xxhdpi": 144, "xxxhdpi": 192}
FG = {"mdpi": 108, "hdpi": 162, "xhdpi": 216, "xxhdpi": 324, "xxxhdpi": 432}


def gen_android():
    print("Android/Wear icons:")
    for dens, sz in LEGACY.items():
        d = os.path.join(ANDROID_RES, f"mipmap-{dens}")
        full = render(sz, INDIGO, CYAN)
        # square legacy
        save(full.convert("RGB"), os.path.join(d, "ic_launcher.png"))
        # round legacy (Wear OS uses this): apply circular mask
        rnd = full.copy()
        rnd.putalpha(circle_mask(sz))
        save(rnd, os.path.join(d, "ic_launcher_round.png"))
        # adaptive foreground: motif only, transparent, inside safe zone (~0.66)
        fg = render(FG[dens], INDIGO, CYAN, transparent_bg=True, content_scale=0.66)
        save(fg, os.path.join(d, "ic_launcher_foreground.png"))

    # adaptive background as a scalable vector gradient
    bg_vec = '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="108dp"
    android:height="108dp"
    android:viewportWidth="108"
    android:viewportHeight="108">
    <path android:pathData="M0,0 h108 v108 h-108 z">
        <aapt:attr xmlns:aapt="http://schemas.android.com/aapt" name="android:fillColor">
            <gradient
                android:startX="0" android:startY="0"
                android:endX="108" android:endY="108"
                android:type="linear">
                <item android:offset="0.0" android:color="#FF4F46E5" />
                <item android:offset="1.0" android:color="#FF06B6D4" />
            </gradient>
        </aapt:attr>
    </path>
</vector>
'''
    save_text(os.path.join(ANDROID_RES, "drawable", "ic_launcher_background.xml"), bg_vec)

    adaptive = '''<?xml version="1.0" encoding="utf-8"?>
<adaptive-icon xmlns:android="http://schemas.android.com/apk/res/android">
    <background android:drawable="@drawable/ic_launcher_background" />
    <foreground android:drawable="@mipmap/ic_launcher_foreground" />
</adaptive-icon>
'''
    save_text(os.path.join(ANDROID_RES, "mipmap-anydpi-v26", "ic_launcher.xml"), adaptive)
    save_text(os.path.join(ANDROID_RES, "mipmap-anydpi-v26", "ic_launcher_round.xml"), adaptive)

    # monochrome white status-bar icon for the foreground-service notification
    stat = '''<?xml version="1.0" encoding="utf-8"?>
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    android:width="24dp"
    android:height="24dp"
    android:viewportWidth="24"
    android:viewportHeight="24"
    android:tint="#FFFFFFFF">
    <path
        android:fillColor="#FFFFFFFF"
        android:pathData="M2,12 h6 l2,-5 l3,10 l2,-5 h7"
        android:strokeColor="#FFFFFFFF"
        android:strokeWidth="2"
        android:strokeLineCap="round"
        android:strokeLineJoin="round" />
</vector>
'''
    save_text(os.path.join(ANDROID_RES, "drawable", "ic_stat_pulse.xml"), stat)


def save_text(path, text):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w") as f:
        f.write(text)
    print("  wrote", os.path.relpath(path, ROOT))


if __name__ == "__main__":
    gen_ios()
    gen_android()
    print("done.")
