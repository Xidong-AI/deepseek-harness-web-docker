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

# 列出未关闭的自动升级失败 Issue，标题含目标版本即命中
# simp: gh 仅输出 JSON，匹配交给 jq（mock 易仿真）；查询上限 50 条，按版本去重后远不会触及
#
# List open auto-upgrade failure Issues; a title containing the target version is a hit
# simp: gh only outputs JSON, matching is delegated to jq (easy to mock); cap of 50 is far above the deduped per-version count
JSON="$("$GH_BIN" issue list --state open --search 'in:title "[自动升级]"' --json title,number --limit 50 2>/dev/null || true)"
[ -n "$JSON" ] || { echo 0; exit 0; }

MATCH="$(jq -r '.[] | select(.title | contains("'"$VERSION"'")) | .number' <<<"$JSON" | head -n1)"
[ -n "$MATCH" ] && echo 1 || echo 0
