#!/usr/bin/env bash
# 关闭过时的自动升级失败 Issue（升级成功后，旧版本的失败记录均已过时）
#
# Close stale auto-upgrade failure Issues (after a successful upgrade, older failure records are all stale)
# Usage: close-stale-issues.sh
#
# 测试注入：设置 GH=/path/to/mock 可替换 gh 命令（用于单测）
#
# Test injection: set GH=/path/to/mock to substitute the gh command (used by unit tests)
set -euo pipefail

GH_BIN="${GH:-gh}"

# GitHub Actions 兜底：CI 中 gh 必须有 GH_TOKEN，否则 exit 4；脚本内回退 GITHUB_TOKEN，
# 调用方显式传入的 GH_TOKEN 仍优先（与 open-issue.sh / push-upgrade-pr.sh 同一双层防御）
# 回归背景：本步骤曾漏配 env 且脚本无兜底，gh 报错被 2>/dev/null 吞掉 → 静默「无过时的失败 Issue」
#
# GitHub Actions fallback: gh needs GH_TOKEN in CI or exits 4; fall back to GITHUB_TOKEN here.
# An explicit GH_TOKEN still wins (same belt-and-suspenders as open-issue.sh / push-upgrade-pr.sh).
# Regression: this step once lacked env and fallback, so gh's error was swallowed by 2>/dev/null
# and stale Issues were silently never closed
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
export GH_TOKEN

JSON="$("$GH_BIN" issue list --state open --search 'in:title "[自动升级]"' --json title,number --limit 50 2>/dev/null || true)"
[ -n "$JSON" ] || { echo "无过时的失败 Issue"; exit 0; }

# 本次升级已成功：所有自动升级失败 Issue 均视为过时，全部关闭
#
# This upgrade succeeded: every auto-upgrade failure Issue is now stale; close them all
STALE="$(jq -r '.[] | .number' <<<"$JSON")"
for n in $STALE; do
  echo "关闭过时 Issue #$n"
  "$GH_BIN" issue close "$n"
done
[ -n "$STALE" ] || echo "无过时的失败 Issue"
