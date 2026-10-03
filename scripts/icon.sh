#!/bin/bash
# Resources/Awai.icon（Icon Composer で編集）から Assets.car と Awai.icns を作る（Xcode が必要）
# 生成物はコミットしておき、Xcode のない環境でも bundle.sh がそのまま使えるようにする
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
xcrun actool Resources/Awai.icon --compile "$tmp" --app-icon Awai \
    --platform macosx --minimum-deployment-target 15.0 \
    --output-partial-info-plist "$tmp/partial.plist" > /dev/null
cp "$tmp/Assets.car" "$tmp/Awai.icns" Resources/
