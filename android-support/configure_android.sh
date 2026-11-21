#!/usr/bin/env bash
set -euo pipefail

APP_GRADLE=""
if [[ -f android/app/build.gradle.kts ]]; then
  APP_GRADLE="android/app/build.gradle.kts"
elif [[ -f android/app/build.gradle ]]; then
  APP_GRADLE="android/app/build.gradle"
else
  echo "Android app Gradle file not found" >&2
  exit 1
fi

SETTINGS=""
if [[ -f android/settings.gradle.kts ]]; then
  SETTINGS="android/settings.gradle.kts"
elif [[ -f android/settings.gradle ]]; then
  SETTINGS="android/settings.gradle"
else
  echo "Android settings Gradle file not found" >&2
  exit 1
fi

if ! grep -q "repo.opencollab.dev/main" "$SETTINGS"; then
  if [[ "$SETTINGS" == *.kts ]]; then
    sed -i '/mavenCentral()/a\        maven("https://repo.opencollab.dev/main/")' "$SETTINGS"
  else
    sed -i "/mavenCentral()/a\\        maven { url 'https://repo.opencollab.dev/main/' }" "$SETTINGS"
  fi
fi

if ! grep -q "org.geysermc.mcprotocollib:protocol" "$APP_GRADLE"; then
  if grep -q '^[[:space:]]*dependencies[[:space:]]*{' "$APP_GRADLE"; then
    if [[ "$APP_GRADLE" == *.kts ]]; then
      sed -i '/^[[:space:]]*dependencies[[:space:]]*{/a\    implementation("org.geysermc.mcprotocollib:protocol:1.21.4-1")' "$APP_GRADLE"
    else
      sed -i "/^[[:space:]]*dependencies[[:space:]]*{/a\\    implementation 'org.geysermc.mcprotocollib:protocol:1.21.4-1'" "$APP_GRADLE"
    fi
  elif [[ "$APP_GRADLE" == *.kts ]]; then
    cat >> "$APP_GRADLE" <<'GRADLE_DEPENDENCY'

dependencies {
    implementation("org.geysermc.mcprotocollib:protocol:1.21.4-1")
}
GRADLE_DEPENDENCY
  else
    cat >> "$APP_GRADLE" <<'GRADLE_DEPENDENCY'

dependencies {
    implementation 'org.geysermc.mcprotocollib:protocol:1.21.4-1'
}
GRADLE_DEPENDENCY
  fi
fi

mkdir -p android/app/src/main/java/com/example/masterme4a_bot_control
cp android-support/MainActivity.java android/app/src/main/java/com/example/masterme4a_bot_control/MainActivity.java
rm -f android/app/src/main/kotlin/com/example/masterme4a_bot_control/MainActivity.kt

MANIFEST="android/app/src/main/AndroidManifest.xml"
if ! grep -q 'android.permission.INTERNET' "$MANIFEST"; then
  sed -i '/<manifest[^>]*>/a\    <uses-permission android:name="android.permission.INTERNET" />' "$MANIFEST"
fi

echo "Configured MCProtocolLib 1.21.4-1 and native bot bridge."
