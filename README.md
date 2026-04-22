# Multica Docker

[multica-ai/multica](https://github.com/multica-ai/multica) 的镜像构建与一键自托管编排。

本仓库不存放业务代码，只做两件事：

1. **定时/手动**从上游拉取源码，构建 Docker 镜像并推送到 **GitHub Container Registry (GHCR)**
2. 提供 `docker-compose.yml`，让任何人用一条命令跑起整套 Multica

---

## 📦 提供哪些镜像

| 镜像 | 用途 | 大小 | 内置内容 |
|---|---|---|---|
| `ghcr.io/mia-clark/multica-server` | 精简版后端 | 小 | Go 后端 + multica CLI |
| `ghcr.io/mia-clark/multica-server-full` | **全能版后端** | 大 | 精简版所有内容 + Node 22 + `claude` / `codex` / `gemini` CLI |
| `ghcr.io/mia-clark/multica-web` | 前端 | 中 | Next.js standalone |

**精简版 vs 全能版怎么选？**
- 如果你打算把 agent daemon 跑在宿主机（官方推荐架构）→ 选 **精简版**
- 如果你想让后端容器**自己就能调 agent CLI**，`docker exec` 进去就能用 → 选 **全能版**

切换方式：改 `.env` 里的 `BACKEND_IMAGE` 一行即可，不用动 compose。

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

# 3.（可选）想要容器内置 agent CLI，把 .env 里 BACKEND_IMAGE 改成：
#    BACKEND_IMAGE=ghcr.io/mia-clark/multica-server-full

# 4. 启动
docker compose up -d

# 5. 访问
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

## 🤖 使用内置 Agent CLI（仅全能版）

先把 `.env` 里 `BACKEND_IMAGE` 切为 `ghcr.io/mia-clark/multica-server-full`，然后 `docker compose up -d`。

### 认证（任选其一）

**方式 A：API Key 直连官方**（推荐，开箱即用）

在 `.env` 里填：
```env
ANTHROPIC_API_KEY=sk-ant-...
OPENAI_API_KEY=sk-...
GEMINI_API_KEY=...
```

`docker compose up -d` 后直接可用，无需任何 `login`。

**方式 B：走第三方反代 / 自建中转**（填 Base URL + Key，全家支持）

| CLI | 变量 | 说明 |
|---|---|---|
| Claude Code | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN`（或 `ANTHROPIC_API_KEY`） | 多数反代使用 Bearer Token 方式，此时填 `AUTH_TOKEN` 而非 `API_KEY` |
| Codex | `OPENAI_BASE_URL` + `OPENAI_API_KEY` | 容器启动时**自动生成** `~/.codex/config.toml`，把 provider 切到你的 endpoint；可选 `OPENAI_MODEL` / `CODEX_WIRE_API`（`chat` 或 `responses`，默认 `chat`） |
| Gemini | ⚠️ 官方 CLI **无自定义 endpoint 变量** | 要走中转只能用 Vertex 兼容的反代：填 `GOOGLE_API_KEY` + `GOOGLE_GENAI_USE_VERTEXAI=true` |

示例 `.env` 片段（走某第三方统一 OpenAI / Anthropic 兼容网关）：

```env
# Claude 走反代
ANTHROPIC_BASE_URL=https://your-proxy.example.com/anthropic
ANTHROPIC_AUTH_TOKEN=sk-your-proxy-token
ANTHROPIC_MODEL=claude-sonnet-4-6

# Codex 走反代
OPENAI_BASE_URL=https://your-proxy.example.com/v1
OPENAI_API_KEY=sk-your-proxy-token
OPENAI_MODEL=gpt-4o
CODEX_WIRE_API=chat
```

改完 `.env` 后 `docker compose up -d`（如果镜像已在跑，用 `docker compose up -d --force-recreate backend`），三家 CLI 即可开箱调用。

**方式 C：交互式登录**（适合走 Claude Pro / ChatGPT Plus 订阅登录态）

API Key 走的是按量 API 计费，跟订阅 Plan 不通用。想白嫖订阅额度必须交互式登录：

```bash
docker compose exec backend claude login
docker compose exec backend codex login
docker compose exec backend gemini           # 首次运行会引导登录
```

凭据分别存在挂载卷 `claude_config` / `codex_config` / `gemini_config` 中，重启、升级镜像都不会丢。

> 💡 自动生成的 Codex `config.toml` 会带 `# multica-agents-init: AUTO-GENERATED` 注释头。如果你手写过 `config.toml`，初始化脚本会检测并保留它，不会覆盖你的改动。

### 直接调用 CLI

```bash
docker compose exec backend claude "帮我重构这段代码"
docker compose exec backend codex "..."
docker compose exec backend gemini "..."
```

### 当 Multica daemon 使用

在同一个 backend 容器里额外起一个 daemon：

```bash
# 先配置 self-host 指向自己的 server
docker compose exec backend multica setup self-host --server-url http://localhost:8080
docker compose exec backend multica login

# 前台跑（查日志）
docker compose exec backend multica daemon start --foreground

# 或后台跑
docker compose exec -d backend multica daemon start
```

---

## 🏗️ 镜像构建（维护者）

### 触发方式

工作流 [`.github/workflows/build-and-push.yml`](./.github/workflows/build-and-push.yml) 支持两种触发：

| 方式 | 说明 |
|---|---|
| 🕐 **定时** | 每天 UTC 00:00（北京 08:00）自动构建上游 `main` |
| 👆 **手动** | Actions 页面点 "Run workflow"，可指定上游 `ref`（分支 / tag / commit） |

### 构建结构

```
┌────────────┐
│  prepare   │  计算 ref / sha / owner
└─────┬──────┘
      │
      ├─────────────────────────┐
      ▼                         ▼
┌──────────────┐         ┌──────────────┐
│  server      │         │  web         │
│  (上游构建)  │         │  (上游构建)  │
└──────┬───────┘         └──────────────┘
       │
       ▼
┌──────────────────────┐
│  server-full         │   FROM server:<sha> + Node + 3 CLI
└──────────────────────┘
```

三个镜像 SHA 严格对齐，同一次构建的 `server-full:xxx` 必然基于 `server:xxx`。

### 产物镜像

```
ghcr.io/mia-clark/multica-server:latest
ghcr.io/mia-clark/multica-server:<short-sha>
ghcr.io/mia-clark/multica-server-full:latest
ghcr.io/mia-clark/multica-server-full:<short-sha>
ghcr.io/mia-clark/multica-web:latest
ghcr.io/mia-clark/multica-web:<short-sha>
```

按 tag（如 `v0.2.13`）手动触发时，额外推送同名标签。

### ⚠️ 首次部署须知（只需做一次）

GHCR 镜像首次推送默认是 **Private**，需要手动改为 **Public** 别人才能免登录拉取：

1. 打开 <https://github.com/mia-clark?tab=packages>
2. 分别点进 `multica-server`、`multica-server-full`、`multica-web`
3. 右侧 → **Package settings** → 滚动到 **Danger Zone** → **Change visibility** → **Public**

---

## 🔧 故障排查

| 现象 | 排查方向 |
|---|---|
| `docker compose pull` 报 401/403 | 镜像还未改为 Public；或检查 tag 是否存在 |
| backend 启动失败，日志 `JWT_SECRET` 相关 | `.env` 未设置或未加载 |
| 前端登录后 WebSocket 连不上 | 反向代理场景下需把 `NEXT_PUBLIC_WS_URL` 改成 `wss://your-domain` |
| 容器内 `claude: not found` | 当前跑的是精简版 server，需要把 `BACKEND_IMAGE` 切成 `multica-server-full` |
| 交互式登录的 token 重启后消失 | 检查 `claude_config` 等 volume 是否被 `docker compose down -v` 清掉 |
| 想回滚到某个旧版本 | 在 `.env` 中把 `MULTICA_TAG` 改成历史 commit 短 hash |

---

## 📜 许可

镜像中的 Multica 代码遵循上游 [multica-ai/multica](https://github.com/multica-ai/multica) 的许可协议。本仓库仅包含打包与编排脚本。
