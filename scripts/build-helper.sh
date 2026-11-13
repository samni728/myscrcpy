#!/bin/zsh
# Regenerate the Android SurfaceControl helper dex jar (optional).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SDK="$HOME/Library/Android/sdk"
D8_BIN="$SDK/build-tools/35.0.0/d8"
test -x "$D8_BIN" || { echo "Cannot find Android SDK d8 at $D8_BIN"; exit 2; }
mkdir -p "$ROOT/Build/android-helper/classes" "$ROOT/Resources"
javac --release 8 -d "$ROOT/Build/android-helper/classes" "$ROOT/android-helper/src/com/samni/miscrcpy/ScreenPower.java"
"$D8_BIN" --min-api 26 --output "$ROOT/Resources/miscrcpy-screenpower.jar" "$ROOT/Build/android-helper/classes/com/samni/miscrcpy/ScreenPower.class"
echo "Android helper created: $ROOT/Resources/miscrcpy-screenpower.jar"
