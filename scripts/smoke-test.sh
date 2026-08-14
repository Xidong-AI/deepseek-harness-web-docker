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

echo "==> 进程检查：dsh 与 caddy 均 RUNNING"
STATUS="$(docker exec "$CID" supervisorctl status)"
grep -qE '^dsh[[:space:]]+RUNNING' <<<"$STATUS" || { printf '错误：dsh 未运行\n%s\n' "$STATUS" >&2; exit 1; }
grep -qE '^caddy[[:space:]]+RUNNING' <<<"$STATUS" || { printf '错误：caddy 未运行\n%s\n' "$STATUS" >&2; exit 1; }

echo "==> 冒烟测试全部通过 ✓"
