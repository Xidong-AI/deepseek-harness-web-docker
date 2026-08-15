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
  docker rm -f "$CID" >/dev/null 2>&1 || true
  [ -n "${SMOKE_HOME:-}" ] && rm -rf "$SMOKE_HOME" || true
}
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
SMOKE_HOME="$(mktemp -d)"
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

echo "==> 等待服务就绪（最多 120s）"
READY=0
for _ in $(seq 1 60); do
  CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/" || true)"
  if [ "$CODE" != "000" ]; then READY=1; break; fi
  sleep 2
done
if [ "$READY" != 1 ]; then
  echo "错误：服务 120s 内未就绪" >&2
  docker logs "$CID" 2>&1 | tail -30 >&2
  exit 1
fi

echo "==> basic auth：无凭据应 401"
CODE="$(curl -s -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
[ "$CODE" = "401" ] || { echo "错误：期望 401 实际 $CODE" >&2; exit 1; }

echo "==> basic auth：带凭据应 200"
CODE="$(curl -s -u admin:smoketest -o /dev/null -w '%{http_code}' "http://127.0.0.1:$PORT/")"
[ "$CODE" = "200" ] || { echo "错误：期望 200 实际 $CODE" >&2; exit 1; }

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
