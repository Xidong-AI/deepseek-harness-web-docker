#!/usr/bin/env bash
# 冒烟测试：构建镜像 → 校验 dsh 版本 → 起容器 → basic auth 与进程检查
#
# Smoke test: build image → verify dsh version → run container → basic auth & process checks
# Usage: smoke-test.sh <version>
set -euo pipefail

VERSION="$1"
IMAGE="dsh-web:smoke"
CID="dsh-smoke"

cleanup() {
  # cleanup 失败不应掩盖主命令的退出码：bash EXIT trap 的函数返回值就是进程的最终
  # exit code（覆盖 `exit N` 的 N）。trap 启动时 $? = 触发 trap 的命令退出码，
  # 函数第一行捕获它，cleanup 内部失败用 warn 兜底，最后 return 这个 rc 把它冒出去
  #
  # Cleanup failures must not mask the main command's exit code: bash EXIT trap's
  # function return value becomes the process's final exit code (overriding `exit N`).
  # The trap fires with $? = the triggering command's exit code; we capture it on the
  # first line, swallow internal cleanup failures into a warn, and `return` it so it
  # propagates to Actions as the real failure rather than a silent success
  local rc=$?
  # cookie 文件：0.1.2-rc.1+ 鉴权流程创建的临时 cookie，与 SMOKE_HOME 一起删即可
  # (cookie jar 在 SMOKE_PARENT 下，独立 mktemp 但跟着 SMOKE_HOME 的 rm -rf 也走
  # 因为 mktemp -p 选了 SMOKE_PARENT；不过保险起见显式删一次)
  [ -n "${SMOKE_COOKIE:-}" ] && [ -f "$SMOKE_COOKIE" ] && rm -f "$SMOKE_COOKIE" 2>/dev/null || true
  docker rm -f "$CID" >/dev/null 2>&1 || true
  if [ -n "${SMOKE_HOME:-}" ] && [ -d "$SMOKE_HOME" ]; then
    # 先放宽权限再递归删：容器内 uid 1000 (node) 写下的子文件可能只对本人可写，
    # runner (uid 1001) 在 sticky /tmp 下无法删；但若 SMOKE_PARENT 已经是 runner 自己的
    # 非 sticky 目录，权限放宽足以应对权限位差异
    #
    # Loosen perms first then recurse: container-internal uid 1000 (node) may have left
    # files only writable by themselves; on a sticky /tmp a uid-1001 runner can't drop
    # those. If SMOKE_PARENT is already a non-sticky runner-owned dir, chmod is enough.
    chmod -R u+w "$SMOKE_HOME" 2>/dev/null || true
    rm -rf "$SMOKE_HOME" 2>/dev/null || warn "无法清理 SMOKE_HOME=$SMOKE_HOME（容器子文件权限/sticky 导致），手动 rm 即可"
  fi
  return "$rc"  # 关键：把主命令退出码冒出去
                 # Critical: propagate the main command's exit code
}
warn() { printf 'WARN: %s\n' "$*" >&2; }
trap cleanup EXIT
cleanup

echo "==> 构建镜像（DSH_VERSION=$VERSION）"
docker build --build-arg DSH_VERSION="$VERSION" -t "$IMAGE" .

echo "==> 校验 dsh --version"
OUT="$(docker run --rm --entrypoint dsh "$IMAGE" --version)"
echo "    dsh --version => $OUT"
grep -q "$VERSION" <<<"$OUT" || { echo "错误：版本不符（期望包含 $VERSION）" >&2; exit 1; }

echo "==> 启动容器冒烟"
# 预置假 x-cmd（x 可执行即跳过 entrypoint 首启 300s 下载）
#
# Pre-seed a fake x-cmd (an executable x skips the entrypoint's 300s first-run download)
#
# SMOKE_PARENT 选择：必须是非 sticky 目录。容器内 dsh/caddy 以 uid 1000 (node) 写入
# bind mount 的子文件，runner 是 uid 1001；sticky /tmp + 跨 uid → cleanup 时 EPERM。
# 优先用 GitHub Actions 提供的 RUNNER_TEMP（runner 独占，非 sticky），否则用
# 系统 TMPDIR（部分发行版已重定向到 /run/user/<uid>），否则回退 $HOME
# （Linux home 不 sticky，macOS 也只有 /tmp 有 sticky）。$HOME 兜底保留本地跑的可用性
#
# SMOKE_PARENT must be non-sticky: container dsh/caddy runs as uid 1000 (node) and
# writes into the bind-mount, while the runner is uid 1001; sticky /tmp + cross-uid
# triggers EPERM on cleanup. Prefer RUNNER_TEMP (runner-exclusive, non-sticky), then
# TMPDIR (some distros point it at /run/user/<uid>), then $HOME (Linux home is not
# sticky; macOS only has sticky on /tmp). $HOME fallback keeps local runs working.
SMOKE_PARENT="${RUNNER_TEMP:-${TMPDIR:-$HOME}}"
mkdir -p "$SMOKE_PARENT"
SMOKE_HOME="$(mktemp -d -p "$SMOKE_PARENT" smoke-XXXXXX)"
# mktemp 默认 0700。容器首启会把 bind mount 根 chown 成 node(uid 1000)，但权限位不变：
# runner（GitHub Actions 上是 uid 1001）便无法 traverse，即使 web-launch-url.txt 已生成
# 也读不到（表现为 60s 超时 + `tail: Permission denied`）。放宽目录到 755 让 runner 能进入，
# 文件本身仍是 0644（只读）。本地跑时 runner uid 恰好也是 1000，不触发，故 CI 才暴露。
#
# mktemp defaults to 0700. The container's first-run chowns the bind-mount root to
# node (uid 1000) without changing mode bits, so the runner (uid 1001 on GitHub Actions)
# cannot traverse it and cannot read web-launch-url.txt even once it exists (symptom:
# 60 s timeout + `tail: Permission denied`). Loosen the directory to 755 so the runner
# can enter; files stay 0644 (read-only). Local runs use uid 1000, so only CI exposes this.
chmod 755 "$SMOKE_HOME"
mkdir -p "$SMOKE_HOME/.x-cmd.root/bin"
printf '#!/bin/sh\nexit 0\n' > "$SMOKE_HOME/.x-cmd.root/bin/x"
docker run -d --name "$CID" \
  -v "$SMOKE_HOME:/home/node" \
  -e DSH_AUTH_USER=admin -e DSH_AUTH_PASSWORD=smoketest \
  -e DEEPSEEK_API_KEY=sk-dummy \
  -e DSH_TRUSTED_HOSTS=smoke.example.com \
  -p 127.0.0.1::3081 "$IMAGE" >/dev/null
PORT="$(docker port "$CID" 3081 | head -n1 | sed 's/.*://')"
echo "    容器 $CID 已启动，映射端口 $PORT"

echo "==> 等待服务就绪（最多 240s）"
# 等三件事之一：1) 200（≤0.1.1-rc.2 旧 caddy basic auth 通过）2) 401（0.1.2-rc.1+ 路径，
# caddy 活，dsh 鉴权拒绝无 token）3) entrypoint 后台抓到的 web-launch-url.txt 出现
# （dsh 启动后 5-30 秒内）。任一即就绪。502/000 继续等
#
# Wait for any of: 1) 200 (≤0.1.1-rc.2 old caddy basic-auth) 2) 401 (0.1.2-rc.1+,
# caddy alive, dsh rejects no-token) 3) web-launch-url.txt written (5-30 s after dsh).
# Any one means "ready". 502/000 keep waiting.
READY=0
LAST_CODE=000
URL_FILE="$SMOKE_HOME/.dsh/web-launch-url.txt"
START_TS="$(date +%s)"
for _ in $(seq 1 120); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
  LAST_CODE="$CODE"
  if [ "$CODE" = "200" ] || [ "$CODE" = "401" ] || [ -s "$URL_FILE" ]; then
    READY=1; break
  fi
  sleep 2
done
if [ "$READY" != 1 ]; then
  ELAPSED=$(( $(date +%s) - START_TS ))
  echo "错误：服务 ${ELAPSED}s 内 Caddy 仍未监听（最后一次 HTTP code=$LAST_CODE，token 文件未出现）" >&2
  echo "  （502/000 = 仍在启动；持续 502 = 上游启动慢/挂）" >&2
  docker logs "$CID" 2>&1 | tail -30 >&2
  exit 1
fi

# 版本分叉：检测 dsh 版本决定鉴权流程
# dsh <0.1.2-rc.1 (e.g. 0.1.1-rc.2)：用 caddy basic auth（DSH_AUTH_USER/PASSWORD）
# dsh >=0.1.2-rc.1：用 token+cookie（dsh 0.1.2-rc.1 引入的一次性 token + 持久 cookie，
#   caddy 0.1.2-rc.1+ 不再 basic auth，DSH_AUTH_USER/PASSWORD 保留为兼容位但 caddy 不用）
#
# Version fork: pick the auth flow by dsh version
# dsh <0.1.2-rc.1 (e.g. 0.1.1-rc.2): caddy basic auth
# dsh >=0.1.2-rc.1: token + cookie (dsh 0.1.2-rc.1 one-time token + persistent cookie;
#   caddy 0.1.2-rc.1+ no longer basic-auths, DSH_AUTH_USER/PASSWORD are kept for compat)
case "$VERSION" in
  0.1.0-*|0.1.1-*)
    # 旧版鉴权：basic auth（dsh ≤0.1.1-rc.2）
    echo "==> 旧版鉴权：basic auth（dsh $VERSION）"
    echo "==> basic auth：无凭据应 401"
    CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
    [ "$CODE" = "401" ] || { echo "错误：期望 401 实际 $CODE" >&2; exit 1; }

    echo "==> basic auth：带凭据应 200"
    CODE="$(curl -s -u admin:smoketest -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
    [ "$CODE" = "200" ] || {
      echo "错误：带 admin:smoketest 凭据应返 200，实际 $CODE" >&2
      docker logs "$CID" 2>&1 | tail -30 >&2
      exit 1
    }
    # basic auth 路径：API fence 步骤用 basic auth
    AUTH_FLAGS=(-u admin:smoketest)
    ;;
  *)
    # 新版鉴权：token + cookie（dsh ≥0.1.2-rc.1）
    echo "==> 新版鉴权：token + cookie（dsh $VERSION）"
    # 等 token URL 文件（entrypoint 后台任务写入，dsh 启动后 1-30 秒内出现）
    # Wait for token URL file (entrypoint's background task writes it 1-30 s after dsh starts)
    for _ in $(seq 1 60); do
      [ -s "$URL_FILE" ] && break
      sleep 1
    done
    if [ ! -s "$URL_FILE" ]; then
      echo "错误：dsh 启动后 60s 内未在 $URL_FILE 捕获到 ?token= URL" >&2
      echo "--- 容器 web-server.log 后 30 行（dsh 启动日志 tee）---" >&2
      tail -30 "$SMOKE_HOME/.dsh/web-server.log" >&2 || true
      docker logs "$CID" 2>&1 | tail -30 >&2
      exit 1
    fi
    LAUNCH_URL="$(cat "$URL_FILE")"
    echo "    抓取到 dsh 启动 URL: $LAUNCH_URL"
    # URL_FILE 记录的是容器内 loopback 地址（dsh 强制 loopback bind），宿主机不能直连：
    # 必须把主机：端口改写到映射端口 $PORT，才能经 Caddy 走真实浏览器路径；token 原样保留。
    #
    # URL_FILE holds the container-internal loopback address (dsh hard-binds loopback);
    # the host cannot reach it directly. Rewrite host:port to the mapped port $PORT so the
    # request goes through Caddy like a real browser; keep the token value as-is.
    TOKEN="$(printf '%s' "$LAUNCH_URL" | sed -n 's#.*[?&]token=\([^&]*\).*#\1#p')"
    [ -n "$TOKEN" ] || { echo "错误：无法从 $LAUNCH_URL 解析 token" >&2; exit 1; }
    LAUNCH_URL="http://127.0.0.1:${PORT}/?token=${TOKEN}"
    # 一次性 token 换持久 cookie：GET ?token=XXX → 303 + Set-Cookie
    # Exchange one-time token for persistent cookie: GET ?token=XXX → 303 + Set-Cookie
    SMOKE_COOKIE="$(mktemp -p "$SMOKE_PARENT" smoke-cookie-XXXXXX)"
    CODE="$(curl -sS -c "$SMOKE_COOKIE" -o /dev/null -w '%{http_code}' "$LAUNCH_URL" || true)"
    if [ "$CODE" != "303" ]; then
      echo "错误：带 token 访问应返 303 重定向，实际 $CODE" >&2
      cat "$SMOKE_COOKIE" >&2 || true
      docker logs "$CID" 2>&1 | tail -20 >&2
      exit 1
    fi
    if ! grep -q "dsh" "$SMOKE_COOKIE" 2>/dev/null; then
      echo "错误：token 交换后未拿到 Set-Cookie（dsh 应发 HttpOnly cookie）" >&2
      cat "$SMOKE_COOKIE" >&2 || true
      exit 1
    fi
    # cookie 同时要供宿主机 curl 与容器内 docker exec curl 使用，而 cookie 文件是宿主
    # 路径、容器内不存在；统一抽成 Cookie header 字符串，两边都可用（HttpOnly cookie
    # 在 curl 的 cookie jar 里以 #HttpOnly_ 前缀记录，解析时需一并纳入）。
    #
    # The cookie must work for both the host curl and the in-container `docker exec curl`,
    # but the cookie jar is a host path that doesn't exist inside the container. Extract a
    # Cookie header string usable on both sides (HttpOnly cookies are stored with a
    # #HttpOnly_ prefix in curl's jar, so include them when parsing).
    COOKIE_HEADER="Cookie: $(awk 'NF && ($1 ~ /^#HttpOnly_/ || $0 !~ /^#/) {print $6"="$7}' "$SMOKE_COOKIE" | paste -sd'; ' -)"
    echo "==> 鉴权：带 cookie 应 200"
    CODE="$(curl -sS -H "$COOKIE_HEADER" -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
    if [ "$CODE" != "200" ]; then
      echo "错误：带 cookie 应返 200，实际 $CODE" >&2
      echo "--- 诊断：直连容器内 dsh 3080（带 cookie）---" >&2
      docker exec "$CID" curl -sS -H "$COOKIE_HEADER" -o /dev/null -w '  HTTP %{http_code}\n' "http://127.0.0.1:3080/" >&2 || true
      docker logs "$CID" 2>&1 | tail -20 | sed 's/^/    /' >&2
      exit 1
    fi
    echo "    鉴权通过（cookie 持久化到 $SMOKE_HOME/.dsh/.credentials.yaml）"
    # 新版路径：API fence 步骤用 cookie（header 字符串，host/容器通用）
    #
    # New auth path: the fence step uses the cookie (a header string, valid on host and in-container)
    AUTH_FLAGS=(-H "$COOKIE_HEADER")
    ;;
esac

echo "==> 特权 API fence：伪造 Host 直连容器内 dsh 应 403（fence 拒绝未授权来源）"
# 不经 Caddy 直连 127.0.0.1:3080，伪造浏览器 Host=evil.com——dsh 视其为非本机来源。
# 此处用容器内 curl（不经 caddy，caddy 不参与；用 cookie/basic auth 都无法过 dsh 的
# Host 来源检查——fence 拒绝非 loopback Host；仅 0.1.2-rc.1+ 需 cookie，0.1.1-rc.2 用 basic auth）
#
# Bypass Caddy: curl dsh 3080 directly from inside the container. dsh's fence rejects
# non-loopback Host. Auth flavor: 0.1.1-rc.2 uses basic auth, 0.1.2-rc.1+ uses cookie.
# Either way, the fake Host=evil.com is what we test, not auth.
CODE="$(docker exec "$CID" curl -s "${AUTH_FLAGS[@]}" -o /dev/null -w '%{http_code}' -X POST \
  -H 'Host: evil.com' -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:3080/api")"
[ "$CODE" = "403" ] || { echo "错误：fence 未拒绝伪造 Host（期望 403 实际 $CODE）" >&2; exit 1; }

echo "==> 特权 API fence：经 Caddy 伪造 Host/Origin 应被改写为 loopback（非 403）"
# 浏览器形态请求经 Caddy：Host/Origin 被改写为 127.0.0.1:3080，fence 通过；
# 若 Caddyfile 的 header_up 两行失效，此处将返回 403——即改写链路回归
CODE="$(curl -s "${AUTH_FLAGS[@]}" -o /dev/null -w '%{http_code}' -X POST \
  -H 'Host: evil.com' -H 'Origin: http://127.0.0.1:3080' \
  -H 'Content-Type: application/json' -d '{}' "http://127.0.0.1:$PORT/api")"
[ "$CODE" = "400" ] || [ "$CODE" = "404" ] || { echo "错误：期望改写生效（400/404，fence 通过后坏 payload 的正常响应）实际 $CODE" >&2; exit 1; }

echo "==> 进程检查：等待 dsh 与 caddy 均 RUNNING"
# dsh 首启初始化（profile/bundles）慢于 Caddy，需轮询等待其越过 startsecs
#
# dsh's first-run init (profile/bundles) is slower than Caddy; poll until it passes startsecs
READY=0
for _ in $(seq 1 30); do
  STATUS="$(docker exec "$CID" supervisorctl status 2>/dev/null || true)"
  if grep -qE '^dsh[[:space:]]+RUNNING' <<<"$STATUS" && grep -qE '^caddy[[:space:]]+RUNNING' <<<"$STATUS"; then
    READY=1; break
  fi
  sleep 2
done
if [ "$READY" != 1 ]; then
  printf '错误：进程未全部 RUNNING\n%s\n' "$STATUS" >&2
  docker logs "$CID" 2>&1 | tail -30 >&2
  exit 1
fi

echo "==> trustedHosts 注入检查"
# DSH_TRUSTED_HOSTS 在启动时注入 cordis.patch.yml（entrypoint 在 dsh 首启前预写，
# dsh 的 initProfile 对已存在文件不覆盖）；此处验证注入结果
docker exec "$CID" sh -c 'grep -q "smoke.example.com" /home/node/.dsh/profiles/web/cordis.patch.yml' \
  || { echo "错误：trustedHosts 未注入 cordis.patch.yml" >&2; exit 1; }
docker exec "$CID" sh -c 'yq ". | length" /home/node/.dsh/profiles/web/cordis.patch.yml | grep -q "^1$"' \
  || { echo "错误：cordis.patch.yml 应为 1 个条目" >&2; exit 1; }

echo "==> 冒烟测试全部通过 ✓"
