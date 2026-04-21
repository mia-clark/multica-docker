# Multica Docker

[multica-ai/multica](https://github.com/multica-ai/multica) 的镜像构建与一键自托管编排。

本仓库不存放业务代码，只做两件事：

1. **定时/手动**从上游拉取源码，构建 Docker 镜像并推送到 **GitHub Container Registry (GHCR)**
2. 提供 `docker-compose.yml`，让任何人用一条命令跑起整套 Multica

---

## 🚀 快速开始（使用者）

> 前置依赖：Docker 20+、Docker Compose v2

```bash
# 1. 下载编排文件与环境变量模板
curl -O https://raw.githubusercontent.com/mia-clark/multica-docker/main/docker-compose.yml
curl -O https://raw.githubusercontent.com/mia-clark/multica-docker/main/.env.example
cp .env.example .env

# 2. 生成强随机 JWT_SECRET 并写入 .env
#    Linux/macOS:  openssl rand -hex 32
#    Windows PS :  -join ((1..64) | ForEach-Object { '{0:x}' -f (Get-Random -Max 16) })

# 3. 启动
docker compose up -d

# 4. 访问
#    前端  http://localhost:3000
#    后端  http://localhost:8080
```

**常用运维：**

```bash
docker compose logs -f          # 查看日志
docker compose pull             # 拉取最新镜像
docker compose up -d            # 滚动升级
docker compose down             # 停止（数据保留）
docker compose down -v          # 停止并清空数据（谨慎）
```

**锁定版本**：在 `.env` 中把 `MULTICA_TAG=latest` 改为某个 commit 短 hash 或上游 tag（如 `v0.2.13`）。

---

## 🏗️ 镜像构建（维护者）

### 触发方式

工作流 [`.github/workflows/build-and-push.yml`](./.github/workflows/build-and-push.yml) 支持两种触发：

| 方式 | 说明 |
|---|---|
| 🕐 **定时** | 每天 UTC 00:00（北京 08:00）自动构建上游 `main` |
| 👆 **手动** | Actions 页面点 "Run workflow"，可指定上游 `ref`（分支 / tag / commit） |

### 产物镜像

```
ghcr.io/mia-clark/multica-server:latest
ghcr.io/mia-clark/multica-server:<short-sha>
ghcr.io/mia-clark/multica-web:latest
ghcr.io/mia-clark/multica-web:<short-sha>
```

按 tag（如 `v0.2.13`）手动触发时，额外推送同名标签。

### ⚠️ 首次部署须知（只需做一次）

GHCR 镜像首次推送默认是 **Private**，需要手动改为 **Public** 别人才能免登录拉取：

1. 打开 <https://github.com/mia-clark?tab=packages>
2. 分别点进 `multica-server` 和 `multica-web`
3. 右侧 → **Package settings** → 滚动到 **Danger Zone** → **Change visibility** → **Public**

（或者让使用者先 `docker login ghcr.io` 再 pull，但不推荐。）

---

## 🧾 架构

```
┌────────────────────────┐
│  multica-ai/multica    │ ← 公开源码
└────────┬───────────────┘
         │ 每日拉取 / 手动触发
         ▼
┌────────────────────────┐
│  GitHub Actions        │
│  (本仓库 workflow)      │
└────────┬───────────────┘
         │ docker push
         ▼
┌────────────────────────┐
│  ghcr.io/mia-clark/*   │ ← 预构建镜像（public）
└────────┬───────────────┘
         │ docker compose pull
         ▼
┌────────────────────────┐
│  终端用户服务器          │
│  web + backend + pg    │
└────────────────────────┘
```

- 目前仅构建 `linux/amd64`，如需 `arm64` 可在 workflow 的 `platforms` 中追加
- 使用 GitHub Actions Cache 加速构建（分镜像独立 scope）

---

## 🔧 故障排查

| 现象 | 排查方向 |
|---|---|
| `docker compose pull` 报 401/403 | 镜像还未改为 Public；或检查 tag 是否存在 |
| backend 启动失败，日志 `JWT_SECRET` 相关 | `.env` 未设置或未加载 |
| 前端登录后 WebSocket 连不上 | 反向代理场景下需把 `NEXT_PUBLIC_WS_URL` 改成 `wss://your-domain` |
| 想回滚到某个旧版本 | 在 `.env` 中把 `MULTICA_TAG` 改成历史 commit 短 hash |

---

## 📜 许可

镜像中的 Multica 代码遵循上游 [multica-ai/multica](https://github.com/multica-ai/multica) 的许可协议。本仓库仅包含打包与编排脚本。
