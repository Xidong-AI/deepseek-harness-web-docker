#!/usr/bin/env bash
# 创建自动升级失败 Issue（同版本去重：已存在相同标题的 open Issue 则跳过）
#
# Create an Issue for a failed auto-upgrade (dedup: skip when an open Issue with the same title exists)
# Usage: open-issue.sh <latest> <current>
#
# 测试注入：设置 GH=/path/to/mock 可替换 gh 命令（用于单测）
#
# Test injection: set GH=/path/to/mock to substitute the gh command (used by unit tests)
set -euo pipefail

LATEST="$1"
CURRENT="$2"
GH_BIN="${GH:-gh}"
TITLE="[自动升级] dsh 上游 $LATEST 构建冒烟测试失败"

EXISTING="$("$GH_BIN" issue list --state open --search "in:title \"$TITLE\"" --json number -q '.[0].number' 2>/dev/null || true)"
if [ -n "$EXISTING" ]; then
  echo "已存在同版本 Issue #$EXISTING，跳过创建"
  exit 0
fi

"$GH_BIN" issue create --title "$TITLE" --body "$(cat <<EOF
## 自动升级失败 | Auto-upgrade failed

- 上游版本 (upstream): \`$LATEST\`
- 仓库当前版本 (repo current): \`$CURRENT\`
- 检测时间 (detected at): \`$(date -u +%FT%TZ)\`
- 运行日志 (run log): ${GITHUB_SERVER_URL}/${GITHUB_REPOSITORY}/actions/runs/${GITHUB_RUN_ID}

升级脚本已将 \`DSH_VERSION\` 提升至 \`$LATEST\` 并执行构建与冒烟测试，但未通过，代码**未推送**至 master。
The upgrade script bumped \`DSH_VERSION\` to \`$LATEST\` and ran build & smoke tests, but they failed; the change was **not** pushed to master.

请人工排查：上游版本是否可安装、容器是否可正常启动，修复后手动升级或等待下次定时检查。
Please investigate: whether the upstream version installs and the container starts; fix it, then upgrade manually or wait for the next scheduled check.
EOF
)"
echo "已创建 Issue"
