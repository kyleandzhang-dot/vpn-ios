#!/bin/bash
set -euo pipefail

get_minos() {
  # 兼容 LC_BUILD_VERSION (minos) 和旧式 LC_VERSION_MIN_IPHONEOS (version)
  xcrun vtool -show-build "$1" 2>/dev/null | awk '
    /^ *minos /  {print $2; exit}
    /LC_VERSION_MIN_IPHONEOS/ {f=1}
    f && /^ *version / {print $2; exit}'
}

fix_fw() {
  local FW="$1"

  if [ -d "$FW/Versions" ]; then
    local TMP REAL
    TMP=$(mktemp -d)
    REAL="$FW/Versions/Current"
    [ ! -d "$REAL" ] && REAL="$FW/Versions/A"
    cp -R -L "$REAL/"* "$TMP/"
    rm -rf "$FW/"*
    cp -R "$TMP/"* "$FW/"
    rm -rf "$TMP"
  fi

  [ -f "$FW/Libbox" ] || { echo "❌ 缺少二进制: $FW/Libbox"; ls -la "$FW"; exit 1; }

  local MINOS
  MINOS=$(get_minos "$FW/Libbox")
  if [ -z "$MINOS" ]; then
    echo "❌ 读不到 minos: $FW"
    xcrun vtool -show-build "$FW/Libbox" || true
    exit 1
  fi
  echo "✅ Libbox minos=$MINOS ($FW)"

  rm -f "$FW/Info.plist"
  cat > "$FW/Info.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleDevelopmentRegion</key><string>en</string>
  <key>CFBundleExecutable</key><string>Libbox</string>
  <key>CFBundleIdentifier</key><string>Libbox</string>
  <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
  <key>CFBundleName</key><string>Libbox</string>
  <key>CFBundlePackageType</key><string>FMWK</string>
  <key>CFBundleShortVersionString</key><string>1.0</string>
  <key>CFBundleVersion</key><string>1</string>
  <key>MinimumOSVersion</key><string>${MINOS}</string>
</dict>
</plist>
EOF
}

COUNT=0
for ROOT in "$@"; do
  while read -r FW; do
    fix_fw "$FW"
    COUNT=$((COUNT+1))
  done < <(find "$ROOT" -name "Libbox*.framework" -not -path "*simulator*" 2>/dev/null)
done

[ "$COUNT" -gt 0 ] || { echo "❌ 没找到任何 Libbox.framework"; exit 1; }