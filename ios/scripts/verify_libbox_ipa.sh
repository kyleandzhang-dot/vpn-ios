#!/bin/bash
set -Eeuo pipefail

IPA_PATH="${1:-Runner.ipa}"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FIX_SCRIPT="$SCRIPT_DIR/fix_libbox.sh"

if [ ! -f "$IPA_PATH" ]; then
  echo "❌ 找不到 IPA: $IPA_PATH" >&2
  exit 1
fi
if [ ! -f "$FIX_SCRIPT" ]; then
  echo "❌ 找不到共享修复脚本: $FIX_SCRIPT" >&2
  exit 1
fi

TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT
unzip -q "$IPA_PATH" -d "$TMP_DIR"

FOUND=0
while IFS= read -r -d '' FW; do
  FOUND=1
  echo "== 检查: $FW =="

  if [ ! -f "$FW/Info.plist" ]; then
    echo "❌ 缺少 Info.plist: $FW" >&2
    exit 1
  fi
  if [ ! -f "$FW/Libbox" ]; then
    echo "❌ 缺少二进制: $FW/Libbox" >&2
    exit 1
  fi

  if ! PLIST_MIN=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$FW/Info.plist" 2>&1); then
    echo "❌ 无法读取 MinimumOSVersion: $FW/Info.plist" >&2
    echo "$PLIST_MIN" >&2
    exit 1
  fi
  if ! BIN_MIN=$(bash "$FIX_SCRIPT" --minos "$FW/Libbox" 2>/dev/null); then
    echo "❌ 无法读取 Libbox 二进制最低系统版本: $FW/Libbox" >&2
    exit 1
  fi

  echo "plist=$PLIST_MIN binary=$BIN_MIN"
  if [ -z "$BIN_MIN" ]; then
    echo "❌ 读不到二进制 minos: $FW/Libbox" >&2
    exit 1
  fi
  if [ "$PLIST_MIN" != "$BIN_MIN" ]; then
    echo "❌ MinimumOSVersion 与二进制不一致: $FW" >&2
    exit 1
  fi
 done < <(find "$TMP_DIR/Payload" -type d -name 'Libbox.framework' -print0)

if [ "$FOUND" -eq 0 ]; then
  echo "❌ IPA 里没有 Libbox.framework" >&2
  exit 1
fi

echo "✅ 所有 Libbox.framework 的 MinimumOSVersion 均与二进制一致"
