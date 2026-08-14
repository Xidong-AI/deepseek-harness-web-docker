# syntax=docker/dockerfile:1
# DeepSeek Harness Web Docker 镜像
#
# DeepSeek Harness Web Docker image
#
# 单容器：dsh(127.0.0.1:3080) + Caddy basic auth(0.0.0.0:3081)，supervisord 管理
#
# Single container: dsh (127.0.0.1:3080) + Caddy basic auth (0.0.0.0:3081), managed by supervisord
#
# 构建：docker build --build-arg DSH_VERSION=0.1.0-rc.6 -t dsh-web:latest .
#
# Build: docker build --build-arg DSH_VERSION=0.1.0-rc.6 -t dsh-web:latest .

ARG DSH_VERSION=0.1.0-rc.6

# Caddy 官方镜像
# 静态二进制，与平台无关
#
# Caddy Official Image
# Static binary, platform-independent
FROM caddy:2-alpine AS caddy

FROM node:22-slim

ARG DSH_VERSION

ENV DEBIAN_FRONTEND=noninteractive

# Caddy 静态二进制
# 来自官方镜像，可在 glibc Debian 上直接运行
#
# Caddy Static Binary
# From the official image, runs directly on glibc Debian
COPY --from=caddy /usr/bin/caddy /usr/bin/caddy

# 运行依赖与 agent 工具集
# 全部可在白名单 bash 环境直接调用
#
# Runtime Dependencies and Agent Toolset
# All directly callable in the whitelisted bash environment
#
# - supervisor（PID 1 进程管理，Python 包，python3 保留）
# - git/openssh-client：git 工作流（GIT_PAGER=cat 表明 dsh 预期 git 存在）
# - curl/wget：网络下载；jq：JSON；unzip/zip：解压/压缩；tar（coreutils）
# - procps(ps/kill/pgrep)：进程排查；ripgrep：代码搜索；rsync：同步
# - yq：YAML 处理；file：类型识别；dnsutils(dig)：DNS 排查；sqlite3：数据
# - python3-pip：python 包管理（pip install --user）；vim-tiny：vi 编辑器兜底
# - build-essential/python3：npm 编译 native 依赖（node-pty 等），装完即清理
#
# - supervisor (PID 1 process management, Python package, python3 kept)
# - git/openssh-client: git workflows (GIT_PAGER=cat shows dsh expects git)
# - curl/wget: downloads; jq: JSON; unzip/zip: archive; tar (coreutils)
# - procps (ps/kill/pgrep): process inspection; ripgrep: code search; rsync: sync
# - yq: YAML; file: type detection; dnsutils (dig): DNS; sqlite3: data
# - python3-pip: Python packages (pip install --user); vim-tiny: fallback vi editor
# - build-essential/python3: compile native npm deps (node-pty etc.), purged after install
#
# 有意不 pin apt 版本：依赖 Debian 源自动更新；npm 版本已由 ARG DSH_VERSION pin
#
# Apt versions are deliberately unpinned: Debian sources auto-update; npm is pinned by ARG DSH_VERSION
# hadolint ignore=DL3008
RUN apt-get update \
 && apt-get install -y --no-install-recommends supervisor ca-certificates git openssh-client curl wget jq unzip zip procps ripgrep rsync yq file dnsutils sqlite3 python3-pip vim-tiny build-essential python3 \
 && rm -rf /var/lib/apt/lists/*

# pnpm
# dsh plugin 命令在 profile 目录内转发给 pnpm（corepack 官方方式，pin 大版本）
#
# pnpm
# dsh plugin commands forward to pnpm inside the profile dir (official corepack way, major version pinned)
RUN corepack enable \
 && corepack prepare pnpm@10 --activate

# dsh 全局安装
# 版本由 DSH_VERSION 构建参数固定
# simp: 不硬编码 npm 镜像，用户可在构建时经 npm_config_registry 指定
#
# Global dsh Install
# Version pinned by the DSH_VERSION build argument
# simp: no hardcoded npm mirror; users can set npm_config_registry at build time
RUN npm install -g @deepseek-ai/dsh@${DSH_VERSION} \
 && npm cache clean --force \
 && apt-get purge -y --auto-remove build-essential \
 && rm -rf /var/lib/apt/lists/* /root/.npm

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
