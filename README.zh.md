# DeepSeek Harness Web Docker

> [English](README.md) | [中文](README.zh.md)

容器化部署 [DeepSeek Harness](https://github.com/deepseek-ai/deepseek-harness)（dsh）Web 客户端：单容器内含 dsh + Caddy basic auth，配置与项目/会话数据持久化，CI 自动推送 GHCR 镜像。

## 特性

- 单容器自包含：dsh（仅容器内 loopback）+ Caddy 基础用户名密码认证（basic auth）
- 配置与项目/会话数据持久化：bind mount `./data` → `/home/node`（整个 HOME：settings.yaml、API Key、profiles、sessions、storages，及 agent 自装工具 `~/.x-cmd.root`）
- 非 root 运行（uid 1000），dsh 不直接对外暴露
- 内置健康检查：`docker compose ps` 直接可见服务真实健康状态（带凭据穿透 basic auth 探测 dsh 响应，`starting`/`healthy`/`unhealthy`）
- 镜像版本可 pin：构建参数 `DSH_VERSION`
- CI 自动构建并推送 `ghcr.io/xidong-ai/deepseek-harness-web-docker`（latest + 日期时间 - 哈希 tag）
- 定时任务每日检查 dsh 上游：有新版本自动提升 `DSH_VERSION`、构建并冒烟测试，通过则推送 master 并钩住触发 GHCR 发布，失败则创建 Issue（存在同版本未关闭 Issue 时不再自动重试，可手动触发强制重试）
- GHCR 发布可手动触发（Actions 页「Run workflow」）或由上游升级自动钩住触发（`workflow_dispatch`）

## 快速开始

### 方式一：使用 GHCR 镜像

```bash
git clone https://github.com/Xidong-AI/deepseek-harness-web-docker
cd deepseek-harness-web-docker
cp .env.example .env    # 编辑 DSH_AUTH_USER / DSH_AUTH_PASSWORD / DEEPSEEK_API_KEY
docker compose up -d    # 拉取 latest 镜像并启动
```

### 方式二：本地构建

```bash
docker compose up -d --build
# 或指定 dsh 版本：
docker build --build-arg DSH_VERSION=0.1.0-rc.7 -t dsh-web:latest .
```

启动后浏览器访问 `http://<主机>:3080`（端口由 `.env` 的 `DSH_WEB_PORT` 控制），输入 basic auth 用户名密码。

## 环境变量（.env）

| 变量 | 必填 | 默认 | 说明 |
| --- | --- | --- | --- |
| `DSH_AUTH_USER` | 是 | `admin` | basic auth 用户名 |
| `DSH_AUTH_PASSWORD` | 是 | 无 | basic auth 明文密码（容器启动时自动生成 bcrypt 哈希） |
| `DEEPSEEK_API_KEY` | 是 | 无 | DeepSeek API Key（provider 经 apiKeyEnv 引用） |
| `DSH_WEB_PORT` | 否 | `3080` | 宿主机对外端口（与已有服务冲突时修改） |
| `DSH_TRUSTED_HOSTS` | 否 | 空 | 逗号分隔的额外受信 Host，注入 profile 的 `cordis.patch.yml`（仅当该文件不存在或仍为空模板时自动注入；已维护则跳过，请直接编辑该文件）；默认靠 Caddy 改写 Host/Origin 为 loopback 已覆盖常规访问 |
| `DSH_VERSION` | 否（构建期） | `0.1.0-rc.7` | dsh 版本，修改后需 `--build` 重建 |

> `.env` 含密码与 API Key，禁止提交入库。

## 数据持久化

所有配置与数据保存在项目目录 `./data/`（git 已忽略）：

- `settings.yaml`：dsh 配置（首启自动从默认模板生成）
- `.credentials.yaml`：凭据（如经 Web UI 配置的 API Key）
- `profiles/web/`：web profile（首启由 dsh 自动初始化）
- `sessions/`、`storages/`：会话与项目数据

删除容器不影响数据；升级后配置保留。

## 升级

```bash
docker compose pull && docker compose up -d   # 使用 GHCR 镜像时
# 或本地重建：
docker compose build && docker compose up -d
```

## 容器内工具与环境

dsh 的 agent 通过 bash 工具在容器内执行命令，可用工具集 = 镜像预装 + **agent 自行安装（x-cmd）**。

### 镜像预装

- 运行时：node 22、npm、pnpm（corepack，`dsh plugin` 依赖）、python3、Caddy、dsh
- agent 工具：git、openssh-client、curl/wget（网络）、jq/yq（JSON/YAML）、ripgrep（搜索）、rsync（同步）、procps（进程）、zip/unzip/tar、file、dig、sqlite3、python3-pip、vim-tiny、ca-certificates

### agent 自行安装（x-cmd，免 root）

镜像内置 [x-cmd](https://x-cmd.com)（首启自动安装到数据卷，幂等；阿里云 OSS 源）。dsh 会话中可直接执行：

```bash
x env use git python jq       # 安装/启用工具（免 root）
x env ls                      # 查看已启用工具
x env which jq                # 查看工具路径
x jq . data.json              # x 前缀调用（任何情况都可用）
jq . data.json                # 裸命令：已启用包已软链至 /usr/local/bin，直接可用
```

- 安装位置：`~/.x-cmd.root`（数据卷 `./data` 内），**容器重启/重建后保留**
- `x` 命令与已启用工具自动软链至 `/usr/local/bin`（agent 的 bash 环境 PATH 固定，软链是唯一接入点）
- 新安装的工具本会话用 `x <pkg>` 前缀调用，容器重启后裸命令可用
- 工具源为 x-cmd 包源（阿里云 OSS，国内可达），支持版本管理（`x env use node=v20`）

**沙箱注意**：x-cmd 运行需写 `~/.x-cmd.root`（数据卷内）。文件沙箱（workspace-write）仅放行会话工作区 + `/tmp`，该目录不可写——bwrap 沙箱下 `x` 启动即报 `folder defined ___X_CMD_ROOT specified is not writable`；本镜像无 bwrap，走 landlock 沙箱，`x` 能启动且**只读调用可用**（内置模块 `x version`/`x passwd`，已启用/已缓存包的 `x <pkg>` 前缀与软链裸命令），但**安装/启用新包失败**：`x env use` 报 `权限不够`，`x env ls` 静默返回空。要装新工具，agent 需申请完整权限（审批），或将工作区选在 `/home/node` 下。

容器内 agent 的环境指引见数据卷 `AGENTS.md`（dsh 会话自动加载）。


编译工具链（gcc/make）、编辑器等需 root 的系统包，修改 `Dockerfile` 的 `apt-get install` 行重建，或基于本镜像追加一层：

```dockerfile
FROM ghcr.io/xidong-ai/deepseek-harness-web-docker:latest
RUN apt-get update && apt-get install -y --no-install-recommends build-essential \
 && rm -rf /var/lib/apt/lists/*
```

## 修改密码

编辑 `.env` 的 `DSH_AUTH_PASSWORD`，然后 `docker compose up -d`（entrypoint 自动重新生成哈希）。

## 鸣谢

感谢 [Linux.do](https://linux.do) 社区的支持。
