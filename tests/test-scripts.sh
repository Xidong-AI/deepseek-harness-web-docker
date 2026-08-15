#!/usr/bin/env bash
# 单测：should-upgrade.sh（版本比较）与 upgrade-dsh.sh（文件更新）
#
# Unit tests: should-upgrade.sh (version comparison) and upgrade-dsh.sh (file updates)
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

echo "== upgrade-dsh.sh（文件更新）=="
# fixture：直接从仓库复制当前文件（模拟"升级前"状态）
#
# fixtures: copy the current repo files directly (simulating the "pre-upgrade" state)
for f in Dockerfile docker-compose.yml README.md README.zh.md DESIGN.md; do
  cp "$ROOT/$f" "$TMP/"
done
"$ROOT/scripts/upgrade-dsh.sh" 0.2.0 "$TMP" >/dev/null
assert_no_grep "Dockerfile 旧版本已清除"      "0\.1\.0-rc\.6" "$TMP/Dockerfile"
assert_grep     "Dockerfile 新版本已写入"      "0\.2\.0"       "$TMP/Dockerfile"
assert_no_grep "docker-compose.yml 旧版本清除" "0\.1\.0-rc\.6" "$TMP/docker-compose.yml"
assert_grep     "docker-compose.yml 新版本写入" "0\.2\.0"       "$TMP/docker-compose.yml"
assert_no_grep "README.md 旧版本已清除"        "0\.1\.0-rc\.6" "$TMP/README.md"
assert_no_grep "README.zh.md 旧版本已清除"     "0\.1\.0-rc\.6" "$TMP/README.zh.md"
assert_grep     "DESIGN.md 不受影响"           "0\.1\.0-rc\.6" "$TMP/DESIGN.md"

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
"$ROOT/scripts/upgrade-dsh.sh" 0.1.0-rc.6 "$TMP2" > "$TMP2/idempotent.out" 2>&1 || true
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
esac
MOCK
chmod +x "$MOCK_GH"
OPEN_ISSUE="$ROOT/scripts/open-issue.sh"

MOCK_LOG="$TMP/mock1.log" MOCK_LIST_OUT='[]' GH="$MOCK_GH" \
  "$OPEN_ISSUE" 0.2.0 0.1.0-rc.6 > "$TMP/issue1.out" 2>&1
assert_grep "无已有 Issue 时创建"            "已创建 Issue" "$TMP/issue1.out"
assert_grep "create 调用含新版本标题"         "issue create --title \[自动升级\] dsh 上游 0.2.0" "$TMP/mock1.log"
assert_grep "create 调用含上游版本正文"        "0.2.0" "$TMP/mock1.log"

MOCK_LOG="$TMP/mock2.log" MOCK_LIST_OUT='[{"number":7}]' GH="$MOCK_GH" \
  "$OPEN_ISSUE" 0.2.0 0.1.0-rc.6 > "$TMP/issue2.out" 2>&1
assert_grep "已有同版本 Issue 时跳过"         "已存在同版本 Issue #7" "$TMP/issue2.out"
assert_no_grep "去重时不调用 create"          "issue create" "$TMP/mock2.log"

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

echo
echo "结果：$PASS 通过，$FAIL 失败"
[ "$FAIL" -eq 0 ] || exit 1
