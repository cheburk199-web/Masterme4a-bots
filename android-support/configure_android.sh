#!/usr/bin/env bash
set -euo pipefail

python3 <<'PY_ANDROID'
from pathlib import Path
import re

app = Path("android/app/build.gradle.kts")
if not app.exists():
    app = Path("android/app/build.gradle")
if not app.exists():
    raise SystemExit("Android app Gradle file not found")

root = Path("android/build.gradle.kts")
if not root.exists():
    root = Path("android/build.gradle")
if not root.exists():
    raise SystemExit("Android root Gradle file not found")

repo = "https://jitpack.io"
root_text = root.read_text()
if repo not in root_text:
    if root.name.endswith(".kts"):
        repo_line = '        maven("https://jitpack.io")'
        fallback = '\nallprojects {\n    repositories {\n        maven("https://jitpack.io")\n    }\n}\n'
    else:
        repo_line = "        maven { url 'https://jitpack.io' }"
        fallback = "\nallprojects {\n    repositories {\n        maven { url 'https://jitpack.io' }\n    }\n}\n"
    pattern = r"(allprojects\s*\{\s*repositories\s*\{)"
    root_text, count = re.subn(pattern, lambda match: match.group(1) + "\n" + repo_line, root_text, count=1)
    if count == 0:
        root_text += fallback
    root.write_text(root_text)


settings = Path("android/settings.gradle.kts")
if settings.exists():
    settings_text = settings.read_text()
    open_collab = 'maven("https://repo.opencollab.dev/main/") { name = "opencollab" }'
    if open_collab not in settings_text:
        pattern = r"(dependencyResolutionManagement\\s*\\{\\s*repositories\\s*\\{)"
        settings_text, count = re.subn(pattern, lambda match: match.group(1) + "\\n        " + open_collab, settings_text, count=1)
        if count == 0:
            settings_text += "\\ndependencyResolutionManagement {\\n    repositories {\\n        " + open_collab + "\\n    }\\n}\\n"
        settings.write_text(settings_text)

app_text = app.read_text()
dependency = "org.geysermc.mcprotocollib:protocol:1.21.4-1"
if dependency not in app_text:
    if app.name.endswith(".kts"):
        app_text += '\ndependencies {\n    implementation("com.github.GeyserMC:MCProtocolLib:1.21.4-1")\n}\n'
    else:
        app_text += "\ndependencies {\n    implementation 'com.github.GeyserMC:MCProtocolLib:1.21.4-1'\n}\n"
    app.write_text(app_text)

manifest = Path("android/app/src/main/AndroidManifest.xml")
manifest_text = manifest.read_text()
permission = '    <uses-permission android:name="android.permission.INTERNET" />'
if "android.permission.INTERNET" not in manifest_text:
    manifest_text = re.sub(r"(<manifest\b[^>]*>)", r"\1\n" + permission, manifest_text, count=1)
    manifest.write_text(manifest_text)

if dependency not in app.read_text():
    raise SystemExit("MCProtocolLib dependency was not added")
if repo not in root.read_text():
    raise SystemExit("JitPack repository was not added")

print("Gradle dependency:")
for line in app.read_text().splitlines():
    if "com.github.GeyserMC:MCProtocolLib" in line:
        print(line)
print("Maven repository:")
print("OpenCollab repository configured in settings.gradle.kts:", Path("android/settings.gradle.kts").exists() and "repo.opencollab.dev/main" in Path("android/settings.gradle.kts").read_text())
for line in root.read_text().splitlines():
    if "jitpack.io" in line:
        print(line)
PY_ANDROID

mkdir -p android/app/src/main/java/com/example/masterme4a_bot_control
cp android-support/MainActivity.java android/app/src/main/java/com/example/masterme4a_bot_control/MainActivity.java
rm -f android/app/src/main/kotlin/com/example/masterme4a_bot_control/MainActivity.kt

echo "Configured MCProtocolLib 1.21.4-1 and native bot bridge."
