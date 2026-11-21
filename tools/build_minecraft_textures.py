#!/usr/bin/env python3
"""Build vanilla Minecraft 1.21.4 textures + block-state/model lookup assets."""
import json
import urllib.request
import zipfile
from io import BytesIO
from pathlib import Path
from PIL import Image

VERSION = "1.21.4"
ROOT = Path("assets/minecraft")
TEXTURE_ROOT = ROOT / "textures" / "block"
BLOCKSTATES_ROOT = ROOT / "blockstates"
MODELS_ROOT = ROOT / "models" / "block"


def fetch_bytes(url, timeout=180):
    request = urllib.request.Request(
        url, headers={"User-Agent": "MASTERME4A-vanilla-assets/3.0"}
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        return response.read()


def fetch_json(url):
    return json.loads(fetch_bytes(url, timeout=60))


def write_jar_entry(jar, archive_path, output_root, prefix):
    relative = archive_path[len(prefix):]
    target = output_root / relative
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_bytes(jar.read(archive_path))
    return relative


def model_references(blockstate):
    found = set()

    def visit(value):
        if isinstance(value, dict):
            model = value.get("model")
            if isinstance(model, str):
                found.add(model.removeprefix("minecraft:"))
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)

    visit(blockstate.get("variants", {}))
    visit(blockstate.get("multipart", []))
    return sorted(found)


def main():
    for folder in (TEXTURE_ROOT, BLOCKSTATES_ROOT, MODELS_ROOT):
        folder.mkdir(parents=True, exist_ok=True)

    version_manifest = fetch_json(
        "https://piston-meta.mojang.com/mc/game/version_manifest_v2.json"
    )
    version = next(
        (item for item in version_manifest["versions"] if item["id"] == VERSION),
        None,
    )
    if version is None:
        raise SystemExit("Minecraft version not found: " + VERSION)

    metadata = fetch_json(version["url"])
    jar_data = fetch_bytes(metadata["downloads"]["client"]["url"])
    with zipfile.ZipFile(BytesIO(jar_data)) as jar:
        names = jar.namelist()
        texture_paths = sorted(
            name for name in names
            if name.startswith("assets/minecraft/textures/block/")
            and name.lower().endswith(".png")
        )
        blockstate_paths = sorted(
            name for name in names
            if name.startswith("assets/minecraft/blockstates/")
            and name.endswith(".json")
        )
        model_paths = sorted(
            name for name in names
            if name.startswith("assets/minecraft/models/block/")
            and name.endswith(".json")
        )
        if not texture_paths or not blockstate_paths or not model_paths:
            raise SystemExit(
                "Official client jar is missing textures, blockstates, or block models"
            )

        texture_manifest = {}
        for archive_path in texture_paths:
            relative = write_jar_entry(
                jar, archive_path, TEXTURE_ROOT,
                "assets/minecraft/textures/block/",
            )
            raw = jar.read(archive_path)
            with Image.open(BytesIO(raw)) as image:
                texture_manifest[relative.removesuffix(".png")] = {
                    "path": "textures/block/" + relative,
                    "width": image.width,
                    "height": image.height,
                    "animated": image.height > image.width and image.height % image.width == 0,
                }

        blockstate_manifest = {}
        for archive_path in blockstate_paths:
            relative = write_jar_entry(
                jar, archive_path, BLOCKSTATES_ROOT,
                "assets/minecraft/blockstates/",
            )
            block_name = relative.removesuffix(".json")
            try:
                parsed = json.loads(jar.read(archive_path))
            except Exception as exc:
                raise SystemExit(f"Invalid blockstate JSON {relative}: {exc}")
            blockstate_manifest[block_name] = {
                "path": "blockstates/" + relative,
                "models": model_references(parsed),
                "hasMultipart": bool(parsed.get("multipart")),
            }

        model_manifest = {}
        for archive_path in model_paths:
            relative = write_jar_entry(
                jar, archive_path, MODELS_ROOT,
                "assets/minecraft/models/block/",
            )
            parsed = json.loads(jar.read(archive_path))
            model_manifest[relative.removesuffix(".json")] = {
                "path": "models/block/" + relative,
                "parent": parsed.get("parent"),
                "textures": parsed.get("textures", {}),
                "elements": len(parsed.get("elements", [])),
            }

    # Prismarine's Java data supplies the same global block-state ID ranges
    # used by the 1.21.4 protocol palette decoded by MCProtocolLib.
    blocks = fetch_json(
        "https://raw.githubusercontent.com/PrismarineJS/minecraft-data/master/data/pc/1.21.4/blocks.json"
    )
    state_lookup = {}
    block_ranges = {}
    for block in blocks:
        first = block.get("minStateId")
        last = block.get("maxStateId")
        if first is None or last is None:
            continue
        name = block["name"]
        block_ranges[name] = {
            "minStateId": first,
            "maxStateId": last,
            "defaultState": block.get("defaultState"),
            "blockstate": blockstate_manifest.get(name, {}).get("path"),
            "models": blockstate_manifest.get(name, {}).get("models", []),
        }
        for state_id in range(int(first), int(last) + 1):
            state_lookup[str(state_id)] = name

    if len(state_lookup) < 1000:
        raise SystemExit(
            "Block-state registry looks incomplete; refusing to publish broken lookup "
            f"({len(state_lookup)} states)"
        )

    (ROOT / "block_textures.json").write_text(
        json.dumps({
            "minecraftVersion": VERSION,
            "format": "original-png",
            "textureCount": len(texture_manifest),
            "textures": texture_manifest,
        }, separators=(",", ":")),
        encoding="utf-8",
    )
    (ROOT / "block_state_registry.json").write_text(
        json.dumps({
            "minecraftVersion": VERSION,
            "source": "PrismarineJS/minecraft-data pc/1.21.4 blocks.json",
            "stateCount": len(state_lookup),
            "states": state_lookup,
            "blocks": block_ranges,
        }, separators=(",", ":")),
        encoding="utf-8",
    )
    (ROOT / "block_model_manifest.json").write_text(
        json.dumps({
            "minecraftVersion": VERSION,
            "blockstateCount": len(blockstate_manifest),
            "modelCount": len(model_manifest),
            "blockstates": blockstate_manifest,
            "models": model_manifest,
        }, separators=(",", ":")),
        encoding="utf-8",
    )
    print(
        "Built vanilla asset lookup: "
        f"{len(texture_manifest)} textures, {len(blockstate_manifest)} blockstates, "
        f"{len(model_manifest)} block models, {len(state_lookup)} block-state IDs"
    )


if __name__ == "__main__":
    main()
