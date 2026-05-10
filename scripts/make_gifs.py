"""Build 9 state GIFs from sprite sheets in assets/source/.

Each source PNG is a single horizontal strip — N equal-width frames of one
chibi state. We slice it, key out the white background using a magenta-key
trick, and save an animated GIF with palette index 255 marked transparent.

Usage:
  pdm run python scripts/make_gifs.py            # regenerate all
  pdm run python scripts/make_gifs.py celebrate  # regenerate one

The magenta-key approach exists because PIL's RGBA→GIF quantizer cannot be
told reliably which palette index ends up as the transparent color. By
forcing palette[255] = #FF00FF (a unique color absent from chibi art) and
pasting that index over the alpha-zero region, the saved GIF's transparency
metadata always points at our key color, regardless of source palette.
"""
from __future__ import annotations

import sys
from pathlib import Path
from typing import Iterable

from PIL import Image, ImageOps

ROOT = Path(__file__).parent.parent
SRC_DIR = ROOT / "assets" / "source"
OUT_DIR = ROOT / "assets" / "gifs"

# (state, frame count, ms per frame, ping-pong playback)
STATES: list[tuple[str, int, int, bool]] = [
    ("idle_blink",  6, 180, True),
    ("coding",      6, 120, False),
    ("peek",        8, 150, True),
    ("loading",     6, 180, False),
    ("fix_bug",     6, 160, False),
    ("error_shrug", 8, 150, False),
    ("celebrate",   5, 140, False),
    ("supervise",   8, 150, False),
    ("sleep",       4, 250, True),
]

WHITE_THRESHOLD = 235  # any pixel with R,G,B all ≥ this is treated as background


def slice_rgba(img: Image.Image, n: int) -> list[Image.Image]:
    w, h = img.size
    fw = w // n
    return [img.crop((i * fw, 0, (i + 1) * fw, h)).convert("RGBA") for i in range(n)]


def to_transparent_p(rgba: Image.Image) -> Image.Image:
    """Convert one RGBA frame into a P-mode frame with palette index 255 = transparent."""
    px = rgba.load()
    w, h = rgba.size

    # Binary alpha mask: 0 where the pixel is near-white (transparent), 255 elsewhere.
    mask_data = bytearray(w * h)
    for y in range(h):
        for x in range(w):
            r, g, b, _ = px[x, y]
            if r > WHITE_THRESHOLD and g > WHITE_THRESHOLD and b > WHITE_THRESHOLD:
                mask_data[y * w + x] = 0
            else:
                mask_data[y * w + x] = 255
    mask = Image.frombytes("L", (w, h), bytes(mask_data))

    # Quantize RGB to 255 colors so palette slot 255 stays free for the key color.
    rgb = rgba.convert("RGB")
    p = rgb.quantize(colors=255, method=Image.FASTOCTREE)

    palette = list(p.getpalette() or [])
    while len(palette) < 768:
        palette.append(0)
    palette[255 * 3 : 255 * 3 + 3] = [255, 0, 255]  # magenta key
    p.putpalette(palette[:768])

    # Paint palette index 255 over every transparent pixel.
    p.paste(255, mask=ImageOps.invert(mask))
    p.info["transparency"] = 255
    return p


def build_gif(state: str, frames: int, duration: int, pingpong: bool) -> Path:
    src = SRC_DIR / f"{state}.png"
    out = OUT_DIR / f"{state}.gif"
    if not src.exists():
        raise FileNotFoundError(f"missing source sprite: {src}")

    raw = slice_rgba(Image.open(src), frames)
    p_frames = [to_transparent_p(f) for f in raw]
    if pingpong and len(p_frames) > 2:
        p_frames = p_frames + p_frames[-2:0:-1]

    p_frames[0].save(
        out,
        save_all=True,
        append_images=p_frames[1:],
        duration=duration,
        loop=0,
        disposal=2,
        transparency=255,
        optimize=False,
    )
    return out


def main(targets: Iterable[str] | None = None) -> None:
    OUT_DIR.mkdir(parents=True, exist_ok=True)
    selected = set(targets) if targets else None
    built = 0
    for state, n, dur, pp in STATES:
        if selected and state not in selected:
            continue
        out = build_gif(state, n, dur, pp)
        size_kb = out.stat().st_size // 1024
        print(f"  {out.name:18s} {len(slice_rgba(Image.open(SRC_DIR / f'{state}.png'), n)):>2d} frames"
              f"  {size_kb:>5d} KB  {'pingpong' if pp else 'one-shot'}")
        built += 1
    if built == 0 and selected:
        raise SystemExit(f"no states matched {sorted(selected)}; valid: {[s[0] for s in STATES]}")
    print(f"done. wrote {built} gif(s) to {OUT_DIR.relative_to(ROOT)}/")


if __name__ == "__main__":
    main(sys.argv[1:] or None)
