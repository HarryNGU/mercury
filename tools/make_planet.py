#!/usr/bin/env python3
"""Draws Mercury's planet logo. Run: python3 tools/make_planet.py

Writes docs/assets/planet.png (the planet alone, transparent), docs/assets/favicon.png,
docs/assets/icon.png, Planet.png (the logo inside the app) and AppIcon.icns (the planet on a
dark Mac icon tile). With --texture it writes docs/assets/mercury-map.jpg instead, the map the
website wraps around its spinning planet.
The colours follow the enhanced colour photos of Mercury: deep blue plains, gold and tan
highlands, pale blue young craters and one bright crater with long rays.
"""
import subprocess, tempfile
from pathlib import Path
import numpy as np
from PIL import Image, ImageFilter

ROOT = Path(__file__).resolve().parent.parent
rng = np.random.default_rng(7)


def noise3(p, freq, octaves=6, seed=0):
    """Value noise on the sphere, summed over octaves (fbm). p: (N,3) unit vectors."""
    r = np.random.default_rng(seed)
    total = np.zeros(len(p)); amp = 1.0; norm = 0.0
    for o in range(octaves):
        f = freq * 2 ** o
        q = p * f + r.uniform(0, 100, 3)
        i = np.floor(q).astype(np.int64); t = q - i
        t = t * t * (3 - 2 * t)
        def h(dx, dy, dz):
            n = (i[:, 0] + dx) * 73856093 ^ (i[:, 1] + dy) * 19349663 ^ (i[:, 2] + dz) * 83492791 ^ (o * 2654435761)
            n = (n ^ (n >> 13)) * 1274126177
            return ((n ^ (n >> 16)) & 0xFFFF) / 65535.0
        c = 0
        for dx in (0, 1):
            for dy in (0, 1):
                for dz in (0, 1):
                    w = (t[:, 0] if dx else 1 - t[:, 0]) * (t[:, 1] if dy else 1 - t[:, 1]) * (t[:, 2] if dz else 1 - t[:, 2])
                    c = c + w * h(dx, dy, dz)
        total += amp * c; norm += amp; amp *= 0.52
    return total / norm


def worley(p, freq, seed):
    """Distance to the nearest random point in a 3D grid, plus a random value for that point."""
    q = p * freq; i = np.floor(q).astype(np.int64)
    best = np.full(len(p), 9.0); val = np.zeros(len(p)); off = np.zeros((len(p), 3))
    for dx in (-1, 0, 1):
        for dy in (-1, 0, 1):
            for dz in (-1, 0, 1):
                c = i + np.array([dx, dy, dz])
                n = (c[:, 0] * 73856093) ^ (c[:, 1] * 19349663) ^ (c[:, 2] * 83492791) ^ (seed * 2654435761)
                pts = []
                for k in range(4):
                    n = (n ^ (n >> 13)) * 1274126177 + 12345
                    pts.append(((n ^ (n >> 16)) & 0xFFFF) / 65535.0)
                o = q - (c + np.stack(pts[:3], 1))
                d = np.linalg.norm(o, axis=1)
                closer = d < best
                best = np.where(closer, d, best); val = np.where(closer, pts[3], val)
                off = np.where(closer[:, None], o, off)
    return best, val, off


def rays(q, c, count, length, width, seed):
    r = np.random.default_rng(seed)
    patch = noise3(q, 14.0, 4, seed + 40)
    ang = np.arccos(np.clip(q @ c, -1, 1))
    ref = np.cross(c, [0.3, 1, 0.1]); ref /= np.linalg.norm(ref); ref2 = np.cross(c, ref)
    tang = q - (q @ c)[:, None] * c
    theta = np.arctan2(tang @ ref2, tang @ ref)
    out = np.zeros(len(q))
    for _ in range(count):
        th = r.uniform(-np.pi, np.pi); w = width * r.uniform(0.4, 1.6); L = length * r.uniform(0.3, 1.2)
        dth = np.angle(np.exp(1j * (theta - th)))
        out += np.exp(-(dth / (w / (0.12 + ang))) ** 2) * np.exp(-ang / L) * r.uniform(0.1, 0.45)
    core = np.exp(-(ang / 0.025) ** 2); halo = np.exp(-(ang / 0.07) ** 2)
    out *= np.clip((patch - 0.25) * 2.0, 0.15, 1.4)
    return np.clip(out * np.clip(ang / 0.04, 0, 1) + halo * 0.55 + core * 0.9, 0, 1.4)


A = 0.5
R = np.array([[np.cos(A), 0, np.sin(A)], [0, 1, 0], [-np.sin(A), 0, np.cos(A)]])


def surface(q):
    """The planet's colour at points q on the unit sphere (before sunlight)."""

    warp = np.stack([noise3(q, 2.0, 3, s_) for s_ in (11, 12, 13)], 1) - 0.5
    qw = q + warp * 0.3
    base = noise3(qw, 1.7, 7, 1)           # broad blue vs tan provinces
    light = noise3(qw, 3.2, 6, 3)          # pale streaky regions
    grain = noise3(q, 22.0, 3, 2)          # fine surface grain
    deep = np.array([0.13, 0.24, 0.66]); blue = np.array([0.30, 0.45, 0.86]); pale = np.array([0.62, 0.74, 0.93])
    gold = np.array([0.92, 0.70, 0.38]); tan = np.array([0.66, 0.54, 0.46]); cream = np.array([0.90, 0.86, 0.74])
    t = np.clip((base - 0.36) / 0.30, 0, 1)[:, None]
    col = deep * (1 - t) + blue * t
    g = np.clip((base - 0.55) / 0.10, 0, 1)[:, None]
    col = col * (1 - g) + tan * g
    gg = np.clip((base - 0.63) / 0.08, 0, 1)[:, None]
    col = col * (1 - gg) + gold * gg
    l = np.clip((light - 0.52) / 0.15, 0, 1)[:, None] * 0.6
    col = col * (1 - l) + pale * l
    col *= (0.80 + 0.40 * grain)[:, None]

    # craters from three sizes of cellular noise, shaded as bowls lit from the upper left
    Lc = np.array([-0.6, 0.7, 0.4]); Lc /= np.linalg.norm(Lc)
    for freq, seed, strength in ((6, 21, 1.0), (13, 22, 0.85), (29, 23, 0.7), (60, 24, 0.5)):
        d, val, off = worley(q, freq, seed)
        keep = val > 0.3
        rad = 0.16 + 0.26 * val
        x = d / rad
        tilt = (off @ Lc) / np.maximum(d, 1e-6)          # +1 on the side facing the light
        bowl = np.clip(1 - x, 0, 1)
        rim = np.exp(-((x - 1) / 0.22) ** 2)
        relief = (-tilt * bowl ** 0.7 * 0.55 + tilt * rim * 0.35) * keep * strength
        col *= (1 + relief)[:, None]
        fresh = np.exp(-(x / 0.45) ** 2) * (val > 0.9)
        col = col * (1 - 0.5 * fresh * strength)[:, None] + pale * (0.9 * fresh * strength)[:, None]

    # the big ray crater just below the middle, and a second one lower right
    c1 = R @ (np.array([0.05, -0.08, 1.0]) / np.linalg.norm([0.05, -0.08, 1.0]))
    c2 = R @ (np.array([0.62, -0.42, 0.66]) / np.linalg.norm([0.62, -0.42, 0.66]))
    col += np.array([0.98, 0.95, 0.82]) * (rays(q, c1, 90, 0.6, 0.04, 5) * 0.85)[:, None]
    col += np.array([0.75, 0.86, 1.0]) * (rays(q, c2, 40, 0.25, 0.04, 6) * 0.4)[:, None]
    return col


def planet(size):
    s = size * 2  # supersample, then shrink for smooth edges
    y, x = np.mgrid[0:s, 0:s]
    u = (x + 0.5) / s * 2 - 1; v = 1 - (y + 0.5) / s * 2
    r2 = u * u + v * v
    inside = r2 <= 1
    z = np.sqrt(np.clip(1 - r2, 0, 1))
    p = np.stack([u[inside], v[inside], z[inside]], 1)
    col = surface(p @ R.T)

    # nearly full lighting like the photo, with a soft limb and a faint blue edge glow
    L = np.array([-0.35, 0.35, 0.87]); L /= np.linalg.norm(L)
    lam = np.clip(p @ L, 0, 1)
    col *= (0.38 + 0.72 * lam)[:, None]
    limb = p[:, 2]
    col *= (0.62 + 0.38 * limb ** 0.6)[:, None]
    col += np.array([0.40, 0.58, 1.0]) * (np.exp(-limb * 10) * 0.28)[:, None]

    img = np.zeros((s, s, 4))
    img[inside, :3] = np.clip(col, 0, 1)
    img[inside, 3] = 1
    return Image.fromarray((img * 255).astype(np.uint8), "RGBA").resize((size, size), Image.LANCZOS)


def tile(size, pl):
    """macOS icon: the planet on a deep space squircle with a few stars and a soft glow."""
    s = size
    y, x = np.mgrid[0:s, 0:s].astype(float)
    inset = s * 100 / 1024; w = s - 2 * inset; rad = s * 185 / 1024
    # squircle mask (rounded rect with continuous corners approximated by superellipse)
    nx = (x + 0.5 - s / 2) / (w / 2); ny = (y + 0.5 - s / 2) / (w / 2)
    m = (np.abs(nx) ** 5 + np.abs(ny) ** 5) <= 1
    bg = np.zeros((s, s, 4))
    d = np.sqrt(((x - s * 0.5) / s) ** 2 + ((y - s * 0.5) / s) ** 2)
    top = np.array([0.075, 0.09, 0.17]); bot = np.array([0.012, 0.015, 0.035])
    t = np.clip((y - inset) / w, 0, 1)[..., None]
    bg[..., :3] = top * (1 - t) + bot * t
    glow = np.exp(-(d / 0.30) ** 2)[..., None] * np.array([0.12, 0.2, 0.5]) * 0.9
    bg[..., :3] += glow
    stars = rng.random((s, s)) > 0.9993
    bg[stars, :3] = 0.8
    bg[..., 3] = m
    base = Image.fromarray((np.clip(bg, 0, 1) * 255).astype(np.uint8), "RGBA").filter(ImageFilter.GaussianBlur(s / 1024 * 0.6))
    ps = int(s * 0.66)
    planet_img = pl.resize((ps, ps), Image.LANCZOS)
    base.alpha_composite(planet_img, ((s - ps) // 2, (s - ps) // 2))
    a = np.array(base); a[..., 3] = (m * 255).astype(np.uint8)
    return Image.fromarray(a, "RGBA")


def texture(w):
    """An equirectangular map of the whole surface, for the spinning planet on the website."""
    h = w // 2
    lat = (0.5 - (np.arange(h) + 0.5) / h) * np.pi
    lon = ((np.arange(w) + 0.5) / w * 2 - 1) * np.pi
    LON, LAT = np.meshgrid(lon, lat)
    q = np.stack([np.cos(LAT) * np.sin(LON), np.sin(LAT), np.cos(LAT) * np.cos(LON)], -1).reshape(-1, 3)
    col = np.clip(surface(q), 0, 1).reshape(h, w, 3)
    return Image.fromarray((col * 255).astype(np.uint8), "RGB")


if __name__ == "__main__":
    import sys
    assets = ROOT / "docs/assets"
    if "--texture" in sys.argv:
        texture(2048).save(assets / "mercury-map.jpg", quality=86, optimize=True, progressive=True)
        raise SystemExit
    pl = planet(1024)
    pl.save(assets / "planet.png", optimize=True)
    pl.resize((64, 64), Image.LANCZOS).save(assets / "favicon.png")
    pl.resize((256, 256), Image.LANCZOS).save(ROOT / "Planet.png")  # the logo inside the app
    icon = tile(1024, pl)
    icon.resize((512, 512), Image.LANCZOS).save(assets / "icon.png")
    with tempfile.TemporaryDirectory() as tmp:
        iset = Path(tmp) / "AppIcon.iconset"; iset.mkdir()
        for n in (16, 32, 128, 256, 512):
            icon.resize((n, n), Image.LANCZOS).save(iset / f"icon_{n}x{n}.png")
            icon.resize((n * 2, n * 2), Image.LANCZOS).save(iset / f"icon_{n}x{n}@2x.png")
        subprocess.run(["iconutil", "-c", "icns", str(iset), "-o", str(ROOT / "AppIcon.icns")], check=True)
    print("done")
