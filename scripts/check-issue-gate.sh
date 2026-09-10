#!/usr/bin/env bash
# 门闩检查：是否存在针对指定版本的未关闭「自动升级」失败 Issue
# 输出：1（存在，应跳过自动升级）/ 0（无，可继续）
#
# Gate check: whether an open auto-upgrade failure Issue exists for the given version
# Output: 1 (exists, skip the auto-upgrade) / 0 (none, proceed)
# Usage: check-issue-gate.sh <version>
#
# 测试注入：设置 GH=/path/to/mock 可替换 gh 命令（用于单测）
#
# Test injection: set GH=/path/to/mock to substitute the gh command (used by unit tests)
set -euo pipefail

VERSION="$1"
GH_BIN="${GH:-gh}"

# GitHub Actions 兜底：CI 中 gh 必须有 GH_TOKEN，否则 exit 4；脚本内回退 GITHUB_TOKEN，
# 调用方显式传入的 GH_TOKEN 仍优先（与 open-issue.sh / push-upgrade-pr.sh 同一双层防御）
# 回归背景：本步骤曾漏配 env 且脚本无兜底，gh 报错被 2>/dev/null 吞掉 → 门闩静默恒不拦截
#
# GitHub Actions fallback: gh needs GH_TOKEN in CI or exits 4; fall back to GITHUB_TOKEN here.
# An explicit GH_TOKEN still wins (same belt-and-suspenders as open-issue.sh / push-upgrade-pr.sh).
# Regression: this step once lacked env and fallback, so gh's error was swallowed by 2>/dev/null
# and the gate silently never blocked
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
export GH_TOKEN

# 列出未关闭的自动升级失败 Issue，标题含目标版本即命中（匹配在下方按版本边界进行）
#
# List open auto-upgrade failure Issues; a title containing the target version is a hit
# (matching below is done at version boundaries)
# simp: gh 仅输出 JSON，匹配交给 jq（mock 易仿真）；查询上限 50 条，按版本去重后远不会触及
#
# simp: gh only outputs JSON, matching is delegated to jq (easy to mock); cap of 50 is far above the deduped per-version count
JSON="$("$GH_BIN" issue list --state open --search 'in:title "[自动升级]"' --json title,number --limit 50 2>/dev/null || true)"
[ -n "$JSON" ] || { echo 0; exit 0; }

# 版本边界匹配（与 check-pr-gate.sh / upgrade-dsh.sh 同思想）：先转义 VERSION 为正则字面量，
# 再要求前后均非版本字符，避免 0.2.0 误匹配标题中的 0.2.0-rc.1（npm 版本字符集 [0-9A-Za-z.-]）
#
# Version-boundary match (same idea as check-pr-gate.sh / upgrade-dsh.sh): escape VERSION to a
# regex literal, then require non-version characters on both sides, so 0.2.0 is never matched as
# a prefix of 0.2.0-rc.1 in a title (npm version chars [0-9A-Za-z.-])
ESC="$(printf '%s' "$VERSION" | sed 's/[][\\^$.|*+?()]/\\&/g')"
MATCH="$(jq -r --arg v "$ESC" '.[] | select(.title | test("(^|[^-0-9A-Za-z.])" + $v + "([^-0-9A-Za-z.]|$)")) | .number' <<<"$JSON" | head -n1)"
[ -n "$MATCH" ] && echo 1 || echo 0
