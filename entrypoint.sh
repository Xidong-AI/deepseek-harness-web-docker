#!/usr/bin/env bash
# 容器入口脚本
# dsh-web 容器入口：校验必需变量 → 生成 bcrypt → 首启初始化数据卷 → 启动 supervisord
#
# Container Entrypoint Script
# dsh-web container entrypoint: validate required env vars → generate bcrypt → initialize the data volume on first run → start supervisord
set -euo pipefail

log() { echo "[entrypoint] $*"; }

# ---- 必需变量校验 ----
#
# ---- Required variable validation ----
: "${DSH_AUTH_USER:?必须设置 DSH_AUTH_USER（.env）}"
: "${DSH_AUTH_PASSWORD:?必须设置 DSH_AUTH_PASSWORD（.env）}"
: "${DEEPSEEK_API_KEY:?必须设置 DEEPSEEK_API_KEY（.env）}"

# ---- basic auth：明文密码 → bcrypt 哈希（注入 Caddyfile 环境变量）----
#
# ---- Basic auth: plaintext password → bcrypt hash (injected into Caddyfile env vars) ----
DSH_AUTH_HASH="$(caddy hash-password --plaintext "$DSH_AUTH_PASSWORD" | tail -n 1)"
export DSH_AUTH_HASH

# ---- 数据卷首启初始化（/home/node/.dsh，node 用户为 uid 1000）----
#
# ---- Data volume first-run initialization (/home/node/.dsh, node user with uid 1000) ----
DHS_HOME=/home/node/.dsh
mkdir -p "$DHS_HOME"

# 1. settings.yaml：不存在时复制默认模板（之后由用户持久化维护）
#
# 1. settings.yaml: copy the default template when absent (later maintained by the user)
if [ ! -f "$DHS_HOME/settings.yaml" ]; then
  cp /opt/dsh/defaults/settings.yaml "$DHS_HOME/settings.yaml"
  log "已初始化默认 settings.yaml"
fi

# 1b. AGENTS.md：容器环境指引（dsh 会话自动加载，agent 必读）
#
# 1b. AGENTS.md: container environment guide (auto-loaded by dsh sessions, mandatory for agents)
if [ ! -f "$DHS_HOME/AGENTS.md" ]; then
  cp /opt/dsh/defaults/AGENTS.md "$DHS_HOME/AGENTS.md"
  log "已初始化 AGENTS.md（容器环境指引）"
fi

# 2. trustedHosts 注入 cordis.patch.yml（仅当文件不存在；已存在则视为用户维护）
#    profile 其余文件（package.json/pnpm-workspace.yaml）由 dsh 首启自动补全
#
# 2. Inject trustedHosts into cordis.patch.yml (only when absent; existing files are treated as user-maintained)
#    The rest of the profile (package.json/pnpm-workspace.yaml) is auto-completed by dsh on first run
if [ -n "${DSH_TRUSTED_HOSTS:-}" ]; then
  PROFILE_DIR="$DHS_HOME/profiles/web"
  PATCH="$PROFILE_DIR/cordis.patch.yml"
  if [ ! -f "$PATCH" ]; then
    mkdir -p "$PROFILE_DIR"
    {
      echo "- id: connection"
      echo "  config:"
      echo "    trustedHosts:"
      # shellcheck disable=SC2086 # 有意按空白分词（逗号分隔列表）
      for host in ${DSH_TRUSTED_HOSTS//,/ }; do
        echo "      - $host"
      done
    } > "$PATCH"
    log "已注入 trustedHosts: $DSH_TRUSTED_HOSTS"
  else
    log "cordis.patch.yml 已存在，跳过 trustedHosts 注入（用户维护）"
  fi
fi

# 3. 修正数据卷属主（bind mount 挂整个 /home/node，首启属主可能是 root）
#
# 3. Fix data volume ownership (the whole /home/node is bind-mounted; owner may be root on first run)
chown -R node:node /home/node
# ---- x-cmd：agent 自行配置运行环境的工具（幂等安装 + 系统 PATH 接入）----
# agent 的 bash 工具环境是白名单（PATH 固定为 /usr/local/sbin:/usr/local/bin:/usr/bin，无 HOME），
# 因此：1) 生成 HOME 注入的 x wrapper；2) 把已 use 包的 shim 软链进 /usr/local/bin。
# agent 用法见数据卷 AGENTS.md：`x env use <pkg>` 安装，`x <pkg>` 前缀调用（始终可用），
# 裸命令对本次启动前已 use 的包可用（重启容器后对新装包生效）。
#
# ---- x-cmd: tools agents install to configure their runtime (idempotent install + system PATH integration) ----
# The agent's bash tool environment is a whitelist (PATH fixed to /usr/local/sbin:/usr/local/bin:/usr/bin, no HOME),
# hence: 1) generate an x wrapper that injects HOME; 2) symlink shims of already-used packages into /usr/local/bin.
# Agent usage is documented in the data-volume AGENTS.md: install with `x env use <pkg>`, invoke with the `x <pkg>` prefix (always available),
# Bare commands work for packages used before this startup (newly installed packages take effect after a container restart).
XCMD_HOME=/home/node/.x-cmd.root
if [ ! -x "$XCMD_HOME/bin/x" ]; then
  log "首次启动：安装 x-cmd（agent 环境自举，约 80MB，写入数据卷；阿里云 OSS 源）"
  if timeout 300 su -s /bin/bash node -c 'HOME=/home/node curl -fsSL https://get.x-cmd.com | sh' >/dev/null 2>&1; then
    log "x-cmd 安装完成"
  else
    log "警告：x-cmd 安装失败（网络或 su 受限？），dsh 照常启动；"
    log "       可稍后手动安装：docker exec -it dsh-web su -s /bin/bash node -c 'curl -fsSL https://get.x-cmd.com | sh'"
  fi
fi
if [ -x "$XCMD_HOME/bin/x" ]; then
  # 1) x wrapper：agent bash 无 HOME，x 需要 HOME 定位安装根
  #
  # 1) x wrapper: the agent bash has no HOME; x needs HOME to locate its install root
  cat > /usr/local/bin/x <<EOF
#!/bin/bash
export HOME=/home/node
exec /home/node/.x-cmd.root/bin/x "$@"
EOF
  chmod 755 /usr/local/bin/x
  # 2) 已 use 包 shim 快照软链 → /usr/local/bin（裸命令直接可用）
  #    exec/<pkg> 文件内容为 shim_bin 路径；shim_bin/<pkg> 是 `#! /bin/sh + exec 真实 bin` 包装
  #
  # 2) Symlink the shim snapshot of used packages → /usr/local/bin (bare commands become directly usable)
  #    exec/<pkg> contains the shim_bin path; shim_bin/<pkg> is a `#! /bin/sh + exec real bin` wrapper
  for shim in "$XCMD_HOME/local/data/pkg/exec"/*; do
    [ -f "$shim" ] || continue
    pkg="$(basename "$shim")"
    target="$(head -n 1 "$shim" 2>/dev/null)" || continue
    if [ -n "$target" ] && [ -e "$target" ]; then
      ln -sf "$target" "/usr/local/bin/$pkg"
    fi
  done
  pkg_list="$("$XCMD_HOME/bin/x" env ls 2>/dev/null | awk '{print $1}' | tr '\n' ' ')"
  log "x-cmd 就绪（已启用包：$pkg_list）"
fi

# ---- 启动 supervisord（dsh + caddy）----
#
# ---- Start supervisord (dsh + caddy) ----
log "启动 supervisord（DSH_AUTH_USER=$DSH_AUTH_USER，对外端口由 compose 映射）"
exec supervisord -c /etc/supervisor/conf.d/dsh.conf
