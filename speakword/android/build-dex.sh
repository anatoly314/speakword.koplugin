#!/usr/bin/env bash
#
# Build audio_helper.dex from AudioPlayer.java using the Android SDK.
#
# Adapted from audiobook.koplugin/android/build-dex.sh
#   https://github.com/stradichenko/audiobook.koplugin (AGPL-3.0)
#
# Prerequisites:
#   - ANDROID_HOME or ANDROID_SDK_ROOT pointing at an Android SDK
#     (falls back to the brew-installed android-commandlinetools).
#   - Build tools >= 30.0.0 (sdkmanager "build-tools;34.0.0").
#   - Platform API 21+ (sdkmanager "platforms;android-34").
#   - Java 8+ on PATH.
#
# Usage:
#   ./build-dex.sh
#
# Output:
#   speakword/android/audio_helper.dex
#
set -euo pipefail
cd "$(dirname "$0")"

# Resolve SDK: env var first, then the macOS Homebrew install location.
SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
if [[ -z "$SDK" ]]; then
    if [[ -d "/opt/homebrew/share/android-commandlinetools" ]]; then
        SDK="/opt/homebrew/share/android-commandlinetools"
    elif [[ -d "/usr/local/share/android-commandlinetools" ]]; then
        SDK="/usr/local/share/android-commandlinetools"
    else
        echo "Error: ANDROID_HOME / ANDROID_SDK_ROOT not set and no brew SDK found" >&2
        exit 1
    fi
fi

# Find build-tools (newest available).
BT_DIR=$(ls -d "$SDK/build-tools"/*/ 2>/dev/null | sort -V | tail -1)
if [[ -z "$BT_DIR" ]]; then
    echo "Error: No build-tools found in $SDK/build-tools/" >&2
    exit 1
fi
D8="${BT_DIR%/}/d8"
if [[ ! -x "$D8" ]]; then
    echo "Error: d8 not executable at $D8" >&2
    exit 1
fi

# Find android.jar (newest platform).
PLATFORM=$(ls -d "$SDK/platforms"/android-*/ 2>/dev/null | sort -V | tail -1)
if [[ -z "$PLATFORM" ]]; then
    echo "Error: No platform found in $SDK/platforms/" >&2
    exit 1
fi
ANDROID_JAR="${PLATFORM%/}/android.jar"

echo "SDK:         $SDK"
echo "Build tools: $BT_DIR"
echo "Platform:    $PLATFORM"
echo "d8:          $D8"

# Compile .java -> .class
echo "Compiling AudioPlayer.java..."
mkdir -p build
javac -source 1.8 -target 1.8 \
    -classpath "$ANDROID_JAR" \
    -d build \
    AudioPlayer.java

# Convert .class -> .dex (include any inner/anonymous classes).
# --lib points d8 at android.jar so it can resolve framework types and
# perform interface-default-method desugaring without warnings.
echo "Dexing..."
"$D8" --min-api 21 --lib "$ANDROID_JAR" --output . build/com/speakword/AudioPlayer*.class

# d8 emits classes.dex; rename to our expected filename.
mv classes.dex audio_helper.dex
rm -rf build

echo "Created audio_helper.dex ($(wc -c < audio_helper.dex) bytes)"
