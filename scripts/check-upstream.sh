#!/usr/bin/env bash
# 检查 dsh 上游版本，输出 current / latest / should_upgrade（GITHUB_OUTPUT 兼容格式）
#
# Check the dsh upstream version; outputs current / latest / should_upgrade (GITHUB_OUTPUT-compatible)
# Usage: check-upstream.sh [repo-dir]（默认当前目录）
set -euo pipefail

DIR="${1:-.}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# 从 Dockerfile 提取当前版本（仅带值的 ARG 声明行）
#
# Extract the current version from the Dockerfile (only the ARG line with a value)
CURRENT="$(grep -E '^ARG DSH_VERSION=' "$DIR/Dockerfile" | head -n1 | cut -d= -f2)"
[ -n "$CURRENT" ] || { echo "错误：未能在 Dockerfile 找到 ARG DSH_VERSION" >&2; exit 1; }

# npm view 返回 dist-tags.latest；registry 由 npm 配置决定（CI 默认 npmjs）
#
# npm view returns dist-tags.latest; the registry follows npm config (npmjs by default on CI)
LATEST="$(npm view @deepseek-ai/dsh version)"
[ -n "$LATEST" ] || { echo "错误：npm view 未返回版本" >&2; exit 1; }

SHOULD="$("$SCRIPT_DIR/should-upgrade.sh" "$CURRENT" "$LATEST")"

echo "current=$CURRENT"
echo "latest=$LATEST"
echo "should_upgrade=$SHOULD"
