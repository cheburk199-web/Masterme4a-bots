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


def install_faithful_textures():
    """Overlay the official Faithful 32x pack for Minecraft 1.21.4."""
    from urllib.parse import quote
    game_versions = quote(json.dumps([VERSION]), safe="")
    versions = fetch_json(
        "https://api.modrinth.com/v2/project/faithful-32x/version"
        f"?game_versions={game_versions}"
    )
    candidates = [item for item in versions if VERSION in item.get("game_versions", []) and item.get("files")]
    if not candidates:
        raise SystemExit("No Faithful 32x release found for Minecraft " + VERSION)
    release = max(candidates, key=lambda item: item.get("date_published", ""))
    file_info = next((item for item in release["files"] if item.get("primary")), release["files"][0])
    archive_bytes = fetch_bytes(file_info["url"])
    expected = (file_info.get("hashes") or {}).get("sha512")
    if expected:
        import hashlib
        if hashlib.sha512(archive_bytes).hexdigest().lower() != expected.lower():
            raise SystemExit("Faithful 32x download SHA-512 verification failed")
    copied = 0
    with zipfile.ZipFile(BytesIO(archive_bytes)) as pack:
        prefix = "assets/minecraft/textures/block/"
        for info in pack.infolist():
            name = info.filename
            if info.is_dir() or not name.startswith(prefix) or not name.lower().endswith(".png"):
                continue
            relative = name[len(prefix):]
            if not relative or ".." in Path(relative).parts:
                continue
            target = TEXTURE_ROOT / relative
            target.parent.mkdir(parents=True, exist_ok=True)
            raw = pack.read(info)
            with Image.open(BytesIO(raw)) as image:
                image.verify()
            target.write_bytes(raw)
            copied += 1
    if copied < 100:
        raise SystemExit(f"Faithful 32x archive looked incomplete ({copied} block textures)")
    manifest = {
        "name": "Faithful 32x",
        "version": release.get("version_number"),
        "file": file_info.get("filename"),
        "source": "https://modrinth.com/resourcepack/faithful-32x",
        "release": "https://modrinth.com/resourcepack/faithful-32x/version/" + release.get("id", ""),
        "license": "Faithful License",
        "texturesOverlaid": copied,
    }
    (ROOT / "faithful_pack.json").write_text(json.dumps(manifest, separators=(",", ":")), encoding="utf-8")
    return manifest


def resolve_model_texture(model_name, visited=None):
    """Resolve a block model's representative face texture, following parents."""
    visited = set() if visited is None else visited
    model_name = model_name.removeprefix("minecraft:").removeprefix("block/")
    if model_name in visited:
        return None
    visited.add(model_name)
    path = MODELS_ROOT / (model_name + ".json")
    if not path.exists():
        return None
    model = json.loads(path.read_text(encoding="utf-8"))
    textures = model.get("textures", {})
    # Prefer the visually representative full-block face.
    for key in ("all", "side", "top", "end", "front", "particle"):
        value = textures.get(key)
        if isinstance(value, str):
            if value.startswith("#"):
                resolved = textures.get(value[1:])
                if isinstance(resolved, str) and not resolved.startswith("#"):
                    return resolved.removeprefix("minecraft:")
            else:
                return value.removeprefix("minecraft:")
    for value in textures.values():
        if isinstance(value, str) and not value.startswith("#"):
            return value.removeprefix("minecraft:")
    parent = model.get("parent")
    if isinstance(parent, str):
        return resolve_model_texture(parent, visited)
    return None



def resolve_model_face_textures(model_name, visited=None):
    """Resolve per-face PNGs, including inherited parent model textures."""
    visited = set() if visited is None else visited
    model_name = model_name.removeprefix("minecraft:").removeprefix("block/")
    if model_name in visited:
        return {}
    visited.add(model_name)
    path = MODELS_ROOT / (model_name + ".json")
    if not path.exists():
        return {}
    model = json.loads(path.read_text(encoding="utf-8"))
    textures = model.get("textures", {})
    result = {}
    for element in model.get("elements", []):
        for face, spec in element.get("faces", {}).items():
            value = spec.get("texture")
            if not isinstance(value, str):
                continue
            seen = set()
            while value.startswith("#") and value[1:] not in seen:
                key = value[1:]
                seen.add(key)
                value = textures.get(key, "")
            if isinstance(value, str) and value:
                value = value.removeprefix("minecraft:").removeprefix("block/")
                result[face] = value
    parent = model.get("parent")
    if isinstance(parent, str):
        inherited = resolve_model_face_textures(parent, visited)
        inherited.update(result)
        result = inherited
    if not result:
        # Cube-all and similar parents store their texture on the parent itself.
        for key in ("all", "side", "top", "end", "particle"):
            value = textures.get(key)
            if isinstance(value, str):
                while value.startswith("#"):
                    value = textures.get(value[1:], "")
                if value and not value.startswith("#"):
                    value = value.removeprefix("minecraft:").removeprefix("block/")
                    result = {face: value for face in ("up", "down", "north", "south", "east", "west")}
                    break
    return result

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

    faithful_pack = install_faithful_textures()
    # Refresh dimensions after overlay so the manifest describes Faithful PNGs.
    texture_manifest = {}
    for path in sorted(TEXTURE_ROOT.rglob("*.png")):
        relative = path.relative_to(TEXTURE_ROOT).as_posix()
        with Image.open(path) as image:
            texture_manifest[relative.removesuffix(".png")] = {
                "path": "textures/block/" + relative,
                "width": image.width,
                "height": image.height,
                "animated": image.height > image.width and image.height % image.width == 0,
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

    # Resolve textures once per block, not once per state ID. Some blocks
    # have hundreds of states; repeatedly parsing the same model JSON caused
    # the Actions texture step to take many minutes.
    state_texture_lookup = {}
    state_face_texture_lookup = {}
    for block_name, block_info in block_ranges.items():
        first = int(block_info["minStateId"])
        last = int(block_info["maxStateId"])
        candidates = block_info.get("models", [])
        texture_path = None
        for model_name in candidates:
            texture_name = resolve_model_texture(model_name)
            if texture_name:
                texture_name = texture_name.removeprefix("block/")
                if (TEXTURE_ROOT / (texture_name + ".png")).exists():
                    texture_path = "textures/block/" + texture_name + ".png"
                    break
        usable = {}
        for model_name in candidates:
            faces = resolve_model_face_textures(model_name)
            usable = {
                face: "textures/block/" + name + ".png"
                for face, name in faces.items()
                if (TEXTURE_ROOT / (name + ".png")).exists()
            }
            if usable:
                break
        for state_id in range(first, last + 1):
            key = str(state_id)
            if texture_path:
                state_texture_lookup[key] = texture_path
            if usable:
                state_face_texture_lookup[key] = usable

    if len(state_texture_lookup) < 500:
        raise SystemExit(
            "State-to-texture lookup looks incomplete; refusing to publish "
            f"({len(state_texture_lookup)} mapped states)"
        )
    (ROOT / "state_face_texture_lookup.json").write_text(
        json.dumps({
            "minecraftVersion": VERSION,
            "source": "Minecraft 1.21.4 block models per-face textures",
            "states": state_face_texture_lookup,
        }, separators=(",", ":")),
        encoding="utf-8",
    )
    (ROOT / "state_texture_lookup.json").write_text(
        json.dumps({
            "minecraftVersion": VERSION,
            "source": "Minecraft 1.21.4 blockstates and block models",
            "states": state_texture_lookup,
        }, separators=(",", ":")),
        encoding="utf-8",
    )

    if len(state_lookup) < 1000:
        raise SystemExit(
            "Block-state registry looks incomplete; refusing to publish broken lookup "
            f"({len(state_lookup)} states)"
        )

    (ROOT / "block_textures.json").write_text(
        json.dumps({
            "minecraftVersion": VERSION,
            "format": "faithful-32x-overlay",
            "resourcePack": faithful_pack,
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
