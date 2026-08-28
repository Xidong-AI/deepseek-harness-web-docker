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

# npx semver 无参时按优先级升序打印；latest 排最后则严格更新
# simp: 借 npm 生态 semver 做纯排序，不用 range。>current 默认只匹配同元组
# prerelease（0.1.1-rc.2 不满足 >0.1.0-rc.7），正是自动升级卡住的原因
#
# npx semver with no flags prints versions in ascending precedence; latest is
# strictly newer if it sorts last. simp: reuse npm semver as a pure sort, not a
# range. >current by default only matches same-tuple prereleases (0.1.1-rc.2
# does not satisfy >0.1.0-rc.7 — why auto-upgrade stalled)
HIGHER="$(npx --yes semver@7 "$CURRENT" "$LATEST" 2>/dev/null | tail -n1 || true)"
[ "$HIGHER" = "$LATEST" ] && echo 1 || echo 0
