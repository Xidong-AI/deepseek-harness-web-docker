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
# 多阶段：builder 阶段编译 dsh（node-pty/sharp 等 native 依赖），
# 运行镜像 COPY 编译产物，并保留轻量编译工具链 + Rust：agent 运行时装 native
# 模块（dsh 插件 node-pty 等）需现场编译兜底；详见运行阶段注释
#
# Multi-stage: the builder stage compiles dsh (native deps such as node-pty/sharp);
# the runtime image copies compiled artifacts AND keeps a lightweight toolchain + Rust,
# so agents can compile native modules (e.g. plugin node-pty) at runtime as a fallback.
# See the runtime stage notes for the trade-off.

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

# build-essential + python3 仅用于本阶段编译 dsh 自带的 native 依赖（node-pty/sharp）；
# 运行镜像另装轻量工具链（make/gcc/g++）供 agent 现场编译插件 native 依赖，见运行阶段
#
# build-essential + python3 are only for compiling dsh's bundled native deps (node-pty/sharp) in this stage;
# the runtime image installs a lightweight toolchain (make/gcc/g++) separately for agents to compile
# plugin native deps on site — see the runtime stage
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
# 动态依赖 libstdc++/libgcc_s/glibc 由 node:22-slim 自带，dsh 核心运行无需工具链；
# 但 agent 运行时装插件（dsh-better-sidebar 等）会触发 node-pty 现场编译
# （prebuild 未匹配时回退 node-gyp），故运行阶段另装 make/gcc/g++（见下）
# bin 用 RUN ln -s 重建：COPY 单文件会解引用 symlink，导致 ESM 从 /usr/local/bin/dsh
# 解析依赖失败（node_modules 不可达）
#
# dsh compiled artifacts: node_modules (with node-pty/sharp native binaries) and the dsh entry.
# Dynamic deps (libstdc++/libgcc_s/glibc) ship with node:22-slim, so dsh core needs no toolchain;
# however, agents installing plugins at runtime (e.g. dsh-better-sidebar) trigger on-site node-pty
# compilation (node-gyp fallback when no prebuild matches), hence make/gcc/g++ in the runtime stage.
# The bin is rebuilt with RUN ln -s: COPY of a single file dereferences the symlink, breaking
# ESM resolution from /usr/local/bin/dsh (node_modules unreachable).
COPY --from=builder /usr/local/lib/node_modules /usr/local/lib/node_modules
RUN ln -s ../lib/node_modules/@deepseek-ai/dsh/lib/bin.js /usr/local/bin/dsh

# 运行依赖与 agent 工具集
# 全部可在白名单 bash 环境直接调用（PATH 固定 /usr/local/sbin:/usr/local/bin:/usr/bin）
# 轻量编译工具链（make/gcc/g++/pkg-config）：agent 运行时装 dsh 插件触发 native 模块
# 现场编译（node-pty prebuild 未匹配时回退 node-gyp），缺 make 会直接报错；不装完整
# build-essential 以控制体积（省 dpkg-dev/gdb 等）
#
# Runtime Dependencies and Agent Toolset
# All directly callable in the whitelisted bash environment (PATH fixed to /usr/local/sbin:/usr/local/bin:/usr/bin).
# Lightweight toolchain (make/gcc/g++/pkg-config): agents installing dsh plugins trigger on-site native
# module compilation (node-gyp fallback when node-pty prebuild doesn't match); a missing make fails hard.
# Full build-essential is avoided to keep the image slim (drops dpkg-dev/gdb etc.).
#
# - supervisor（PID 1 进程管理，Python 包，python3 保留）
# - git/openssh-client：git 工作流（GIT_PAGER=cat 表明 dsh 预期 git 存在）
# - curl/wget：网络下载；jq：JSON；unzip/zip：解压/压缩；tar（coreutils）
# - procps(ps/kill/pgrep)：进程排查；ripgrep：代码搜索；rsync：同步
# - yq：YAML 处理；file：类型识别；dnsutils(dig)：DNS 排查；sqlite3：数据
# - python3-pip：python 包管理（pip install --user）；vim-tiny：vi 编辑器兜底
# - make/gcc/g++/pkg-config：node-gyp 编译 native 模块（node-pty 等）兜底
#
# 有意不 pin apt 版本：依赖 Debian 源自动更新；npm 版本已由 ARG DSH_VERSION pin
#
# Apt versions are deliberately unpinned: Debian sources auto-update; npm is pinned by ARG DSH_VERSION
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends supervisor ca-certificates git openssh-client curl wget jq unzip zip procps ripgrep rsync yq file dnsutils sqlite3 python3-pip vim-tiny python3 make gcc g++ pkg-config \
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

# Rust 工具链（rustup 官方方式，minimal profile + rustfmt/clippy）
# agent 运行时可直接 cargo build/rustc 编译项目；profile minimal 不含 rust-docs 以控制体积
# RUSTUP_HOME/CARGO_HOME 指向系统目录并 chown 给 node：agent 无 root 也能 rustup component add
# agent 的 bash PATH 白名单固定（/usr/local/sbin:/usr/local/bin:/usr/bin），故把 cargo/bin 下
# 可执行文件软链到 /usr/local/bin（与 x-cmd shim 同一接入点策略）
# RUSTUP_DIST_SERVER 可经 build-arg 覆盖（国内构建若 static.rust-lang.org 不可达可设 rsproxy.cn）
#
# Rust toolchain (official rustup, minimal profile + rustfmt/clippy)
# Agents can cargo build/rustc directly at runtime; minimal profile omits rust-docs to save space.
# RUSTUP_HOME/CARGO_HOME point to system dirs and are chowned to node, so non-root agents can
# `rustup component add` too. The agent's bash PATH is a fixed whitelist
# (/usr/local/sbin:/usr/local/bin:/usr/bin), so cargo/bin executables are symlinked into
# /usr/local/bin (same entry-point strategy as the x-cmd shims).
# RUSTUP_DIST_SERVER can be overridden via build-arg (set to rsproxy.cn if static.rust-lang.org
# is unreachable in your build environment).
ENV RUSTUP_HOME=/usr/local/rustup \
    CARGO_HOME=/usr/local/cargo
ARG RUSTUP_DIST_SERVER=https://static.rust-lang.org
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
      | sh -s -- -y --profile minimal --default-toolchain stable --no-modify-path \
                 --component rustfmt --component clippy \
 && find /usr/local/cargo/bin -maxdepth 1 -type f -executable \
      -exec ln -sf {} /usr/local/bin/ \; \
 && chown -R node:node /usr/local/rustup /usr/local/cargo \
 && rm -rf /usr/local/rustup/tmp/* /usr/local/cargo/registry/cache

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
