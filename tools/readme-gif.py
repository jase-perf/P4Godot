"""Put the README's animated GIF together from the frames gui-readme saves.

    uv run --no-project --with pillow python tools/readme-gif.py <shots>/gif docs/images/hero-checkout.gif

<shots>/gif/frames.txt starts with "crop X Y W H" (the part of the editor the
GIF shows), then one "NNNN.png MILLISECONDS" line per frame.
"""
import sys
from pathlib import Path

from PIL import Image

WIDTH = 860  # the README shows images at up to 850 px

frames_dir, out = Path(sys.argv[1]), Path(sys.argv[2])
lines = (frames_dir / "frames.txt").read_text().split("\n")
x, y, w, h = (int(v) for v in lines[0].split()[1:])
images, durations = [], []
for line in lines[1:]:
    if not line.strip():
        continue
    name, ms = line.split()
    img = Image.open(frames_dir / name).convert("RGB").crop((x, y, x + w, y + h))
    if img.width > WIDTH:
        img = img.resize((WIDTH, round(img.height * WIDTH / img.width)), Image.LANCZOS)
    images.append(img)
    durations.append(int(ms))

# One palette for every frame, from all of them: the editor's colours stay
# put instead of shimmering from frame to frame.
sheet = Image.new("RGB", (images[0].width, images[0].height * len(images)))
for i, img in enumerate(images):
    sheet.paste(img, (0, i * img.height))
palette = sheet.quantize(colors=255, method=Image.Quantize.MEDIANCUT)
frames = [img.quantize(palette=palette, dither=Image.Dither.NONE) for img in images]
frames[0].save(out, save_all=True, append_images=frames[1:], duration=durations, loop=0,
               optimize=True, disposal=1)
print(f"{out}: {len(frames)} frames, {sum(durations) / 1000:.1f} s, {out.stat().st_size // 1024} KB")
