#!/bin/bash
# リリースビルドして build/Awai.app を作る（Xcode 不要）
set -euo pipefail
cd "$(dirname "$0")/.."

swift build -c release
bin_dir=$(swift build -c release --show-bin-path)

app=build/Awai.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin_dir/Awai" "$app/Contents/MacOS/Awai"
cp Resources/Info.plist "$app/Contents/Info.plist"
# アイコン（macOS 26 以降は Assets.car、それより前は Awai.icns を使う）
cp Resources/Assets.car Resources/Awai.icns "$app/Contents/Resources/"

# Apple Silicon では最低限アドホック署名が必要
codesign --force --sign - "$app"
echo "$app"
