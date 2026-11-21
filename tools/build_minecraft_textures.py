#!/usr/bin/env python3
"""Extract original-resolution vanilla Minecraft Java 1.21.4 block textures.

Do not resize textures: several vanilla textures are animated or use dimensions
other than 16x16. The renderer consumes the original PNGs and this manifest.
"""
import json
import urllib.request
import zipfile
from io import BytesIO
from pathlib import Path
from PIL import Image

VERSION = "1.21.4"
ROOT = Path("assets/minecraft")
TEXTURE_ROOT = ROOT / "textures" / "block"
MANIFEST = ROOT / "block_textures.json"


def fetch_json(url):
    request = urllib.request.Request(
        url, headers={"User-Agent": "MASTERME4A-asset-builder/2.0"}
    )
    with urllib.request.urlopen(request, timeout=60) as response:
        return json.load(response)


def main():
    TEXTURE_ROOT.mkdir(parents=True, exist_ok=True)
    manifest = fetch_json(
        "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
    )
    version = next(
        (item for item in manifest["versions"] if item["id"] == VERSION), None
    )
    if version is None:
        raise SystemExit("Minecraft version not found: " + VERSION)

    metadata = fetch_json(version["url"])
    client_url = metadata["downloads"]["client"]["url"]
    request = urllib.request.Request(
        client_url, headers={"User-Agent": "MASTERME4A-asset-builder/2.0"}
    )
    with urllib.request.urlopen(request, timeout=180) as response:
        jar_bytes = response.read()

    entries = {}
    with zipfile.ZipFile(BytesIO(jar_bytes)) as jar:
        paths = sorted(
            name for name in jar.namelist()
            if name.startswith("assets/minecraft/textures/block/")
            and name.lower().endswith(".png")
        )
        if not paths:
            raise SystemExit(
                "No vanilla block textures found in official Minecraft client jar"
            )

        for archive_path in paths:
            relative = archive_path.removeprefix(
                "assets/minecraft/textures/block/"
            )
            output_path = TEXTURE_ROOT / relative
            output_path.parent.mkdir(parents=True, exist_ok=True)
            raw = jar.read(archive_path)
            output_path.write_bytes(raw)
            with Image.open(BytesIO(raw)) as image:
                entries[relative.removesuffix(".png")] = {
                    "path": "textures/block/" + relative,
                    "width": image.width,
                    "height": image.height,
                    "animated": image.height > image.width and image.height % image.width == 0,
                }

    payload = {
        "minecraftVersion": VERSION,
        "format": "original-png",
        "textureCount": len(entries),
        "textures": entries,
    }
    MANIFEST.write_text(
        json.dumps(payload, ensure_ascii=False, separators=(",", ":")),
        encoding="utf-8",
    )
    print(
        f"Extracted {len(entries)} original-resolution vanilla block textures "
        f"to {TEXTURE_ROOT}"
    )


if __name__ == "__main__":
    main()
