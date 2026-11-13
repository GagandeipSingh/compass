"""Renders the Compass app icon, adaptive-icon layers and the plain native
splash images into assets/. Original artwork: a dark graphite tile, a
brushed-metal bezel, a deep face and a bevelled two-tone needle.

Drawn at 4x and downsampled, so every edge is antialiased.

    python tool/make_icons.py
"""

import math
import os

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = os.path.dirname(os.path.abspath(__file__))
OUT = os.path.join(HERE, '..', 'assets')
SS = 4  # supersample factor


def polar(size):
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    c = size / 2
    dx, dy = x - c, y - c
    return np.sqrt(dx * dx + dy * dy) / size, np.arctan2(dy, dx)


def rgba(arr):
    return Image.fromarray(np.clip(arr, 0, 255).astype(np.uint8), 'RGBA')


def tile_background(size, span=1.0):
    """Graphite tile: top-lit vertical gradient + soft radial glow.

    [span] is the fraction of the canvas actually seen. The adaptive icon's
    launcher mask shows only the middle 72 of 108 dp, so the gradient is
    stretched over that window; spread over the whole canvas, the visible
    part ran 41 -> 18 and read as flat beside the bright dial.
    """
    y = np.linspace(0, 1, size, dtype=np.float32)[:, None]
    y = np.clip((y - (1 - span) / 2) / span, 0, 1)
    # Soft graphite, a touch darker than a mid-grey tile: dark enough to
    # frame the bright dial, light enough that the gradient reads.
    top = np.array([60, 62, 68], np.float32)
    bot = np.array([32, 33, 37], np.float32)
    col = top * (1 - y[..., None]) + bot * y[..., None]
    col = np.broadcast_to(col, (size, size, 3)).copy()
    r, _ = polar(size)
    glow = np.clip(1 - r / 0.55, 0, 1) ** 2 * 14
    col += glow[..., None]
    a = np.full((size, size, 1), 255, np.float32)
    return rgba(np.concatenate([col, a], -1))


def dial(size):
    """The compass mark alone on transparency: bezel, face, ticks, needle."""
    r, th = polar(size)
    img = np.zeros((size, size, 4), np.float32)

    R_OUT, R_IN, R_FACE = 0.40, 0.335, 0.325

    # Bezel: brushed metal, lit from the top-left.
    ring = (r <= R_OUT) & (r >= R_IN)
    light = 0.5 + 0.5 * np.cos(th - (-math.pi * 0.75))
    brush = 0.04 * np.sin(th * 90)
    # Bright enough to read on a dimmed screen against the dark tile.
    shade = 0.70 + 0.40 * light + brush
    edge = np.clip(1 - np.abs(r - (R_OUT + R_IN) / 2) / ((R_OUT - R_IN) / 2), 0, 1)
    shade *= 0.80 + 0.20 * edge ** 0.5
    metal = np.stack([shade * 232, shade * 234, shade * 240], -1)
    img[ring, :3] = metal[ring]
    img[ring, 3] = 255

    # Face: deep, darkening toward the rim, inner shadow under the bezel.
    face = r < R_IN
    t = np.clip(r / R_FACE, 0, 1)
    base = 56 * (1 - t ** 1.6) + 36
    inner_shadow = np.clip((r - (R_IN - 0.03)) / 0.03, 0, 1) * 6
    fc = np.clip(base - inner_shadow, 0, 255)
    img[face, 0] = fc[face]
    img[face, 1] = fc[face] + 1
    img[face, 2] = fc[face] + 4
    img[face, 3] = 255

    out = rgba(img)
    d = ImageDraw.Draw(out)
    c = size / 2

    # Ticks on the face edge: every 10 degrees, cardinals longer.
    for deg in range(0, 360, 10):
        a = math.radians(deg - 90)
        major = deg % 90 == 0
        r1 = (R_FACE - 0.012) * size
        r0 = r1 - (0.05 if major else 0.028) * size
        w = int((0.012 if major else 0.007) * size)
        col = (255, 69, 58, 255) if deg == 0 else (235, 235, 240, 255 if major else 200)
        d.line([(c + r0 * math.cos(a), c + r0 * math.sin(a)),
                (c + r1 * math.cos(a), c + r1 * math.sin(a))], fill=col, width=w)

    # Needle, tilted for life, with a soft drop shadow.
    tilt = math.radians(38)
    L, W = 0.255 * size, 0.058 * size

    def pt(along, across):
        ax, ay = math.sin(tilt), -math.cos(tilt)  # needle axis (north)
        px, py = -ay, ax                           # perpendicular
        return (c + along * ax + across * px, c + along * ay + across * py)

    north = [pt(L, 0), pt(0, -W), pt(0, W)]
    south = [pt(-L, 0), pt(0, -W), pt(0, W)]

    shadow = Image.new('RGBA', out.size, (0, 0, 0, 0))
    sd = ImageDraw.Draw(shadow)
    off = 0.018 * size
    for poly in (north, south):
        sd.polygon([(x + off * 0.6, y + off) for x, y in poly], fill=(0, 0, 0, 200))
    shadow = shadow.filter(ImageFilter.GaussianBlur(0.014 * size))
    out = Image.alpha_composite(out, shadow)
    d = ImageDraw.Draw(out)

    # Two facets per half: the lit side and the shaded side make the bevel.
    d.polygon([pt(L, 0), pt(0, -W), pt(0, 0)], fill=(255, 92, 80, 255))
    d.polygon([pt(L, 0), pt(0, W), pt(0, 0)], fill=(218, 48, 40, 255))
    d.polygon([pt(-L, 0), pt(0, -W), pt(0, 0)], fill=(246, 246, 250, 255))
    d.polygon([pt(-L, 0), pt(0, W), pt(0, 0)], fill=(176, 178, 186, 255))

    # Centre cap: metal dome with a specular dot.
    cap = 0.038 * size
    capimg = np.zeros((size, size, 4), np.float32)
    y, x = np.mgrid[0:size, 0:size].astype(np.float32)
    dx, dy = (x - c) / cap, (y - c) / cap
    rr = np.sqrt(dx * dx + dy * dy)
    inside = rr <= 1
    hl = np.clip(1 - np.sqrt((dx + 0.35) ** 2 + (dy + 0.4) ** 2) / 1.2, 0, 1)
    v = 110 + 130 * hl
    capimg[inside, 0] = v[inside]
    capimg[inside, 1] = v[inside]
    capimg[inside, 2] = v[inside] + 6
    capimg[inside, 3] = 255
    out = Image.alpha_composite(out, rgba(capimg))

    # Glass: faint gloss over the upper face.
    gloss = np.zeros((size, size, 4), np.float32)
    gy = (y - c) / size
    gx = (x - c) / size
    g = (np.sqrt((gx / 0.30) ** 2 + ((gy + 0.16) / 0.17) ** 2) <= 1) & (r < R_IN)
    fade = np.clip(1 - (gy + 0.33) / 0.30, 0, 1)
    gloss[g, :3] = 255
    gloss[g, 3] = (fade[g] * 22)
    out = Image.alpha_composite(out, rgba(gloss))
    return out


def down(img, size):
    return img.resize((size, size), Image.LANCZOS)


def main():
    os.makedirs(OUT, exist_ok=True)
    S = 1024 * SS
    mark = dial(S)

    # Full tile (launcher icon): the mark scaled up 8.5% so the compass fills more of the tile.
    big = mark.resize((int(S * 1.085),) * 2, Image.LANCZOS)
    o = (big.width - S) // 2
    tile = tile_background(S)
    tile = Image.alpha_composite(tile, big.crop((o, o, o + S, o + S)))
    down(tile.convert('RGB'), 1024).save(os.path.join(OUT, 'icon-1024.png'))

    # Adaptive layers: ring at ~25% of the canvas radius-wise, about three
    # quarters of the ~33% the launcher mask shows, leaving a clear gap.
    fg = Image.new('RGBA', (S, S), (0, 0, 0, 0))
    m = down(mark, int(S * 0.61))
    fg.alpha_composite(m, ((S - m.width) // 2, (S - m.height) // 2))
    down(fg, 1024).save(os.path.join(OUT, 'icon-foreground-1024.png'))
    down(tile_background(S, span=72 / 108).convert('RGB'), 1024).save(
        os.path.join(OUT, 'icon-background-1024.png'))

    # Native splash: plain full-screen soft white (light) and deep navy
    # (dark), no icon. The app opens straight onto the compass after it.
    # Colours match pubspec's flutter_native_splash block.
    for name, bg in (('splash_light.png', (0xEE, 0xF1, 0xF8)),
                     ('splash_dark.png', (0x06, 0x0A, 0x18))):
        Image.new('RGB', (864, 864), bg).save(os.path.join(OUT, name))
    print('icons written to', os.path.normpath(OUT))


if __name__ == '__main__':
    main()
