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

# npm 版本号字符集为 [0-9A-Za-z.-]；先转义 OLD 为正则字面量，再以「版本边界」锚定替换：
# 仅当 OLD 前后都不是版本字符时才替换，避免把 OLD 当作更长版本的前缀误改写
# （如 0.1.0 不应把历史引用 0.1.0-rc.6 改成 0.1.1-rc.6）。NEW 为 npm 版本号
# （不含 & 与 \），可直接作替换串。
#
# npm version chars are [0-9A-Za-z.-]; escape OLD to a regex literal, then anchor on
# version boundaries: replace OLD only when neither neighbour is a version char, so OLD
# is never rewritten as a prefix of a longer version (e.g. 0.1.0 must not turn the
# historical reference 0.1.0-rc.6 into 0.1.1-rc.6). NEW is an npm version (no & or \),
# safe as a replacement string.
ESC="$(printf '%s' "$OLD" | sed 's/[][\\^$.|*+?()]/\\&/g')"
# Dockerfile / README：版本边界替换（见上注释）
#
# Dockerfile / README: version-boundary replacement (see the note above)
for f in Dockerfile README.md README.zh.md; do
  [ -f "$DIR/$f" ] || { echo "错误：缺少 $f" >&2; exit 1; }
  sed -i "s/\\(^\\|[^-0-9A-Za-z.]\\)${ESC}\\([^-0-9A-Za-z.]\\|$\\)/\\1${NEW}\\2/g" "$DIR/$f"
done
# docker-compose.yml：版本号嵌在 ${DSH_VERSION:-OLD} 中，前置 `-` 是 bash 默认值语法，
# 与 prerelease 内部的 `-` 无法仅凭字符类区分，故用精确上下文替换（compose 中版本号只出现于该位置）
#
# docker-compose.yml: the version sits inside ${DSH_VERSION:-OLD}, whose leading `-` is bash
# default-value syntax and is indistinguishable from a prerelease `-` by character class alone,
# so replace with an exact context match (the version appears only at that spot in compose)
[ -f "$DIR/docker-compose.yml" ] || { echo "错误：缺少 docker-compose.yml" >&2; exit 1; }
sed -i "s/\${DSH_VERSION:-${ESC}}/\${DSH_VERSION:-${NEW}}/g" "$DIR/docker-compose.yml"

# 原子验证：作为完整版本号的 OLD 必须全部消失，新版本号已写入
# （验证同样按版本边界/精确上下文匹配，历史引用的更长版本号不视为残留）
#
# Atomic verification: OLD as a full version number must be fully gone and the new one written
# (also matched at version boundaries / exact contexts; longer historical versions are not leftovers)
LEFT="$(grep -lE "(^|[^-0-9A-Za-z.])${ESC}([^-0-9A-Za-z.]|$)" "$DIR"/Dockerfile "$DIR"/README.md "$DIR"/README.zh.md 2>/dev/null || true)"
LEFT_COMPOSE="$(grep -lE "\$\{DSH_VERSION:-${ESC}\}" "$DIR"/docker-compose.yml 2>/dev/null || true)"
[ -z "$LEFT$LEFT_COMPOSE" ] || { echo "错误：旧版本仍残留于 $LEFT $LEFT_COMPOSE" >&2; exit 1; }
grep -q "$NEW" "$DIR/Dockerfile" || { echo "错误：新版本未写入" >&2; exit 1; }

echo "已升级：$OLD → $NEW（Dockerfile / docker-compose.yml / README.md / README.zh.md）"
