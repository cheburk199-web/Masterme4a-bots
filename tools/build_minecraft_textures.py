#!/usr/bin/env python3
"""Extract vanilla Minecraft Java 1.21.4 block textures from Mojang's client jar."""
import concurrent.futures
import json
import urllib.request
import zipfile
from io import BytesIO
from pathlib import Path
from PIL import Image

VERSION = "1.21.4"
OUT = Path("assets/minecraft")
TILE = 16
COLS = 64
ATLAS = OUT / "block_atlas.png"
INDEX = OUT / "block_textures.json"

def fetch_json(url):
    request = urllib.request.Request(url, headers={"User-Agent": "MASTERME4A-asset-builder/1.0"})
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = fetch_json("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
    version = next((item for item in manifest["versions"] if item["id"] == VERSION), None)
    if version is None:
        raise SystemExit("Minecraft version not found: " + VERSION)
    metadata = fetch_json(version["url"])
    client_url = metadata["downloads"]["client"]["url"]
    request = urllib.request.Request(client_url, headers={"User-Agent": "MASTERME4A-asset-builder/1.0"})
    with urllib.request.urlopen(request, timeout=180) as response:
        jar_bytes = response.read()
    with zipfile.ZipFile(BytesIO(jar_bytes)) as jar:
        paths = sorted(
            name for name in jar.namelist()
            if name.startswith("assets/minecraft/textures/block/") and name.endswith(".png")
            and name.count("/") == 4
        )
        if not paths:
            raise SystemExit("No block textures found inside the official Minecraft client jar")
        images = {}
        for path in paths:
            try:
                images[path.removeprefix("assets/minecraft/textures/block/").removesuffix(".png")] = Image.open(BytesIO(jar.read(path))).convert("RGBA")
            except Exception as error:
                print("Skipping", path, error)
    names = sorted(images)
    rows = (len(names) + COLS - 1) // COLS
    atlas = Image.new("RGBA", (COLS * TILE, rows * TILE), (0, 0, 0, 0))
    mapping = {"version": VERSION, "tileSize": TILE, "columns": COLS, "rows": rows, "textures": {}}
    for index, name in enumerate(names):
        x, y = (index % COLS) * TILE, (index // COLS) * TILE
        image = images[name]
        if image.size != (TILE, TILE):
            image.thumbnail((TILE, TILE), Image.Resampling.NEAREST)
            tile = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
            tile.alpha_composite(image, ((TILE-image.width)//2, (TILE-image.height)//2))
            image = tile
        atlas.alpha_composite(image, (x, y))
        mapping["textures"][name] = {"u": x / atlas.width, "v": y / atlas.height,
                                     "width": TILE / atlas.width, "height": TILE / atlas.height}
    atlas.save(ATLAS, optimize=True)
    INDEX.write_text(json.dumps(mapping, separators=(",", ":")), encoding="utf-8")
    print(f"Packed {len(names)} vanilla block textures into {ATLAS} ({atlas.width}x{atlas.height})")

if __name__ == "__main__":
    main()
