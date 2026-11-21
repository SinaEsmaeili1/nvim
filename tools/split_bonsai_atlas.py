"""Split assets/bonsai/bonsai-atlas.png into one PNG per frame, for kitty.

kitty reads each frame file directly when the Bonsai logo is uploaded
(lua/bonsai/ui/kitty.lua), so Neovim never sends image data itself.
Run from the config folder:  python3 tools/split_bonsai_atlas.py
Writes assets/bonsai/frames/<state>/NN.png (00 to 47 for each state).
"""
import json
from pathlib import Path

from PIL import Image

root = Path(__file__).resolve().parent.parent / "assets" / "bonsai"
meta = json.loads((root / "bonsai-atlas.json").read_text())
atlas = Image.open(root / meta["image"]).convert("RGBA")
w, h, cols = meta["frameWidth"], meta["frameHeight"], meta["columns"]

for state, info in meta["states"].items():
    out = root / "frames" / state
    out.mkdir(parents=True, exist_ok=True)
    for local in range(info["frameCount"]):
        i = info["firstFrame"] + local
        x, y = (i % cols) * w, (i // cols) * h
        atlas.crop((x, y, x + w, y + h)).save(out / f"{local:02d}.png", optimize=True)

print("frames written to", root / "frames")
