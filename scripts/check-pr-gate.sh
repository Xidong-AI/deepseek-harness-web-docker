#!/usr/bin/env bash
# 门闩检查：是否存在针对指定版本的未关闭「自动升级」PR（head 分支为 auto-upgrade/dsh）
# 输出：1（存在，应跳过自动升级）/ 0（无，可继续）
#
# Gate check: whether an open auto-upgrade PR (head branch auto-upgrade/dsh) exists for the given version
# Output: 1 (exists, skip the auto-upgrade) / 0 (none, proceed)
# Usage: check-pr-gate.sh <version>
#
# 测试注入：设置 GH=/path/to/mock 可替换 gh 命令（用于单测）
#
# Test injection: set GH=/path/to/mock to substitute the gh command (used by unit tests)
set -euo pipefail

VERSION="$1"
GH_BIN="${GH:-gh}"

# 列出 auto-upgrade/dsh 分支上的 open PR，标题含目标版本即命中
# simp: gh 仅输出 JSON，匹配交给 jq（mock 易仿真）；查询上限 10 条，常驻单 PR 远不会触及
#
# List open PRs on auto-upgrade/dsh; a title containing the target version is a hit
# simp: gh only outputs JSON, matching is delegated to jq (easy to mock); the cap of 10 is far
# above the standing single PR
JSON="$("$GH_BIN" pr list --head auto-upgrade/dsh --state open --json title,number --limit 10 2>/dev/null || true)"
[ -n "$JSON" ] || { echo 0; exit 0; }

# 版本边界匹配（与 upgrade-dsh.sh 同思想）：先转义 VERSION 为正则字面量，再要求前后均非版本字符，
# 避免把 0.2.0 误匹配为标题中 0.2.0-rc.1 的前缀（npm 版本字符集 [0-9A-Za-z.-]）
#
# Version-boundary match (same idea as upgrade-dsh.sh): escape VERSION to a regex literal, then
# require non-version characters on both sides, so 0.2.0 is never matched as a prefix of
# 0.2.0-rc.1 in a title (npm version chars [0-9A-Za-z.-])
ESC="$(printf '%s' "$VERSION" | sed 's/[][\\^$.|*+?()]/\\&/g')"
MATCH="$(jq -r --arg v "$ESC" '.[] | select(.title | test("(^|[^-0-9A-Za-z.])" + $v + "([^-0-9A-Za-z.]|$)")) | .number' <<<"$JSON" | head -n1)"
[ -n "$MATCH" ] && echo 1 || echo 0
