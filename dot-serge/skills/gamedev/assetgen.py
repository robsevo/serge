#!/usr/bin/env python3
"""assetgen — deterministic procedural game assets, $0 (B.3, 2026-07-21).

Run with the office-venv python (Pillow + numpy live there):
  ~/.serge/office-venv/bin/python3 assetgen.py <cmd> ...

Commands:
  sprite  OUT.png --seed N [--size 16] [--frames 4]
      Mirrored half-grid creature sprites (the classic procgen look), one row
      of `frames` animation variants, transparent background.
  tileset OUT.png --seed N [--size 16] [--tiles 8]
      One-row tile atlas: solid / border / checker / speckle variants derived
      from a seeded palette.
  sfx     OUT.wav --kind jump|coin|hit|explosion|powerup --seed N
      16-bit mono PCM at 22050 Hz via numpy synthesis (sweeps, blips, noise
      envelopes). stdlib `wave` writer — no soundfile dependency.

Determinism contract: same args + same seed ⇒ byte-identical output (PNG via
Pillow with fixed encoder args; WAV is raw PCM). Different seed ⇒ different
asset. All failures are LOUD (nonzero exit + message); no silent defaults.
"""
import argparse
import sys
import wave

try:
    import numpy as np
    from PIL import Image
except ImportError as e:
    sys.exit(f"assetgen: missing dependency ({e}) — run with ~/.serge/office-venv/bin/python3")

SR = 22050


def rng_for(seed):
    return np.random.default_rng(seed)


def palette(rng):
    hue = rng.uniform(0, 1)
    def col(l, s=0.8):
        import colorsys
        r, g, b = colorsys.hls_to_rgb(hue, l, s)
        return (int(r * 255), int(g * 255), int(b * 255), 255)
    return [col(0.25), col(0.45), col(0.7)]


def gen_sprite(out, seed, size, frames):
    rng = rng_for(seed)
    pal = palette(rng)
    sheet = Image.new("RGBA", (size * frames, size), (0, 0, 0, 0))
    half = size // 2
    base = rng.random((size, half))
    for f in range(frames):
        # each frame jitters the base mask so frames read as animation
        mask = (base + rng.random((size, half)) * 0.35) > 0.55
        shade = rng.integers(0, len(pal), (size, half))
        img = Image.new("RGBA", (size, size), (0, 0, 0, 0))
        px = img.load()
        for y in range(size):
            for x in range(half):
                if mask[y][x]:
                    c = pal[int(shade[y][x])]
                    px[x, y] = c
                    px[size - 1 - x, y] = c  # mirror → bilateral creature
        sheet.paste(img, (f * size, 0))
    sheet.save(out, format="PNG", optimize=False)
    print(f"sprite sheet: {out} ({size * frames}x{size}, {frames} frames, seed={seed})")


def gen_tileset(out, seed, size, tiles):
    rng = rng_for(seed)
    pal = palette(rng)
    atlas = Image.new("RGBA", (size * tiles, size), (0, 0, 0, 255))
    px = atlas.load()
    for t in range(tiles):
        kind = t % 4
        c0, c1 = pal[t % len(pal)], pal[(t + 1) % len(pal)]
        noise = rng.random((size, size))
        for y in range(size):
            for x in range(size):
                if kind == 0:      # solid
                    c = c0
                elif kind == 1:    # border
                    c = c1 if (x in (0, size - 1) or y in (0, size - 1)) else c0
                elif kind == 2:    # checker
                    c = c0 if (x // 4 + y // 4) % 2 == 0 else c1
                else:              # speckle
                    c = c1 if noise[y][x] > 0.8 else c0
                px[t * size + x, y] = c
    atlas.save(out, format="PNG", optimize=False)
    print(f"tileset: {out} ({size * tiles}x{size}, {tiles} tiles, seed={seed})")


def env(n, attack=0.01, decay=4.0):
    t = np.linspace(0, 1, n, endpoint=False)
    a = np.minimum(t / max(attack, 1e-4), 1.0)
    return a * np.exp(-decay * t)


def gen_sfx(out, kind, seed):
    rng = rng_for(seed)
    t = None
    if kind == "jump":
        n = int(SR * 0.25)
        t = np.linspace(0, 0.25, n, endpoint=False)
        f = 220 + 660 * (t / 0.25)                     # rising sweep
        sig = np.sin(2 * np.pi * np.cumsum(f) / SR) * env(n, decay=3)
    elif kind == "coin":
        n = int(SR * 0.18)
        t = np.linspace(0, 0.18, n, endpoint=False)
        f = np.where(t < 0.06, 988.0, 1319.0)          # B5 → E6 blip
        sig = np.sign(np.sin(2 * np.pi * np.cumsum(f) / SR)) * 0.6 * env(n, decay=5)
    elif kind == "hit":
        n = int(SR * 0.15)
        sig = rng.uniform(-1, 1, n) * env(n, attack=0.002, decay=12)
    elif kind == "explosion":
        n = int(SR * 0.8)
        noise = rng.uniform(-1, 1, n)
        kernel = np.ones(64) / 64                       # cheap low-pass rumble
        sig = np.convolve(noise, kernel, mode="same") * env(n, decay=3) * 1.6
    elif kind == "powerup":
        n = int(SR * 0.45)
        t = np.linspace(0, 0.45, n, endpoint=False)
        steps = np.array([262, 330, 392, 523, 659, 784])   # C-major arpeggio
        f = steps[np.minimum((t / 0.075).astype(int), len(steps) - 1)]
        sig = np.sin(2 * np.pi * np.cumsum(f) / SR) * env(n, decay=1.5)
    else:
        sys.exit(f"assetgen: unknown sfx kind {kind!r} — one of jump|coin|hit|explosion|powerup")
    pcm = np.clip(sig, -1, 1)
    pcm = (pcm * 32767).astype("<i2")
    with wave.open(out, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(SR)
        w.writeframes(pcm.tobytes())
    print(f"sfx: {out} ({kind}, {len(pcm) / SR:.2f}s @ {SR} Hz, seed={seed})")


def main():
    p = argparse.ArgumentParser(prog="assetgen")
    sub = p.add_subparsers(dest="cmd", required=True)
    sp = sub.add_parser("sprite");  sp.add_argument("out"); sp.add_argument("--seed", type=int, required=True); sp.add_argument("--size", type=int, default=16); sp.add_argument("--frames", type=int, default=4)
    tp = sub.add_parser("tileset"); tp.add_argument("out"); tp.add_argument("--seed", type=int, required=True); tp.add_argument("--size", type=int, default=16); tp.add_argument("--tiles", type=int, default=8)
    fp = sub.add_parser("sfx");     fp.add_argument("out"); fp.add_argument("--kind", required=True); fp.add_argument("--seed", type=int, required=True)
    a = p.parse_args()
    if a.cmd == "sprite":
        if a.size < 4 or a.size % 2 or a.frames < 1:
            sys.exit("assetgen: sprite --size must be even and >=4, --frames >=1")
        gen_sprite(a.out, a.seed, a.size, a.frames)
    elif a.cmd == "tileset":
        if a.size < 4 or a.tiles < 1:
            sys.exit("assetgen: tileset --size >=4 and --tiles >=1 required")
        gen_tileset(a.out, a.seed, a.size, a.tiles)
    elif a.cmd == "sfx":
        gen_sfx(a.out, a.kind, a.seed)


if __name__ == "__main__":
    main()
