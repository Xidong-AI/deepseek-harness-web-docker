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
# 就绪 = Caddy 在听 3081。200（链路全通）和 401（basic auth 拒绝但端口活了）都算就绪，
# 因为后续 basic auth 断言会自然区分这两条路径。502（Caddy 在但 dsh 还没就绪）和
# 000（未监听）继续等。这是 dsh 0.1.2-rc.1 学到的：上游 dsh 启动后 web 鉴权可能挂
# （持续 401），caddy 自身是活的
#
# Ready = Caddy is listening on 3081. Both 200 (full chain) and 401 (basic-auth rejected
# but the port is alive) count: the basic-auth assertion below distinguishes them.
# 502 (Caddy up but dsh not yet) and 000 (not listening) keep waiting.
# This was learned with dsh 0.1.2-rc.1: its web auth can hang in 401, with Caddy fine
READY=0
LAST_CODE=000
START_TS="$(date +%s)"
for _ in $(seq 1 120); do
  CODE="$(curl -s -u admin:smoketest -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
  LAST_CODE="$CODE"
  if [ "$CODE" = "200" ] || [ "$CODE" = "401" ]; then READY=1; break; fi
  sleep 2
done
if [ "$READY" != 1 ]; then
  ELAPSED=$(( $(date +%s) - START_TS ))
  echo "错误：服务 ${ELAPSED}s 内 Caddy 仍未监听（最后一次 HTTP code=$LAST_CODE）" >&2
  echo "  （注：502/000 表示 Caddy/dsh 还在初始化；持续 502 是上游启动慢/挂）" >&2
  echo "  （注：401 表示 Caddy 活但 basic auth 拒绝——会进入下一步 basic auth 断言，不算此错）" >&2
  docker logs "$CID" 2>&1 | tail -30 >&2
  exit 1
fi

echo "==> basic auth：无凭据应 401"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
[ "$CODE" = "401" ] || { echo "错误：期望 401 实际 $CODE（caddy 自身未在 3081 basic-auth 拒绝）" >&2; exit 1; }

echo "==> basic auth：带凭据应 200"
CODE="$(curl -s -u admin:smoketest -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
[ "$CODE" = "200" ] || {
  echo "错误：带 admin:smoketest 凭据应返 200，实际 $CODE" >&2
  # 关键诊断：绕过 caddy 直连容器内 dsh 3080，看 dsh 自身是 200/401/502/连不上——
  # 区分「Caddy basic-auth 配置错（DSH_AUTH_HASH 注入问题）」vs「dsh 上游就拒绝」
  #
  # Key diagnostic: bypass Caddy and curl dsh 3080 directly to see whether dsh itself
  # returns 200/401/502 or is unreachable — distinguishes a Caddy basic-auth config
  # issue (DSH_AUTH_HASH not injected) from dsh upstream rejecting everything
  echo "--- 诊断：绕开 caddy 直连容器内 dsh 3080 ---" >&2
  echo "  带 admin:smoketest 凭据:" >&2
  docker exec "$CID" curl -s -u admin:smoketest -o /dev/null -w '  HTTP %{http_code} 耗时 %{time_total}s\n' "http://127.0.0.1:3080/" >&2 || true
  echo "  不带凭据（dsh 自身通常会返 401/403 或重定向到登录页）:" >&2
  docker exec "$CID" curl -s -o /dev/null -w '  HTTP %{http_code} 耗时 %{time_total}s\n' "http://127.0.0.1:3080/" >&2 || true
  echo "  supervisor 摘要:" >&2
  docker exec "$CID" supervisorctl status 2>&1 | sed 's/^/    /' >&2 || true
  echo "  最近 30 行容器日志:" >&2
  docker logs "$CID" 2>&1 | tail -30 | sed 's/^/    /' >&2
  exit 1
}

echo "==> 特权 API fence：伪造 Host 直连容器内 dsh 应 403（fence 拒绝未授权来源）"
# 不经 Caddy 直连 127.0.0.1:3080，伪造浏览器 Host=evil.com——dsh 视其为非本机来源
CODE="$(docker exec "$CID" curl -s -o /dev/null -w '%{http_code}' -X POST \
  -H 'Host: evil.com' -H 'Content-Type: application/json' -d '{}' \
  "http://127.0.0.1:3080/api")"
[ "$CODE" = "403" ] || { echo "错误：fence 未拒绝伪造 Host（期望 403 实际 $CODE）" >&2; exit 1; }

echo "==> 特权 API fence：经 Caddy 伪造 Host/Origin 应被改写为 loopback（非 403）"
# 浏览器形态请求经 Caddy：Host/Origin 被改写为 127.0.0.1:3080，fence 通过；
# 若 Caddyfile 的 header_up 两行失效，此处将返回 403——即改写链路回归
CODE="$(curl -s -u admin:smoketest -o /dev/null -w '%{http_code}' -X POST \
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
