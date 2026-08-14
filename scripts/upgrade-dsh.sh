#!/usr/bin/env bash
# 升级脚本：将仓库中 dsh 上游版本号提升到指定版本
# 更新范围：Dockerfile（ARG + 注释示例）、docker-compose.yml（默认值）、README.md / README.zh.md（示例与变量表）
# DESIGN.md 为历史设计稿，不在自动升级范围（差异由 §10 实现差异记录人工维护）
#
# Upgrade script: bump the dsh upstream version in the repo to the given version
# Updated files: Dockerfile (ARG + comment example), docker-compose.yml (default), README.md / README.zh.md (examples and variable tables)
# DESIGN.md is a historical design doc, out of scope for auto-upgrade (differences are maintained manually in §10)
# Usage: upgrade-dsh.sh <new-version> [repo-dir]（默认当前目录）
set -euo pipefail

NEW="$1"
DIR="${2:-.}"

# 从 Dockerfile 提取当前版本（仅带值的 ARG 声明行）
#
# Extract the current version from the Dockerfile (only the ARG line with a value)
OLD="$(grep -E '^ARG DSH_VERSION=' "$DIR/Dockerfile" | head -n1 | cut -d= -f2)"
[ -n "$OLD" ] || { echo "错误：未能在 Dockerfile 找到 ARG DSH_VERSION" >&2; exit 1; }
[ "$NEW" != "$OLD" ] || { echo "新版本与当前版本相同（$NEW），无需升级" >&2; exit 0; }

FILES=(Dockerfile docker-compose.yml README.md README.zh.md)
for f in "${FILES[@]}"; do
  [ -f "$DIR/$f" ] || { echo "错误：缺少 $f" >&2; exit 1; }
  # npm 版本号仅含 [0-9a-zA-Z.-]，无 sed 特殊字符，可安全作替换串
  #
  # npm versions only contain [0-9a-zA-Z.-], no sed metacharacters, safe as a replacement string
  sed -i "s/${OLD}/${NEW}/g" "$DIR/$f"
done

# 原子验证：旧版本号必须全部消失，新版本号已写入
#
# Atomic verification: the old version must be fully gone and the new version written
LEFT="$(grep -l "$OLD" "$DIR"/Dockerfile "$DIR"/docker-compose.yml "$DIR"/README.md "$DIR"/README.zh.md 2>/dev/null || true)"
[ -z "$LEFT" ] || { echo "错误：旧版本仍残留于 $LEFT" >&2; exit 1; }
grep -q "$NEW" "$DIR/Dockerfile" || { echo "错误：新版本未写入" >&2; exit 1; }

echo "已升级：$OLD → $NEW（Dockerfile / docker-compose.yml / README.md / README.zh.md）"
