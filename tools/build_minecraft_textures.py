#!/usr/bin/env python3
"""Download and pack the vanilla Minecraft Java 1.21.4 block textures for Flutter."""
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

def get_json(url):
    req = urllib.request.Request(url, headers={"User-Agent": "MASTERME4A-asset-builder/1.0"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return json.load(response)

def download_texture(item):
    name, meta = item
    url = "https://resources.download.minecraft.net/" + meta["hash"][:2] + "/" + meta["hash"]
    req = urllib.request.Request(url, headers={"User-Agent": "MASTERME4A-asset-builder/1.0"})
    with urllib.request.urlopen(req, timeout=30) as response:
        return name, Image.open(BytesIO(response.read())).convert("RGBA")

def main():
    OUT.mkdir(parents=True, exist_ok=True)
    manifest = get_json("https://piston-meta.mojang.com/mc/game/version_manifest_v2.json")
    version = next((v for v in manifest["versions"] if v["id"] == VERSION), None)
    if not version:
        raise SystemExit("Minecraft version " + VERSION + " is absent from Mojang manifest")
    version_info = get_json(version["url"])
    asset_index = get_json(version_info["assetIndex"]["url"])
    selected = {
        key.removeprefix("minecraft/"): value
        for key, value in asset_index["objects"].items()
        if key.startswith("minecraft/textures/block/") and key.endswith(".png")
    }
    if not selected:
        raise SystemExit("No vanilla block textures found in asset index")
    print(f"Downloading {len(selected)} vanilla block textures for {VERSION}")
    images = {}
    with concurrent.futures.ThreadPoolExecutor(max_workers=12) as pool:
        for name, image in pool.map(download_texture, selected.items()):
            images[name] = image
    names = sorted(images)
    rows = (len(names) + COLS - 1) // COLS
    atlas = Image.new("RGBA", (COLS * TILE, rows * TILE), (0, 0, 0, 0))
    mapping = {"version": VERSION, "tileSize": TILE, "columns": COLS, "rows": rows, "textures": {}}
    for i, name in enumerate(names):
        x, y = (i % COLS) * TILE, (i // COLS) * TILE
        image = images[name]
        if image.size != (TILE, TILE):
            image.thumbnail((TILE, TILE), Image.Resampling.NEAREST)
            tile = Image.new("RGBA", (TILE, TILE), (0, 0, 0, 0))
            tile.alpha_composite(image, ((TILE-image.width)//2, (TILE-image.height)//2))
            image = tile
        atlas.alpha_composite(image, (x, y))
        mapping["textures"][name.removesuffix(".png")] = {
            "u": x / atlas.width, "v": y / atlas.height,
            "width": TILE / atlas.width, "height": TILE / atlas.height
        }
    atlas.save(ATLAS, optimize=True)
    INDEX.write_text(json.dumps(mapping, separators=(",", ":")), encoding="utf-8")
    print(f"Created {ATLAS} ({atlas.width}x{atlas.height}) and {INDEX}")

if __name__ == "__main__":
    main()
