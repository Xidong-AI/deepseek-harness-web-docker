#!/usr/bin/env bash
# 单测：should-upgrade.sh（版本比较）、upgrade-dsh.sh（文件更新）、open-issue.sh（失败 Issue）、
# check-issue-gate.sh（失败 Issue 门闩）、close-stale-issues.sh（过时 Issue 清理）、
# check-pr-gate.sh（自动升级 PR 门闩）与 push-upgrade-pr.sh 的 upsert_pr（PR 创建/更新）
# git 分支准备与推送部分难 mock，由 CI 真机验证
#
# Unit tests: should-upgrade.sh (version comparison), upgrade-dsh.sh (file updates), open-issue.sh
# (failure Issue), check-issue-gate.sh (failure Issue gate), close-stale-issues.sh (stale Issue cleanup),
# check-pr-gate.sh (auto-upgrade PR gate), and push-upgrade-pr.sh's upsert_pr (PR create/update)
# The git branch prep and push parts are hard to mock and are verified live on CI
# Usage: tests/test-scripts.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0

# 断言辅助
#
# assertion helpers
assert_eq() { # <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then PASS=$((PASS+1)); echo "  ✓ $1"; else
    FAIL=$((FAIL+1)); echo "  ✗ $1：期望 [$2] 实际 [$3]"
  fi
}
assert_grep() { # <desc> <pattern> <file>（期望存在匹配）
  if grep -q "$2" "$3"; then PASS=$((PASS+1)); echo "  ✓ $1"; else
    FAIL=$((FAIL+1)); echo "  ✗ $1：$3 未匹配 $2"
  fi
}
assert_no_grep() { # <desc> <pattern> <file>（期望无匹配）
  if grep -q "$2" "$3"; then FAIL=$((FAIL+1)); echo "  ✗ $1：$3 意外匹配 $2"; else
    PASS=$((PASS+1)); echo "  ✓ $1"
  fi
}

echo "== should-upgrade.sh（版本比较）=="
SU="$ROOT/scripts/should-upgrade.sh"
assert_eq "相等版本不升级"           0 "$("$SU" 0.1.0-rc.6 0.1.0-rc.6)"
assert_eq "rc → 正式版应升级"         1 "$("$SU" 0.1.0-rc.6 0.1.0)"
assert_eq "patch 升级应升级"          1 "$("$SU" 0.1.0 0.1.1)"
assert_eq "minor 升级应升级"          1 "$("$SU" 0.1.0 0.2.0)"
assert_eq "上游回退（降级）不升级"    0 "$("$SU" 0.1.0-rc.6 0.1.0-rc.5)"
assert_eq "正式版后的 rc 不升级"      0 "$("$SU" 0.1.0 0.1.0-rc.9)"
# 同元组更高 rc 原本就能过；跨元组 prerelease 才是 range 默认规则的盲区
# （>0.1.0-rc.7 不匹配 0.1.1-rc.2，正是自动升级卡住的原因）
#
# A higher rc in the same tuple already passed; cross-tuple prereleases are the
# range default's blind spot (>0.1.0-rc.7 does not match 0.1.1-rc.2 — why auto-upgrade stalled)
assert_eq "同元组更高 rc 应升级"      1 "$("$SU" 0.1.0-rc.7 0.1.0-rc.8)"
assert_eq "跨元组 prerelease 应升级"  1 "$("$SU" 0.1.0-rc.7 0.1.1-rc.2)"
assert_eq "跨元组 alpha 应升级"       1 "$("$SU" 0.1.0-rc.7 0.1.2-alpha.1)"

echo "== upgrade-dsh.sh（文件更新）=="
# fixture：直接从仓库复制当前文件（模拟"升级前"状态）
#
# fixtures: copy the current repo files directly (simulating the "pre-upgrade" state)
for f in Dockerfile docker-compose.yml README.md README.zh.md DESIGN.md; do
  cp "$ROOT/$f" "$TMP/"
done
# 当前版本号从 fixture Dockerfile 动态提取：升级脚本可能升级到任意上游版本，
# 硬编码版本会让「旧版本清除」断言失效或空转
#
# Current version is read from the fixture Dockerfile: the upgrade script may bump to any
# upstream version, so hardcoding one would make the "old version gone" asserts stale or vacuous
CUR_VERSION="$(grep -E '^ARG DSH_VERSION=' "$TMP/Dockerfile" | head -n1 | cut -d= -f2)"
ESC_VERSION="$(printf '%s' "$CUR_VERSION" | sed 's/[][\\^$.|*+?()]/\\&/g')"
"$ROOT/scripts/upgrade-dsh.sh" 0.2.0 "$TMP" >/dev/null
assert_no_grep "Dockerfile 旧版本已清除"      "$ESC_VERSION"  "$TMP/Dockerfile"
assert_grep     "Dockerfile 新版本已写入"      "0\.2\.0"       "$TMP/Dockerfile"
assert_no_grep "docker-compose.yml 旧版本清除" "$ESC_VERSION"  "$TMP/docker-compose.yml"
assert_grep     "docker-compose.yml 新版本写入" "0\.2\.0"       "$TMP/docker-compose.yml"
assert_no_grep "README.md 旧版本已清除"        "$ESC_VERSION"  "$TMP/README.md"
assert_no_grep "README.zh.md 旧版本已清除"     "$ESC_VERSION"  "$TMP/README.zh.md"
# DESIGN.md 是历史设计稿，不在升级范围：升级前后内容必须完全一致
# （不依赖任何版本号，避免历史引用随版本演进失效）
#
# DESIGN.md is a historical design doc, out of the upgrade scope: its content must be
# byte-identical after an upgrade (independent of any version number)
assert_eq "DESIGN.md 不受影响" "$(md5sum < "$ROOT/DESIGN.md")" "$(md5sum < "$TMP/DESIGN.md")"

echo "== upgrade-dsh.sh（版本边界：历史引用不被误改）=="
TMP3="$TMP/boundary"
mkdir -p "$TMP3"
for f in Dockerfile README.md README.zh.md; do
  printf 'ARG DSH_VERSION=0.1.0\n' > "$TMP3/$f"
done
# shellcheck disable=SC2016 # 单引号是有意的：fixture 需要字面 ${DSH_VERSION:-0.1.0}
printf 'DSH_VERSION: ${DSH_VERSION:-0.1.0}\n' > "$TMP3/docker-compose.yml"
printf '历史版本参考 0.1.0-rc.6 仅供说明\n' >> "$TMP3/README.md"
"$ROOT/scripts/upgrade-dsh.sh" 0.1.1 "$TMP3" >/dev/null
assert_grep     "新版本 0.1.1 已写入"          "ARG DSH_VERSION=0\.1\.1" "$TMP3/README.md"
assert_grep     "compose 精确上下文已替换"     "DSH_VERSION: \${DSH_VERSION:-0\.1\.1}" "$TMP3/docker-compose.yml"
# 独立的 0.1.0 必须消失（版本边界匹配；0.1.0-rc.6 内的子串不算）
#
# standalone 0.1.0 must be gone (matched at version boundaries; the substring inside 0.1.0-rc.6 doesn't count)
assert_no_grep  "独立 0.1.0 全部替换"          "\(^\|[^-0-9A-Za-z.]\)0\.1\.0\([^-0-9A-Za-z.]\|$\)" "$TMP3/README.md"
assert_grep     "历史引用 0.1.0-rc.6 保留"     "0\.1\.0-rc\.6" "$TMP3/README.md"

echo "== upgrade-dsh.sh（同版本幂等）=="
TMP2="$TMP/idempotent"
mkdir -p "$TMP2"
for f in Dockerfile docker-compose.yml README.md README.zh.md; do
  cp "$ROOT/$f" "$TMP2/"
done
# 以 fixture 中的当前版本为参数：同版本必须走「无需升级」分支（版本号动态提取，
# 与 upgrade-dsh.sh 内部读取 Dockerfile 的方式一致，避免硬编码随上游升级失配）
#
# Pass the fixture's own current version: an equal version must take the "no upgrade needed"
# branch. The version is read the same way upgrade-dsh.sh reads the Dockerfile, so the test
# cannot drift when the upstream version bumps
CUR_VERSION="$(grep -E '^ARG DSH_VERSION=' "$TMP2/Dockerfile" | head -n1 | cut -d= -f2)"
"$ROOT/scripts/upgrade-dsh.sh" "$CUR_VERSION" "$TMP2" > "$TMP2/idempotent.out" 2>&1 || true
assert_eq "同版本返回提示且不报错" 0 "$?"
assert_grep "同版本提示输出" "无需升级" "$TMP2/idempotent.out"

echo "== open-issue.sh (mock gh)=="
MOCK_GH="$TMP/mock-gh"
cat > "$MOCK_GH" <<'MOCK'
#!/usr/bin/env bash
echo "$*" >> "${MOCK_LOG:?}"
case "$1 $2" in
  "issue list")
    if [[ "$*" == *"-q"* ]]; then
      # 仿真 gh 的 -q jq 查询：[] → 空输出；[{"number":7}] → 7
      python3 -c "import json,sys; d=json.load(sys.stdin); print(d[0]['number'] if d else '')" <<< "${MOCK_LIST_OUT-}"
    else
      # 原始 JSON 输出（gate/close 脚本自行 jq 解析）；未设置时输出空 = 仿真 gh 失败
      echo "${MOCK_LIST_OUT-}"
    fi
    ;;
  "issue create") echo "created" ;;
  "issue close") echo "closed $3" ;;
  "pr list") echo "${MOCK_LIST_OUT-}" ;;
  "pr view") echo "${MOCK_PR_STATE-}" ;;
  "pr create") echo "created" ;;
  "pr edit") echo "edited" ;;
esac
MOCK
chmod +x "$MOCK_GH"
OPEN_ISSUE="$ROOT/scripts/open-issue.sh"

MOCK_LOG="$TMP/mock1.log" MOCK_LIST_OUT='[]' GH="$MOCK_GH" \
  "$OPEN_ISSUE" 0.2.0 0.1.0-rc.6 > "$TMP/issue1.out" 2>&1
assert_grep "无已有 Issue 时创建"            "已创建 Issue" "$TMP/issue1.out"
assert_grep "create 调用含新版本标题"         "issue create --title \[自动升级\] dsh 上游 0.2.0" "$TMP/mock1.log"
assert_grep "create 标题为通用失败措辞"       "升级流程失败" "$TMP/mock1.log"
assert_grep "create 调用含上游版本正文"        "0.2.0" "$TMP/mock1.log"

MOCK_LOG="$TMP/mock2.log" MOCK_LIST_OUT='[{"number":7}]' GH="$MOCK_GH" \
  "$OPEN_ISSUE" 0.2.0 0.1.0-rc.6 > "$TMP/issue2.out" 2>&1
assert_grep "已有同版本 Issue 时跳过"         "已存在同版本 Issue #7" "$TMP/issue2.out"
assert_no_grep "去重时不调用 create"          "issue create" "$TMP/mock2.log"

# GitHub Actions 兜底：仅设 GITHUB_TOKEN 时，脚本应将其映射为 GH_TOKEN 并透传给 gh
# (upstream-check.yml 早期版本漏配 env，导致 exit 4 的根因)
#
# GitHub Actions fallback: when only GITHUB_TOKEN is set, the script must surface it as
# GH_TOKEN to gh. (This is the root cause of the upstream-check.yml exit-4 failure before
# the env was wired up)
GH_TOKEN_GUARD="$TMP/gh-token-guard"
cat > "$GH_TOKEN_GUARD" <<'GUARD'
#!/usr/bin/env bash
echo "GH_TOKEN=${GH_TOKEN-unset}" >> "${GUARD_LOG:?}"
exec "$GH_REAL" "$@"
GUARD
chmod +x "$GH_TOKEN_GUARD"
GUARD_LOG="$TMP/mock_guard.log" MOCK_LOG="$TMP/mock_guard_gh.log" MOCK_LIST_OUT='[]' \
  GH="$GH_TOKEN_GUARD" GH_REAL="$MOCK_GH" \
  GITHUB_TOKEN=ghp_ci_fallback \
  "$OPEN_ISSUE" 0.2.0 0.1.0-rc.6 > "$TMP/issue_guard.out" 2>&1
assert_grep "GITHUB_TOKEN 兜底为 GH_TOKEN" "GH_TOKEN=ghp_ci_fallback" "$TMP/mock_guard.log"
# 显式 GH_TOKEN 应优先于 GITHUB_TOKEN（避免 CI 中被无关变量意外覆盖）
#
# Explicit GH_TOKEN must win over GITHUB_TOKEN (so unrelated CI vars cannot clobber it)
GUARD_LOG="$TMP/mock_guard2.log" MOCK_LOG="$TMP/mock_guard2_gh.log" MOCK_LIST_OUT='[]' \
  GH="$GH_TOKEN_GUARD" GH_REAL="$MOCK_GH" \
  GH_TOKEN=ghp_explicit GITHUB_TOKEN=ghp_should_lose \
  "$OPEN_ISSUE" 0.2.0 0.1.0-rc.6 > "$TMP/issue_guard2.out" 2>&1
assert_grep "显式 GH_TOKEN 优先" "GH_TOKEN=ghp_explicit" "$TMP/mock_guard2.log"

echo "== check-issue-gate.sh (mock gh)=="
GATE="$ROOT/scripts/check-issue-gate.sh"
GATE_LIST='[{"title":"[自动升级] dsh 上游 0.2.0 构建冒烟测试失败","number":5}]'

MOCK_LOG="$TMP/mock3.log" MOCK_LIST_OUT="$GATE_LIST" GH="$MOCK_GH" \
  "$GATE" 0.2.0 > "$TMP/gate1.out" 2>&1
assert_eq "同版本失败 Issue 存在时拦截" 1 "$(cat "$TMP/gate1.out")"

MOCK_LOG="$TMP/mock4.log" MOCK_LIST_OUT="$GATE_LIST" GH="$MOCK_GH" \
  "$GATE" 0.2.1 > "$TMP/gate2.out" 2>&1
assert_eq "不同版本失败 Issue 不拦截" 0 "$(cat "$TMP/gate2.out")"

MOCK_LOG="$TMP/mock5.log" MOCK_LIST_OUT='[]' GH="$MOCK_GH" \
  "$GATE" 0.2.0 > "$TMP/gate3.out" 2>&1
assert_eq "无失败 Issue 不拦截" 0 "$(cat "$TMP/gate3.out")"

MOCK_LOG="$TMP/mock6.log" MOCK_LIST_OUT='' GH="$MOCK_GH" \
  "$GATE" 0.2.0 > "$TMP/gate4.out" 2>&1
assert_eq "gh 查询失败（空输出）不拦截" 0 "$(cat "$TMP/gate4.out")"

# GitHub Actions 兜底：仅设 GITHUB_TOKEN 时应映射为 GH_TOKEN（回归：CI 步骤曾漏配 env 且脚本无兜底，
# gh exit 4 被 2>/dev/null 吞掉 → 门闩静默恒不拦截）
#
# GitHub Actions fallback: GITHUB_TOKEN must be surfaced as GH_TOKEN (regression: the CI step
# lacked env and the script had no fallback, so gh exit 4 was swallowed and the gate never blocked)
GUARD_LOG="$TMP/mock_guard_gate.log" MOCK_LOG="$TMP/mock_guard_gate_gh.log" MOCK_LIST_OUT='[]' \
  GH="$GH_TOKEN_GUARD" GH_REAL="$MOCK_GH" GITHUB_TOKEN=ghp_ci_fallback \
  "$GATE" 0.2.0 > "$TMP/gate_guard.out" 2>&1
assert_grep "gate：GITHUB_TOKEN 兜底为 GH_TOKEN" "GH_TOKEN=ghp_ci_fallback" "$TMP/mock_guard_gate.log"

echo "== close-stale-issues.sh (mock gh)=="
CLOSE="$ROOT/scripts/close-stale-issues.sh"
CLOSE_LIST='[{"title":"[自动升级] dsh 上游 0.1.9 构建冒烟测试失败","number":9},{"title":"[自动升级] dsh 上游 0.2.0 构建冒烟测试失败","number":7}]'

MOCK_LOG="$TMP/mock7.log" MOCK_LIST_OUT="$CLOSE_LIST" GH="$MOCK_GH" \
  "$CLOSE" > "$TMP/close1.out" 2>&1
assert_grep "关闭第一条过时 Issue" "关闭过时 Issue #9" "$TMP/close1.out"
assert_grep "关闭第二条过时 Issue" "关闭过时 Issue #7" "$TMP/close1.out"
assert_eq "close 调用两次" 2 "$(grep -c 'issue close' "$TMP/mock7.log")"
assert_grep "close 参数为 Issue 编号" "issue close 9" "$TMP/mock7.log"

MOCK_LOG="$TMP/mock8.log" MOCK_LIST_OUT='[]' GH="$MOCK_GH" \
  "$CLOSE" > "$TMP/close2.out" 2>&1
assert_grep "无 Issue 时提示" "无过时的失败 Issue" "$TMP/close2.out"
assert_no_grep "无 Issue 时不调用 close" "issue close" "$TMP/mock8.log"

# GitHub Actions 兜底：仅设 GITHUB_TOKEN 时应映射为 GH_TOKEN（回归：CI 步骤曾漏配 env 且脚本无兜底，
# gh exit 4 被 2>/dev/null 吞掉 → 静默「无过时的失败 Issue」，Issue 永不关闭）
#
# GitHub Actions fallback: GITHUB_TOKEN must be surfaced as GH_TOKEN (regression: the CI step
# lacked env and the script had no fallback, so gh exit 4 was swallowed and stale Issues were never closed)
GUARD_LOG="$TMP/mock_guard_close.log" MOCK_LOG="$TMP/mock_guard_close_gh.log" MOCK_LIST_OUT='[]' \
  GH="$GH_TOKEN_GUARD" GH_REAL="$MOCK_GH" GITHUB_TOKEN=ghp_ci_fallback \
  "$CLOSE" > "$TMP/close_guard.out" 2>&1
assert_grep "close：GITHUB_TOKEN 兜底为 GH_TOKEN" "GH_TOKEN=ghp_ci_fallback" "$TMP/mock_guard_close.log"

echo "== check-pr-gate.sh (mock gh)=="
PRGATE="$ROOT/scripts/check-pr-gate.sh"
PRGATE_LIST='[{"title":"【维护，构建】升级 dsh 版本至 0.2.0","number":11}]'

MOCK_LOG="$TMP/prgate1.log" MOCK_LIST_OUT="$PRGATE_LIST" GH="$MOCK_GH" \
  "$PRGATE" 0.2.0 > "$TMP/prgate1.out" 2>&1
assert_eq "同版本 open PR 存在时拦截" 1 "$(cat "$TMP/prgate1.out")"

MOCK_LOG="$TMP/prgate2.log" MOCK_LIST_OUT="$PRGATE_LIST" GH="$MOCK_GH" \
  "$PRGATE" 0.2.1 > "$TMP/prgate2.out" 2>&1
assert_eq "不同版本 PR 不拦截" 0 "$(cat "$TMP/prgate2.out")"

# 版本前缀边界：0.2.0 不得匹配标题中的 0.2.0-rc.1（与 upgrade-dsh.sh 的边界替换同思想）
#
# Version-prefix boundary: 0.2.0 must not match 0.2.0-rc.1 in a title
# (same idea as upgrade-dsh.sh's boundary replacement)
PRGATE_RC='[{"title":"【维护，构建】升级 dsh 版本至 0.2.0-rc.1","number":12}]'
MOCK_LOG="$TMP/prgate3.log" MOCK_LIST_OUT="$PRGATE_RC" GH="$MOCK_GH" \
  "$PRGATE" 0.2.0 > "$TMP/prgate3.out" 2>&1
assert_eq "版本前缀不误拦（0.2.0 vs 0.2.0-rc.1）" 0 "$(cat "$TMP/prgate3.out")"

MOCK_LOG="$TMP/prgate4.log" MOCK_LIST_OUT='[]' GH="$MOCK_GH" \
  "$PRGATE" 0.2.0 > "$TMP/prgate4.out" 2>&1
assert_eq "无 PR 不拦截" 0 "$(cat "$TMP/prgate4.out")"

MOCK_LOG="$TMP/prgate5.log" MOCK_LIST_OUT='' GH="$MOCK_GH" \
  "$PRGATE" 0.2.0 > "$TMP/prgate5.out" 2>&1
assert_eq "gh 查询失败（空输出）不拦截" 0 "$(cat "$TMP/prgate5.out")"

# GitHub Actions 兜底：仅设 GITHUB_TOKEN 时应映射为 GH_TOKEN（回归：CI 步骤曾漏配 env 且脚本无兜底，
# gh exit 4 被 2>/dev/null 吞掉 → PR 门闩静默恒不拦截）
#
# GitHub Actions fallback: GITHUB_TOKEN must be surfaced as GH_TOKEN (regression: the CI step
# lacked env and the script had no fallback, so gh exit 4 was swallowed and the PR gate never blocked)
GUARD_LOG="$TMP/mock_guard_prgate.log" MOCK_LOG="$TMP/mock_guard_prgate_gh.log" MOCK_LIST_OUT='[]' \
  GH="$GH_TOKEN_GUARD" GH_REAL="$MOCK_GH" GITHUB_TOKEN=ghp_ci_fallback \
  "$PRGATE" 0.2.0 > "$TMP/prgate_guard.out" 2>&1
assert_grep "prgate：GITHUB_TOKEN 兜底为 GH_TOKEN" "GH_TOKEN=ghp_ci_fallback" "$TMP/mock_guard_prgate.log"

echo "== push-upgrade-pr.sh upsert_pr (mock gh)=="
# source 载入函数（脚本入口有 BASH_SOURCE 守卫，不执行 main）；
# 需先设置 GH 再 source，使脚本顶部 GH_BIN 指向 mock
#
# Source to load the function (the script has a BASH_SOURCE guard and won't run main);
# set GH before sourcing so the script's top-level GH_BIN points at the mock
PRPUSH="$ROOT/scripts/push-upgrade-pr.sh"
# shellcheck disable=SC1090
GH="$MOCK_GH" source "$PRPUSH"

MOCK_LOG="$TMP/prpush1.log" MOCK_PR_STATE=OPEN GH="$MOCK_GH" \
  upsert_pr 0.2.0 0.1.0-rc.6 > "$TMP/prpush1.out" 2>&1
assert_grep "PR 为 OPEN 时调用 edit" "pr edit auto-upgrade/dsh" "$TMP/prpush1.log"
assert_grep "edit 标题含新版本" "升级 dsh 版本至 0.2.0" "$TMP/prpush1.log"

MOCK_LOG="$TMP/prpush2.log" MOCK_PR_STATE='' GH="$MOCK_GH" \
  upsert_pr 0.2.0 0.1.0-rc.6 > "$TMP/prpush2.out" 2>&1
assert_grep "无 PR 时调用 create" "pr create" "$TMP/prpush2.log"
assert_grep "create head 为常驻分支" "auto-upgrade/dsh" "$TMP/prpush2.log"
assert_grep "create body 含上游版本" "0.2.0" "$TMP/prpush2.log"

MOCK_LOG="$TMP/prpush3.log" MOCK_PR_STATE=MERGED GH="$MOCK_GH" \
  upsert_pr 0.2.0 0.1.0-rc.6 > "$TMP/prpush3.out" 2>&1
assert_grep "PR 已合并时重新 create" "pr create" "$TMP/prpush3.log"

MOCK_LOG="$TMP/prpush4.log" MOCK_PR_STATE=CLOSED GH="$MOCK_GH" \
  upsert_pr 0.2.0 0.1.0-rc.6 > "$TMP/prpush4.out" 2>&1
assert_grep "PR 已关闭时重新 create" "pr create" "$TMP/prpush4.log"

echo
echo "结果：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
