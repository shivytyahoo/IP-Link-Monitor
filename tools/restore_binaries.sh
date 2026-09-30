#!/bin/bash
# Restores binary files stored as base64 in tools/binaries/.
# Run once after cloning:  bash tools/restore_binaries.sh
set -e
cd "$(dirname "$0")/.."
mkdir -p android/gradle/wrapper
base64 -d tools/binaries/gradle-wrapper.jar.b64 > android/gradle/wrapper/gradle-wrapper.jar
for d in hdpi mdpi xhdpi xxhdpi xxxhdpi; do
  mkdir -p "android/app/src/main/res/mipmap-$d"
  base64 -d "tools/binaries/ic_launcher-$d.png.b64" > "android/app/src/main/res/mipmap-$d/ic_launcher.png"
done
echo "Binaries restored."
