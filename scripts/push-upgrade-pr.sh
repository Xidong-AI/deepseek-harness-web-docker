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
  # 始终基于 master 重建本地分支（工作树回到 master 最新内容），再以 --no-ff -s ours 合并远端分支历史：
  # 新提交以远端分支 HEAD 为祖先，push 必然 fast-forward；合并结果完全取 master 内容，
  # 保证 bump 永远基于 master 而非旧分支残留（ruleset 禁 force push 与删除分支）。
  # --no-ff 不可省：远端分支是 master 后代时（上次推送未合并的重试场景），普通 merge 会 fast-forward
  # 使工作树变成旧分支内容，bump 将无事可做
  #
  # Rebuild the local branch on master (worktree returns to master's latest), then merge the remote
  # branch history with --no-ff -s ours: the new commit descends from the remote branch HEAD, so the
  # push is guaranteed fast-forward; the merge result is exactly master's content, so the bump
  # always starts from master, never from stale branch leftovers
  # (the ruleset forbids force pushes and branch deletion).
  # --no-ff is essential: when the remote branch descends from master (a retry after an unmerged push),
  # a plain merge would fast-forward the worktree back to the stale branch content and leave nothing to bump
  git fetch origin "$BRANCH" >/dev/null 2>&1 || true
  git checkout -B "$BRANCH" master
  if git rev-parse --verify -q "refs/remotes/origin/$BRANCH" >/dev/null; then
    # -s ours 策略：合并结果树完全取本地（master）内容，仅将远端分支历史并入祖先链，
    # 保证新提交可 fast-forward 推送。与 -X ours（仅解决文本冲突）不同，-s ours 彻底无视
    # 分支内容且永不因冲突中止——旧分支上的内容一律以 master 为准，丢弃也无妨
    # （分支只含自动升级内容，最终以 master + 新 bump 为准）
    #
    # -s ours strategy: the merge result tree is exactly the local (master) content; the remote
    # branch history is only grafted into the ancestry so the new commit can be pushed fast-forward.
    # Unlike -X ours (which only resolves textual conflicts), -s ours ignores the branch content
    # entirely and never aborts on conflicts — anything stale on the branch is safely discarded
    # (the branch only carries auto-upgrade content; master plus the new bump is authoritative)
    git merge --no-ff --no-edit -s ours "origin/$BRANCH"
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
