# 容器内运行环境说明（dsh agent 必读）

本会话运行在 Docker 容器内（用户 node，uid 1000），以下规则适用于所有 bash 工具调用。

## 预装工具

- 运行时：node 22、npm、pnpm（corepack）、python3、Caddy
- 常用工具：git、openssh-client、curl、wget、jq、yq、ripgrep、rsync、ps/pgrep、zip/unzip/tar、file、dig、sqlite3、pip、vim-tiny

## 自行安装工具（x-cmd，免 root）

镜像内置 x-cmd。安装并启用工具：

```bash
x env use jq python git   # 一次启用多个；可指定版本：x env use node=v20
x env ls                  # 查看已启用
x env which <pkg>         # 查看路径
```

调用已启用工具：

- **优先 `x <pkg>` 前缀调用**（`x jq . file.json`）——任何情况下都可用；
- 本次启动前已启用的包也已软链进 /usr/local/bin，**裸命令直接可用**（`jq . file.json`）；
- 刚安装的新包裸命令需容器重启后才进入 /usr/local/bin，当前会话请用 `x <pkg>` 前缀。

工具安装持久化在数据卷（~/.x-cmd.root），容器重启/重建后保留。

- **沙箱警告**：x-cmd 运行需写 `~/.x-cmd.root`。文件沙箱（workspace-write）仅放行会话工作区 + `/tmp`，该目录不可写——bwrap 沙箱下 `x` 启动即报 `folder defined ___X_CMD_ROOT specified is not writable`；本容器（无 bwrap，走 landlock）下 `x` 能启动，但 `x env use`/`x env ls` 等写操作报 `权限不够` 失败。两种情况都需申请完整权限（审批通过）后才能正常使用，或将工作区选在 `/home/node` 下。

## 限制

- 无 root/apt 权限，不能安装系统级包（gcc/make 等需自定义镜像，[见项目 README](https://github.com/Xidong-AI/deepseek-harness-web-docker/raw/refs/heads/master/README.zh.md)）；
- 不读 shell rc 文件：每次 bash -c 为全新环境，PATH 固定（/usr/local/sbin:/usr/local/bin:/usr/bin）；
- 文件沙箱：工作区之外的文件操作可能被拒绝（见工具描述）——包括 x-cmd 对 `~/.x-cmd.root` 的写入，沙箱下需完整权限才能用 `x`。
