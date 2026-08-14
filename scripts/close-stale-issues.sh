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
