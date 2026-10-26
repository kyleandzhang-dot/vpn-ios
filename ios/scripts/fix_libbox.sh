#!/bin/bash
set -Eeuo pipefail

trap 'echo "❌ 脚本在第 $LINENO 行失败 (exit $?)" >&2' ERR

# 读取二进制的真实 minos，结果只输出到 stdout，调试信息走 stderr。
# 支持 fat 文件、dylib，以及静态库 (ar archive)。
# 静态库：解开后读每个 .o 的 minos，取最大值（Info.plist 必须 >= 二进制要求）。
get_minos() {
  local BIN="$1" WORK THIN INFO VALUES MINOS=""
  WORK=$(mktemp -d)
  THIN="$WORK/thin"

  INFO=$(lipo -info "$BIN" 2>&1 || true)
  if [[ "$INFO" == *"fat file"* ]]; then
    lipo "$BIN" -thin arm64 -output "$THIN"
  else
    cp "$BIN" "$THIN"
  fi

  if [[ "$(file "$THIN")" == *"ar archive"* ]]; then
    echo "检测到静态库 (ar archive)，解包读取各 .o 的 minos" >&2
    mkdir "$WORK/obj"
    ( cd "$WORK/obj" && ar -x "$THIN" )
    echo "解出 $(find "$WORK/obj" -type f | wc -l | tr -d ' ') 个成员" >&2
    VALUES=$(find "$WORK/obj" -type f | while read -r O; do
      xcrun vtool -show-build "$O" 2>/dev/null | awk '
        /^ *minos /  {print $2; exit}
        /LC_VERSION_MIN_IPHONEOS/ {f=1}
        f && /^ *version / {print $2; exit}' || true
    done)
  else
    VALUES=$(xcrun vtool -show-build "$THIN" 2>&1 | awk '
      /^ *minos /  {print $2; exit}
      /LC_VERSION_MIN_IPHONEOS/ {f=1}
      f && /^ *version / {print $2; exit}' || true)
  fi

  VALUES=$(printf '%s\n' "$VALUES" | sed '/^$/d')
  if [ -n "$VALUES" ]; then
    echo "各 minos 取值统计:" >&2
    printf '%s\n' "$VALUES" | sort -V | uniq -c >&2
    MINOS=$(printf '%s\n' "$VALUES" | sort -V | tail -n 1)
  fi

  rm -rf "$WORK"
  printf '%s' "$MINOS"
}

fix_fw() {
  local FW="$1"
  echo "== 处理: $FW =="

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
    # iOS 不允许 framework 带 Resources/Versions 子目录
    rm -rf "$FW/Resources" "$FW/Versions" "$FW/Current"
  fi

  if [ ! -f "$FW/Libbox" ]; then
    echo "❌ 缺少二进制: $FW/Libbox"
    ls -la "$FW"
    exit 1
  fi

  echo "文件类型: $(file "$FW/Libbox" | head -n 1)"

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

# 模式 1: 只打印某个二进制的 minos（给 ipa 校验用）
if [ "${1:-}" = "--minos" ]; then
  get_minos "$2"
  echo
  exit 0
fi

# 模式 2: 修复目录下所有 Libbox.framework（跳过 simulator）
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
  if [ "${ALLOW_EMPTY:-0}" = "1" ]; then
    echo "没找到 Libbox.framework，跳过 (ALLOW_EMPTY=1)"
    exit 0
  fi
  echo "❌ 没找到任何 Libbox.framework（已排除 simulator）"
  exit 1
fi
echo "完成，共处理 $COUNT 个 framework"