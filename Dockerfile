# syntax=docker/dockerfile:1
# DeepSeek Harness Web Docker 镜像
#
# DeepSeek Harness Web Docker image
#
# 单容器：dsh(127.0.0.1:3080) + Caddy basic auth(0.0.0.0:3081)，supervisord 管理
#
# Single container: dsh (127.0.0.1:3080) + Caddy basic auth (0.0.0.0:3081), managed by supervisord
#
# 构建：docker build --build-arg DSH_VERSION=0.1.0-rc.7 -t dsh-web:latest .
#
# Build: docker build --build-arg DSH_VERSION=0.1.0-rc.7 -t dsh-web:latest .
#
# 多阶段：builder 阶段含编译工具链（node-pty/sharp 等 native 依赖），
# 运行镜像只 COPY 编译产物，不含 gcc/make/python-dev 痕迹
#
# Multi-stage: the builder stage holds the toolchain for native deps (node-pty/sharp);
# the runtime image only copies compiled artifacts, with no gcc/make/python-dev remnants

ARG DSH_VERSION=0.1.0-rc.7

# Caddy 官方镜像
# 静态二进制，与平台无关
#
# Caddy Official Image
# Static binary, platform-independent
FROM caddy:2-alpine AS caddy

# ---- builder 阶段：编译 dsh（node-pty / sharp 等 native 依赖）----
#
# ---- builder stage: compile dsh (native deps such as node-pty / sharp) ----
FROM node:22-slim AS builder

ARG DSH_VERSION

ENV DEBIAN_FRONTEND=noninteractive

# build-essential + python3 仅用于 npm 编译，本阶段镜像不产出到运行镜像
#
# build-essential + python3 are only for npm compilation; this stage's image never reaches the runtime
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends build-essential python3 \
 && npm install -g @deepseek-ai/dsh@${DSH_VERSION} \
 && npm cache clean --force \
 && rm -rf /var/lib/apt/lists/* /root/.npm /root/.cache

# ---- 运行阶段 ----
#
# ---- runtime stage ----
FROM node:22-slim

ENV DEBIAN_FRONTEND=noninteractive

# Caddy 静态二进制
# 来自官方镜像，可在 glibc Debian 上直接运行
#
# Caddy Static Binary
# From the official image, runs directly on glibc Debian
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy

# dsh 编译产物：node_modules（含 node-pty/sharp native 二进制）与 dsh 入口
# 动态依赖 libstdc++/libgcc_s/glibc 由 node:22-slim 自带，运行无需编译工具链
# bin 用 RUN ln -s 重建：COPY 单文件会解引用 symlink，导致 ESM 从 /usr/local/bin/dsh
# 解析依赖失败（node_modules 不可达）
#
# dsh compiled artifacts: node_modules (with node-pty/sharp native binaries) and the dsh entry
# Dynamic deps (libstdc++/libgcc_s/glibc) ship with node:22-slim; no toolchain is needed at runtime
# The bin is rebuilt with RUN ln -s: COPY of a single file dereferences the symlink, breaking
# ESM resolution from /usr/local/bin/dsh (node_modules unreachable)
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh

# 运行依赖与 agent 工具集
# 全部可在白名单 bash 环境直接调用；无 build-essential（编译只在 builder 阶段）
#
# Runtime Dependencies and Agent Toolset
# All directly callable in the whitelisted bash environment; no build-essential (compilation stays in the builder stage)
#
# - supervisor（PID 1 进程管理，Python 包，python3 保留）
# - git/openssh-client：git 工作流（GIT_PAGER=cat 表明 dsh 预期 git 存在）
# - curl/wget：网络下载；jq：JSON；unzip/zip：解压/压缩；tar（coreutils）
# - procps(ps/kill/pgrep)：进程排查；ripgrep：代码搜索；rsync：同步
# - yq：YAML 处理；file：类型识别；dnsutils(dig)：DNS 排查；sqlite3：数据
# - python3-pip：python 包管理（pip install --user）；vim-tiny：vi 编辑器兜底
#
# 有意不 pin apt 版本：依赖 Debian 源自动更新；npm 版本已由 ARG DSH_VERSION pin
#
# Apt versions are deliberately unpinned: Debian sources auto-update; npm is pinned by ARG DSH_VERSION
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends supervisor ca-certificates git openssh-client curl wget jq unzip zip procps ripgrep rsync yq file dnsutils sqlite3 python3-pip vim-tiny python3 \
 && rm -rf /var/lib/apt/lists/*

# pnpm
# dsh plugin 命令在 profile 目录内转发给 pnpm（corepack 官方方式，pin 大版本）
# COREPACK_HOME 指向系统目录：缓存不落在 /root，运行阶段可读且镜像不留 root 缓存
#
# pnpm
# dsh plugin commands forward to pnpm inside the profile dir (official corepack way, major version pinned)
# COREPACK_HOME points to a system dir so the cache never lands in /root (readable at runtime, no root cache in the image)
ENV COREPACK_HOME=/usr/local/share/corepack
RUN corepack enable \
 && corepack prepare pnpm@10 --activate \
 && rm -rf /root/.cache

# 运行用户与数据目录
# 非 root 运行用户：复用官方镜像自带的 node 用户（uid 1000，home /home/node）
# 数据目录 /home/node/.dsh 挂载卷；uid 1000 便于宿主机 bind mount 属主对齐
#
# Runtime User and Data Directory
# Non-root runtime user: reuse the node user from the official image (uid 1000, home /home/node)
# Data dir /home/node/.dsh is a mounted volume; uid 1000 aligns ownership for host bind mounts

# 配置与入口
#
# Configuration and Entrypoint
COPY defaults/ /opt/dsh/defaults/
COPY Caddyfile /etc/caddy/Caddyfile
COPY supervisord.conf /etc/supervisor/conf.d/dsh.conf
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
# 构建收尾说明
# Caddyfile 需 node 用户可读（COPY 保留源 600 权限）
# vim-tiny 默认不注册 vim 命令名，补 alternatives 注册（vi 已自动可用）
#
# Build Finalization Notes
# Caddyfile must be readable by the node user (COPY keeps the source 600 permission)
# vim-tiny does not register the vim command by default; alternatives registration added (vi already available)
RUN chmod 644 /etc/caddy/Caddyfile \
 && chmod +x /usr/local/bin/entrypoint.sh \
 && update-alternatives --install /usr/bin/vim vim /usr/bin/vim.tiny 10

ENV HOME=/home/node
EXPOSE 3081

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
