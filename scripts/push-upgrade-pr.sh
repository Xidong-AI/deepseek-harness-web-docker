#!/usr/bin/env bash
# 常驻 PR 分支的推送与 PR 维护脚本（两个子命令）
#   prepare                     准备 PR 分支：从 master 新建，或合并 master 最新内容（保证后续 push 可 fast-forward）
#   push <latest> <current>     提交升级、推送 auto-upgrade/dsh 分支并创建/更新唯一 PR
# 版本提升（upgrade-dsh.sh）与冒烟测试（smoke-test.sh）由调用方在两个子命令之间完成
#
# Push and maintain the standing PR branch (two subcommands)
#   prepare                      Prep the PR branch: create it from master, or merge master's latest
#                                content (so the later push is guaranteed fast-forward)
#   push <latest> <current>      Commit the upgrade, push auto-upgrade/dsh, and create/update the single PR
# The version bump (upgrade-dsh.sh) and smoke test (smoke-test.sh) run between the two subcommands
#
# 测试注入：设置 GH=/path/to/mock 可替换 gh 命令（用于单测）
#
# Test injection: set GH=/path/to/mock to substitute the gh command (used by unit tests)
set -euo pipefail

BRANCH="auto-upgrade/dsh"

# gh 凭据双兜底：GH_TOKEN 优先，回退 GITHUB_TOKEN（与 open-issue.sh 同模式）
#
# gh credential belt-and-suspenders: GH_TOKEN wins, GITHUB_TOKEN as fallback (same pattern as open-issue.sh)
GH_BIN="${GH:-gh}"
GH_TOKEN="${GH_TOKEN:-${GITHUB_TOKEN:-}}"
export GH_TOKEN

pr_body() { # <latest> <current>
  local latest="$1" current="$2"
  cat <<EOF
## 自动升级 | Auto-upgrade

- 上游版本 (upstream): \`$latest\`
- 仓库当前版本 (repo current): \`$current\`
- 变更文件 (files): Dockerfile / docker-compose.yml / README.md / README.zh.md
- 运行日志 (run log): ${GITHUB_SERVER_URL:-https://github.com}/${GITHUB_REPOSITORY:-}/actions/runs/${GITHUB_RUN_ID:-}

升级脚本已提升版本并通过构建与冒烟测试（通过后才推送本分支）。
The upgrade script bumped the version and passed build & smoke tests (this branch is pushed only after they pass).

合并时请勾选 **Delete branch**，下次自动升级将重建分支。
Please tick **Delete branch** when merging so the next auto-upgrade can recreate the branch.
EOF
}

upsert_pr() { # <latest> <current>
  local latest="$1" current="$2"
  local title state
  title="【维护，构建】升级 dsh 版本至 $latest"
  # 该分支已有 OPEN PR 时编辑刷新；否则新建（无 PR / 已合并 / 已关闭）
  #
  # Edit an OPEN PR on this branch; otherwise create a new one (none / merged / closed)
  state="$("$GH_BIN" pr view "$BRANCH" --json state -q '.state' 2>/dev/null || true)"
  if [ "$state" = "OPEN" ]; then
    "$GH_BIN" pr edit "$BRANCH" --title "$title" --body "$(pr_body "$latest" "$current")"
  else
    "$GH_BIN" pr create --base master --head "$BRANCH" --title "$title" --body "$(pr_body "$latest" "$current")"
  fi
}

prepare_branch() {
  # 分支不存在 → 从 master 新建；存在 → 合并 master 最新内容：
  # 工作树回到 master 状态（-X theirs），并产生以远端分支 HEAD 为祖先的合并提交，
  # 使后续 push 必然 fast-forward（ruleset 禁 force push 与删除分支）
  #
  # No branch → create from master; exists → merge master's latest:
  # the worktree returns to master's state (-X theirs) and the merge commit descends from the
  # remote branch HEAD, so the later push is guaranteed fast-forward
  # (the ruleset forbids force pushes and branch deletion)
  git fetch origin "$BRANCH" >/dev/null 2>&1 || true
  if git rev-parse --verify -q "refs/remotes/origin/$BRANCH" >/dev/null; then
    git checkout -B "$BRANCH" "origin/$BRANCH"
    # -X theirs 仅能解决文本冲突；结构性冲突（如文件删除）会中止合并，由 set -e 转为失败 Issue 人工介入
    #
    # -X theirs only resolves textual conflicts; structural ones (e.g. file deletion) abort the
    # merge and fail the job via set -e, surfacing as a failure Issue for human intervention
    git merge --no-edit -X theirs master
  else
    git checkout -B "$BRANCH" master
  fi
}

push_branch() { # <latest> <current>
  local latest="$1" current="$2"
  git config user.name "github-actions[bot]"
  git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
  git add Dockerfile docker-compose.yml README.md README.zh.md
  git commit -m "【维护，构建】升级 dsh 版本至 $latest"
  git push origin "$BRANCH"
  upsert_pr "$latest" "$current"
}

main() {
  case "${1:-}" in
    prepare) prepare_branch ;;
    push)
      shift
      push_branch "${1:?用法：push-upgrade-pr.sh push <latest> <current>}" \
        "${2:?用法：push-upgrade-pr.sh push <latest> <current>}"
      ;;
    *) echo "用法：push-upgrade-pr.sh prepare|push <latest> <current>" >&2; exit 2 ;;
  esac
}

# 仅在直接执行时进入 main；被 source（单测载入函数）时不执行
#
# Enter main only when executed directly; a source (unit tests loading functions) skips it
if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  main "$@"
fi
