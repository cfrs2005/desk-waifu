"""Build animated banner that shows all 9 states side-by-side.
Run from repo root: pdm run python scripts/make_banner.py
"""
from PIL import Image
from pathlib import Path

ROOT = Path(__file__).parent.parent
SRC = ROOT / "assets" / "gifs"
OUT = ROOT / "assets" / "banner.gif"

ORDER = [
    "idle_blink", "coding", "peek", "loading", "fix_bug",
    "error_shrug", "celebrate", "supervise", "sleep",
]
PANEL = 140              # each panel rendered at 140 px wide
FRAMES = 24              # banner length in frames
DURATION = 110           # ms per frame
GAP = 8                  # px between panels

def load_frames(path: Path):
    im = Image.open(path)
    frames = []
    try:
        while True:
            frames.append(im.copy().convert("RGBA"))
            im.seek(im.tell() + 1)
    except EOFError:
        pass
    return frames

def fit(frame: Image.Image, w: int, h: int) -> Image.Image:
    src_w, src_h = frame.size
    scale = min(w / src_w, h / src_h)
    nw, nh = int(src_w * scale), int(src_h * scale)
    resized = frame.resize((nw, nh), Image.LANCZOS)
    canvas = Image.new("RGBA", (w, h), (0, 0, 0, 0))
    canvas.paste(resized, ((w - nw) // 2, (h - nh) // 2), resized)
    return canvas

print("loading gif sources...")
state_frames = {s: load_frames(SRC / f"{s}.gif") for s in ORDER}
panel_h = int(PANEL * 1.6)  # chibi is taller than wide

banner_w = PANEL * len(ORDER) + GAP * (len(ORDER) - 1)
banner_h = panel_h + 24  # space for state labels under each panel

print(f"banner: {banner_w}x{banner_h}, {FRAMES} frames")

out_frames = []
for i in range(FRAMES):
    canvas = Image.new("RGBA", (banner_w, banner_h), (255, 255, 255, 0))
    for j, state in enumerate(ORDER):
        src = state_frames[state]
        frame = src[i % len(src)]
        panel = fit(frame, PANEL, panel_h)
        x = j * (PANEL + GAP)
        canvas.paste(panel, (x, 0), panel)
    out_frames.append(canvas.convert("RGBA"))

out_frames[0].save(
    OUT,
    save_all=True,
    append_images=out_frames[1:],
    duration=DURATION,
    loop=0,
    disposal=2,
    transparency=0,
    optimize=True,
)
print(f"wrote {OUT.relative_to(ROOT)} ({OUT.stat().st_size // 1024} KB)")
