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

# npm view 返回 dist-tags.latest；registry 由 npm 配置决定（CI 默认 npmjs 无同步延迟；
# 若自建 runner 走镜像源如 npmmirror，dist-tags 可能有分钟级同步延迟，检测会略滞后但不误报）
#
# npm view returns dist-tags.latest; the registry follows npm config (npmjs by default on CI, no sync delay;
# self-hosted runners behind mirrors like npmmirror may see minute-level dist-tags lag — detection lags, never false-positives)
LATEST="$(npm view @deepseek-ai/dsh version)"
[ -n "$LATEST" ] || { echo "错误：npm view 未返回版本" >&2; exit 1; }

SHOULD="$("$SCRIPT_DIR/should-upgrade.sh" "$CURRENT" "$LATEST")"
# 转为布尔字符串输出：workflow 的 if 条件按 'true'/'false' 比较（此前输出 1/0 导致条件恒 false，自动升级永不触发）
#
# Emit a boolean string: the workflow's if conditions compare against 'true'/'false'
# (previously emitting 1/0 made the conditions always false, so auto-upgrade never ran)
SHOULD_BOOL=false
[ "$SHOULD" = "1" ] && SHOULD_BOOL=true

echo "current=$CURRENT"
echo "latest=$LATEST"
echo "should_upgrade=$SHOULD_BOOL"
