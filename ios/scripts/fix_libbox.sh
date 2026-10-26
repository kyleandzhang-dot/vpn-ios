#!/bin/bash
set -Eeuo pipefail

# 任何命令失败都打印行号，避免静默退出
trap 'echo "❌ 脚本在第 $LINENO 行失败 (exit $?)" >&2' ERR

get_minos() {
  local out
  if ! out=$(xcrun vtool -show-build "$1" 2>&1); then
    echo "❌ vtool 执行失败: $1" >&2
    echo "$out" >&2
    return 0
  fi
  echo "--- vtool 输出 ($1) ---" >&2
  echo "$out" >&2
  # 兼容 LC_BUILD_VERSION (minos) 和旧式 LC_VERSION_MIN_IPHONEOS (version)
  awk '
    /^ *minos /  {print $2; exit}
    /LC_VERSION_MIN_IPHONEOS/ {f=1}
    f && /^ *version / {print $2; exit}' <<< "$out"
}

fix_fw() {
  local FW="$1"
  echo "== 处理: $FW =="
  ls -la "$FW"

  # 展平 Versions 结构
  if [ -d "$FW/Versions" ]; then
    echo "检测到 Versions 结构，展平中"
    local TMP REAL
    TMP=$(mktemp -d)
    REAL="$FW/Versions/Current"
    if [ ! -d "$REAL" ]; then
      REAL="$FW/Versions/A"
    fi
    cp -R -L "$REAL/"* "$TMP/"
    rm -rf "$FW/"*
    cp -R "$TMP/"* "$FW/"
    rm -rf "$TMP"
  fi

  if [ ! -f "$FW/Libbox" ]; then
    echo "❌ 缺少二进制: $FW/Libbox"
    ls -la "$FW"
    exit 1
  fi

  echo "文件类型: $(file "$FW/Libbox")"

  local MINOS
  MINOS=$(get_minos "$FW/Libbox")
  if [ -z "$MINOS" ]; then
    echo "❌ 读不到 minos: $FW"
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
  echo "== 扫描: $ROOT =="
  while read -r FW; do
    [ -n "$FW" ] || continue
    fix_fw "$FW"
    COUNT=$((COUNT+1))
  done < <(find "$ROOT" -name "Libbox*.framework" -not -path "*simulator*" 2>/dev/null)
done

if [ "$COUNT" -eq 0 ]; then
  echo "❌ 没找到任何 Libbox.framework（已排除 simulator）"
  exit 1
fi
echo "完成，共处理 $COUNT 个 framework"