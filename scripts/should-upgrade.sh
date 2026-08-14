#!/usr/bin/env bash
# 版本比较：判断 latest 是否严格高于 current（semver 语义）
# 输出：1（应升级）/ 0（无需升级）
#
# Version comparison: whether latest is strictly newer than current (semver semantics)
# Output: 1 (should upgrade) / 0 (no upgrade needed)
# Usage: should-upgrade.sh <current> <latest>
set -euo pipefail

CURRENT="$1"
LATEST="$2"

[ "$CURRENT" = "$LATEST" ] && { echo 0; exit 0; }

# npx semver：latest 满足 >current 时输出自身，否则输出空
# simp: 借 npm 生态 semver 实现，避免自写版本比较（prerelease 如 0.1.0-rc.6 的排序规则易错）
#
# npx semver: echoes latest when it satisfies >current, otherwise empty
# simp: reuse the npm semver CLI instead of hand-rolling comparison (prerelease ordering like 0.1.0-rc.6 is error-prone)
UPDATED="$(npx --yes semver@7 -r ">$CURRENT" "$LATEST" 2>/dev/null || true)"
[ -n "$UPDATED" ] && echo 1 || echo 0
