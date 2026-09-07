#!/bin/bash
# QuotaBar 一键安装：在本机构建并安装到 /Applications。
# 本地构建的产物没有 quarantine 标记，不触发 Gatekeeper 拦截。
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="QuotaBar"
APP="build/${APP_NAME}.app"
BIN="${APP}/Contents/MacOS/${APP_NAME}"

fail() { echo "✗ $1" >&2; exit 1; }

echo "▸ 检查构建环境"
[ "$(uname -m)" = "arm64" ] || fail "本应用仅支持 Apple Silicon（当前 $(uname -m)）。"
MACOS_MAJOR="$(sw_vers -productVersion | cut -d. -f1)"
[ "$MACOS_MAJOR" -ge 13 ] || fail "需要 macOS 13 或更高版本（当前 $(sw_vers -productVersion)）。"
xcode-select -p >/dev/null 2>&1 || fail "未找到 Xcode 命令行工具。请先运行：xcode-select --install"
command -v swift >/dev/null 2>&1 || fail "未找到 swift。请先运行：xcode-select --install"
echo "  macOS $(sw_vers -productVersion) / $(uname -m)"

# 签名后必须实测能否执行。签名无效的二进制在 exec 时被 AMFI 以 SIGKILL(137) 杀掉，
# 随后由 syspolicyd 当作恶意软件移入废纸篓——钥匙串里存在重复或不可用的开发者证书时会这样。
# 被拦截后该路径会被短暂封锁，所以 137 要隔几秒复检一次才能定性。
runs_ok() {
  local code
  for _ in 1 2 3; do
    # 签名被拒后系统会把 app 移进废纸篓，此时文件已不在原处，直接判定失败。
    [ -x "$BIN" ] || return 1
    # 交给子 shell 执行，signal 被杀时的 "Killed: 9" 提示随之丢弃，只取退出码。
    set +e; bash -c '"$0" --once >/dev/null 2>&1' "$BIN" 2>/dev/null; code=$?; set -e
    [ "$code" -ne 137 ] && return 0
    sleep 5
  done
  return 1
}

try_sign() {
  make bundle ${1:+SIGN_ID="$1"} >/dev/null 2>&1 || return 1
  runs_ok
}

echo "▸ 构建并签名"
if try_sign ""; then
  echo "  使用钥匙串中的开发者证书签名"
elif try_sign "-"; then
  echo "  开发者证书签出的签名无法执行，已改用 ad-hoc 签名"
  echo "  （ad-hoc 签名下，每次重新构建后钥匙串授权需重新点一次「始终允许」）"
else
  fail "构建或签名失败：签出的二进制无法执行。"
fi

echo "▸ 安装到 /Applications"
pkill -x "$APP_NAME" 2>/dev/null || true
rm -rf "/Applications/${APP_NAME}.app"
cp -R "$APP" /Applications/

echo
echo "✓ 已安装：/Applications/${APP_NAME}.app"
echo
echo "  启动：open -a ${APP_NAME}"
echo "  首次启动会请求读取钥匙串中的 Claude Code 凭据，请选择「始终允许」。"
echo "  需要先在本机登录过 Claude Code（claude）与 Codex（codex）。"
