# DeepSeek Harness Web Docker 设计文档

> 状态：设计稿（v1，已与需求方对齐，未进入实现）

## 1. 项目概述

把 DeepSeek Harness（DSH）Web 客户端 + 基础认证反代容器化，交付一个**可复现、面向最终用户**的单容器镜像：

- 容器内托管 dsh Web 客户端（监听容器内 loopback，不对外）
- 内置 Caddy basic auth 用户名密码保护
- 配置与项目/会话数据经 bind mount 持久化到宿主机
- CI 自动构建并推送 GHCR（`ghcr.io/xidong-ai/deepseek-harness-web-docker`）

参考现有宿主机实现（`~/.local/bin/dsh`、`~/.local/bin/caddy-dsh`），但项目独立、不含个人私有配置，适合推送给其他用户。

## 2. 架构

```
浏览器 ──HTTP──> 宿主机:${DSH_WEB_PORT:-3080}
                    │  docker compose ports 映射
                    ▼
        ┌─────────── Docker 容器 ────────────────────────────┐
        │  supervisord (PID 1)                                │
        │  ├─ caddy  0.0.0.0:3081                             │
        │  │   ├─ basic_auth（用户 ${DSH_AUTH_USER}，bcrypt）│
        │  │   └─ reverse_proxy 127.0.0.1:3080                │
        │  │       header_up Host/Origin → loopback           │
        │  └─ dsh --profile web --port 3080                   │
        │       （仅 bind 127.0.0.1:3080，不对外）             │
        │                                                     │
        │  /home/dsh/.dsh ◄── bind mount ──> ./data           │
        └─────────────────────────────────────────────────────┘
```

### 2.1 为什么 dsh 与 Caddy 必须同容器共享 loopback

DSH v0.1 无内置认证，且特权 API（`settings.*`/`credentials.*`，`PRIVILEGED_METHODS` 硬编码空信任列表）**只接受 loopback 来源**（防 DNS rebinding）。因此：

- 反代必须与 dsh 处于同一 network namespace，经 `127.0.0.1:3080` 转发
- Caddy 必须把上游请求的 `Host`/`Origin` 改写为 `127.0.0.1:3080`，使 dsh 视为本机来源（Origin 必须与改写后 Host 同源，否则 fence 的 Origin 检查仍 403）
- 若拆成 compose 多服务，跨容器请求的来源不是 loopback，特权 API 必然 403——故**单容器是硬约束，不是偏好**

### 2.2 与现有实现的差异（容器化的关键修正）

| 项目 | 宿主机现有（参考） | 容器内 |
| --- | --- | --- |
| dsh 监听 | `127.0.0.1:3080` | `127.0.0.1:3080`（不变） |
| Caddy 监听 | `bind 127.0.0.1 ::1` 的 `:3081` | `0.0.0.0:3081`（Docker 端口映射 DNAT 到容器 eth0，bind loopback 会拒接映射流量） |
| 对外端口 | 公网经 cloudflared → 3081 | `${DSH_WEB_PORT:-3080}:3081`，默认 3080 |
| 进程管理 | pm2（宿主机开机自启） | supervisord（容器 PID 1） |
| 配置目录 | `~/.dsh/`（HOME 本机） | `/home/dsh/.dsh/`，bind mount `./data` |
| basic auth 密码 | `ecosystem.config.js` 里 bcrypt 哈希 | `.env` 明文，entrypoint 启动时自动哈希 |
| profile web | 软链到 dot-files 仓库 | 镜像内置默认模板，entrypoint 首启复制进数据卷 |
| trustedHosts | 硬编码 `dsh.pj568.eu.org` | `.env` 可选变量注入，默认靠 Caddy 改写 |

## 3. 关键决策记录（对齐结论）

| # | 决策点 | 结论 |
| --- | --- | --- |
| 1 | 容器编排形态 | 单容器：dsh + Caddy 共存（supervisord 管理） |
| 2 | 镜像基础 | `node:22-slim`（Debian glibc）+ `npm i -g` 装 dsh；Caddy 官方静态二进制 |
| 3 | 进程管理 | supervisord（PID 1 正确处理信号，日志转发 stdout/stderr） |
| 4 | 运行用户 | 专用非 root 用户 `dsh`（uid 1000），HOME=`/home/dsh` |
| 5 | 持久化 | bind mount `./data` → `/home/dsh/.dsh/`（整个目录：settings/credentials/profiles/sessions/storages） |
| 6 | 认证密码 | `.env` 放明文 `DSH_AUTH_PASSWORD`，entrypoint 用 `caddy hash-password` 生成 bcrypt 注入 |
| 7 | dsh 版本 | Dockerfile `ARG DSH_VERSION=0.1.0-rc.6`，可构建时覆盖 |
| 8 | 对外端口 | `${DSH_WEB_PORT:-3080}:3081`，环境变量可改（本机测试时换端口避开现有 3080/3081） |
| 9 | 首启初始化 | 镜像内置最小 web profile + settings.yaml 模板，entrypoint 检测数据卷为空时复制，之后持久化 |
| 10 | trustedHosts | `DSH_TRUSTED_HOSTS`（可选，逗号分隔）注入 `cordis.patch.yml`；默认靠 Caddy 改写 loopback |
| 11 | API Key | 仅 `.env` 注入：`DEEPSEEK_API_KEY`，settings.yaml 用 `apiKeyEnv` 引用 |
| 12 | settings 模板 | 最小通用：`deepseek-official`（apiKeyEnv）+ `agent-default-model`；不含个人私有 provider |
| 13 | 与现有部署关系 | 独立通用项目，推送给用户；本机测试用另一端口，不影响现有 pm2 部署 |
| 14 | 分发 | 源码（Dockerfile + compose）+ CI 自动构建推 GHCR |
| 15 | GHCR 路径 | `ghcr.io/xidong-ai/deepseek-harness-web-docker` |
| 16 | CI 触发/tag | push master 触发；镜像 tag = 日期时间 + 提交哈希（另推 `latest` 便于 compose 默认引用） |

## 4. 文件清单

```
deepseek-harness-web-docker/
├── Dockerfile                  # node:22-slim + dsh(npm, ARG 版本) + caddy + supervisord + entrypoint
├── docker-compose.yml          # 单服务；ports: ${DSH_WEB_PORT:-3080}:3081；./data bind mount
├── .env.example                # 全部可配变量的模板（提交入库，.env 不入库）
├── .gitignore                  # .env、data/（含 .credentials.yaml 等敏感文件）
├── .dockerignore
├── README.md                   # 面向用户：快速开始、变量说明、升级、排错
├── LICENSE
├── Caddyfile                   # basic_auth + reverse_proxy（容器内 /etc/caddy/Caddyfile）
├── supervisord.conf            # 两个 program：dsh、caddy（容器内 /etc/supervisor/conf.d/dsh.conf）
├── entrypoint.sh               # 首启初始化 + 哈希注入 + 降权启动 supervisord
├── defaults/                   # 镜像内置默认配置（COPY 进镜像 /opt/dsh/defaults）
│   ├── settings.yaml           # deepseek-official(apiKeyEnv: DEEPSEEK_API_KEY) + agent-default-model
│   └── profiles/web/
│       ├── package.json        # dsh.profile.bundles: [@deepseek-ai/dsh-base, @deepseek-ai/dsh-web-app]
│       ├── cordis.yml          # []（空入口，patch 机制组合）
│       ├── cordis.patch.yml    # connection.trustedHosts 占位（entrypoint 按 DSH_TRUSTED_HOSTS 注入）
│       └── pnpm-workspace.yaml # packages: [.]，nodeLinker: hoisted
├── .github/workflows/
│   └── docker-build.yml        # push master → buildx → tag(日期时间-哈希, latest) → push GHCR
└── data/                       # 持久化卷（git 忽略，运行期生成）
```

### 4.1 各文件要点

- **Dockerfile**：`ARG DSH_VERSION=0.1.0-rc.6` → `npm install -g @deepseek-ai/dsh@${DSH_VERSION}`；下载 Caddy 官方二进制（glibc）；`apt-get install supervisor`；创建 `dsh` 用户（uid 1000）；COPY defaults、Caddyfile、entrypoint、supervisord.conf；`ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]`
- **docker-compose.yml**：单服务 `dsh-web`；`ports: ["${DSH_WEB_PORT:-3080}:3081"]`；`volumes: ["./data:/home/dsh/.dsh"]`；`env_file: .env`（必填 `DSH_AUTH_PASSWORD`、`DEEPSEEK_API_KEY`）；`restart: unless-stopped`
- **Caddyfile**：
  ```
  http://:3081 {
      basic_auth {
          {$DSH_AUTH_USER} {$DSH_AUTH_HASH}
      }
      reverse_proxy 127.0.0.1:3080 {
          header_up Host 127.0.0.1:3080
          header_up Origin http://127.0.0.1:3080
      }
  }
  ```
  （bcrypt 含 `$` 必须经环境变量注入，不能直写 Caddyfile；`{$VAR}` 引用安全）

- **entrypoint.sh**（bash，按序执行）：
  1. 若 `/home/dsh/.dsh` 为空：从 `/opt/dsh/defaults` 复制 `settings.yaml` 与 `profiles/web/`，并创建 `profiles/web/node_modules` 软链指向 `/usr/local/lib/node_modules/@deepseek-ai/dsh/node_modules`（bundle 解析需要，参考现有 `profiles/node_modules` 软链做法）
  2. 若 `DSH_TRUSTED_HOSTS` 非空：以逗号分隔项替换 `cordis.patch.yml` 的 `trustedHosts` 占位
  3. `DSH_AUTH_HASH=$(caddy hash-password --plaintext "$DSH_AUTH_PASSWORD")`，导出给 supervisord 子进程
  4. `chown -R dsh:dsh /home/dsh/.dsh`（bind mount 首启属主可能是 root）
  5. supervisord 以 root 启动、program 指定 `user=dsh`（避免 su 嵌套）
- **supervisord.conf**：`[program:dsh]` 执行 `dsh --profile web --port 3080`（不传 `--trusted-host`，该链路不可靠；trustedHosts 走 cordis.patch.yml）；`[program:caddy]` 执行 `caddy run --config /etc/caddy/Caddyfile --adapter caddyfile`；均 `stdout_logfile=/dev/stdout`、`autorestart=true`
- **defaults/settings.yaml**：
  ```yaml
  deepseek-official:
    providers:
      deepseek:
        apiKeyEnv: DEEPSEEK_API_KEY
  agent-default-model:
    provider: deepseek
    model: deepseek-v4-pro
    reasoningEffort: high
  ```
  （字段名以实际 dsh schema 为准，实现时用本机 rc.6 实例核对后定稿）
- **defaults/profiles/web/cordis.patch.yml** 占位：
  ```yaml
  - id: connection
    config:
      trustedHosts: []
  ```
- **.github/workflows/docker-build.yml**：`on: push: branches: [master]`；buildx（`linux/amd64`，可选 `linux/arm64` 多架构）→ tag `latest` + `${日期时间}-${sha7}`（如 `20260815T0054-a1b2c3d`）→ push `ghcr.io/xidong-ai/deepseek-harness-web-docker`（用 `GITHUB_TOKEN`，组织级包权限需在仓库设置开启）

## 5. 环境变量参考（.env.example）

| 变量 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `DSH_AUTH_USER` | 是 | `admin` | basic auth 用户名 |
| `DSH_AUTH_PASSWORD` | 是 | 无 | basic auth 明文密码（entrypoint 自动生成 bcrypt） |
| `DEEPSEEK_API_KEY` | 是 | 无 | DeepSeek API Key（settings.yaml 经 apiKeyEnv 引用） |
| `DSH_WEB_PORT` | 否 | `3080` | 宿主机对外端口（测试时可改，如 3082） |
| `DSH_TRUSTED_HOSTS` | 否 | 空 | 逗号分隔的额外受信 Host（公网域名/自定义域名），注入 cordis.patch.yml；默认靠 Caddy 改写 loopback 已覆盖常规访问 |
| `DSH_VERSION` | 否（构建期） | `0.1.0-rc.6` | Dockerfile ARG，构建镜像时固定 |

> `.env` 不入库；`.env.example` 入库。API Key 与密码均为敏感信息，bind mount 的 `data/.credentials.yaml` 同样敏感，`.gitignore` 必须覆盖。

## 6. 用户运行说明（README 草案要点）

```bash
git clone <repo>
cd deepseek-harness-web-docker
cp .env.example .env          # 编辑 DSH_AUTH_USER/PASSWORD、DEEPSEEK_API_KEY
docker compose up -d --build  # 或 docker compose up -d（用 GHCR 镜像时）
# 浏览器访问 http://<host>:3080，输入 basic auth 用户名密码
```

- 配置与项目/会话数据持久化在 `./data`，删容器不丢
- 升级：`docker compose pull` + `docker compose up -d`（数据卷不动）
- 改密码：改 `.env` 后 `docker compose up -d`（entrypoint 重新哈希）
- 公网暴露（可选）：配合 Cloudflare Tunnel/反代，把公网域名填入 `DSH_TRUSTED_HOSTS` 并建议加 HTTPS

## 7. 安全注意事项

- basic auth 是**基础**认证：HTTP 明文传输时密码可被嗅探，公网使用必须套 HTTPS（Caddy 容器内仅 HTTP，HTTPS 由外层隧道/反代终结）
- dsh 不直接对外暴露：容器内仅 bind `127.0.0.1:3080`，compose 不映射该端口
- 特权 API 依赖 Caddy 改写 Host/Origin 为 loopback 才可通过；Caddyfile 不可去掉 `header_up` 两行
- 容器非 root 运行（uid 1000），数据卷属主由 entrypoint 修正
- `data/`、`.env` 含密钥，禁止入库

## 8. 验证计划（实现阶段的 TDD 冒烟测试）

1. **构建**：`docker build --build-arg DSH_VERSION=0.1.0-rc.6 -t dsh-web:test .` 成功
2. **首启初始化**：清空 `./data` 后起容器，验证 `data/settings.yaml`、`data/profiles/web/*` 生成、属主为 1000
3. **basic auth**：无凭据 `curl -o /dev/null -w "%{http_code}" http://127.0.0.1:${DSH_WEB_PORT}/` 应 401；带 `-u` 应 200
4. **dsh 响应**：带凭据访问 `/` 返回 dsh Web 页面；`/api` 健康接口 200（Host/Origin 改写生效，无 fence 403）
5. **持久化**：重启容器后 `data/` 内容不变；`docker compose down && up` 后 settings 仍在
6. **密码轮换**：改 `.env` 密码重建容器，旧密码 401、新密码 200
7. **trustedHosts**：设 `DSH_TRUSTED_HOSTS=example.com` 后检查 `data/profiles/web/cordis.patch.yml` 注入正确
8. **CI**：本地 `act` 或推 master 后确认 GHCR 出现 `latest` 与日期时间 - 哈希 tag

本机测试必须改 `DSH_WEB_PORT`（如 3082）避开现有 pm2 的 3080/3081。

## 9. 后续实现任务（按序）

1. 建 Dockerfile + defaults（settings.yaml 字段以本机 rc.6 实际 schema 核对）
2. entrypoint.sh + supervisord.conf + Caddyfile
3. docker-compose.yml + .env.example + .gitignore/.dockerignore
4. 本机冒烟测试（§8，另一端口）
5. README + LICENSE
6. GitHub Actions workflow → push master 验证 GHCR
7. 合入 master（单目标提交，遵循提交规范）
## 10. 实现差异记录（实现阶段实测修正）

| 设计稿 | 实现实测 | 原因 |
| --- | --- | --- |
| 镜像内置默认 web profile，entrypoint 首启复制 | defaults 仅含 settings.yaml；profile 由 dsh 首启自动初始化（dsh-app-boot 的 PROFILE_TEMPLATES.web + initProfile），entrypoint 仅在设置 DSH_TRUSTED_HOSTS 时预写 cordis.patch.yml | 代码调研发现 dsh 内置 web profile 模板且自动维护 profiles/node_modules 软链（healProfilesModuleFallback），无需内置复制 |
| 专用非 root 用户 dsh（uid 1000），数据目录 /home/dsh/.dsh | 复用官方镜像自带 node 用户（uid 1000），数据目录 /home/node/.dsh | node:22-slim 已自带 uid 1000 的 node 用户，避免删除/重建用户 |
| npm i -g 纯 JS 安装 | 需先装 build-essential + python3（node-pty 等 native 依赖编译），装完清理 build-essential | dsh 依赖 node-pty（node-gyp 编译），slim 镜像无工具链 |
| GHCR 路径 ghcr.io/Xidong-AI/... | 全小写 ghcr.io/xidong-ai/... | Docker registry 仓库名必须小写 |
| 容器内 Caddyfile 可读 | 需显式 chmod 644 /etc/caddy/Caddyfile | COPY 保留源 600 权限，node 用户读不了 |
| 容器内工具集 | 镜像补充 git/openssh-client/curl/jq/unzip + corepack pnpm；并集成 x-cmd 环境自举 | agent 的 bash 工具环境是白名单（PATH 固定 /usr/local/bin 等、无 HOME），镜像预装保证基础可用，x-cmd 让 agent 免 root 自装工具（持久化于卷）；x wrapper 注入 HOME，use 包 shim 软链至 /usr/local/bin |
| 数据卷布局 | bind mount 从 /home/node/.dsh 扩为整个 /home/node | x-cmd 安装于 $HOME/.x-cmd.root（硬编码 HOME 路径），需要 HOME 整体持久化；.dsh 数据兼容保留 |
| defaults 内容 | 增加 AGENTS.md（容器环境指引，dsh 会话自动加载） | agent 需要知道容器环境限制与 x-cmd 用法 |
| 上游版本手动升级（改 ARG 后 --build） | 新增 `upstream-check.yml` 定时任务（每日 UTC 03:00 + workflow_dispatch）与 `scripts/`（check-upstream / should-upgrade / upgrade-dsh / smoke-test / open-issue / check-issue-gate / close-stale-issues）：检测 `@deepseek-ai/dsh` dist-tags.latest 更新后自动提升 Dockerfile/compose/README 双语中的版本号，构建冒烟测试（镜像构建、dsh --version 校验、basic auth 401/200、双进程 RUNNING）通过则推送 master（触发 GHCR 自动构建），失败则创建 Issue（同版本去重）；存在同版本未关闭失败 Issue 时定时任务跳过自动升级（npm 包版本不可变，重试必失败；仅 schedule 生效，手动触发绕过供人工重试环境性失败），升级成功后自动关闭过时失败 Issue | 需求：dsh 上游自动跟进；失败不推送、master 保持已验收状态；冒烟跳过 x-cmd 首启下载（预置假 x）；DESIGN.md 历史内容不做自动替换 |
| supervisord.conf | 无 `[rpcinterface:supervisor]` 段 | 补齐该段 | 缺段时 `docker exec supervisorctl status` 报 "did not recognize the supervisor namespace commands"（socket 通但 RPC 命名空间未注册），冒烟测试进程检查实际从未通过 |
| 冒烟测试范围 | 仅 basic auth 401/200 + 双进程 RUNNING | 新增特权 API fence 断言（伪造 Host 直连容器内 dsh 的 `POST /api` 应 403；经 Caddy 伪造 Host/Origin 应被改写为 loopback、返回 400/404 而非 403）+ trustedHosts 注入断言；进程检查改为轮询等待（dsh 首启初始化慢于 Caddy） | 安全关键路径需回归：实测 dsh 特权 RPC 端点为 `POST /api`（GET 404，坏 payload 400/404），fence 即 DESIGN §2.1 所述 loopback 来源检查 |
| chown 属主修正 | 每次启动无条件 `chown -R node:node /home/node` | 仅当根目录属主非 1000:1000 时全量修正，否则跳过 | 数据卷含 x-cmd 工具（数万文件），全量递归拖慢每次重启 |
| trustedHosts 注入条件 | 仅当 `cordis.patch.yml` 不存在时注入 | 不存在**或为空模板**（顶层数组 `[]`，即 dsh 首启生成）时注入；已有内容/不可解析时跳过并提示 | dsh 首启自动生成空模板 patch（initProfile 对已存在文件不覆盖），用户首启未设变量、后设变量重启需能自动注入；已维护的 patch 绝不覆盖 |

