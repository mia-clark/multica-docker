# Multica Docker

[multica-ai/multica](https://github.com/multica-ai/multica) 的镜像构建与一键自托管编排。

本仓库不存放业务代码，只做两件事：

1. **定时/手动/每次 push** 从上游拉取源码，构建 Docker 镜像并推送到 **GitHub Container Registry (GHCR)**
2. 提供 `docker-compose.yml`，让任何人用一条命令跑起整套 Multica（控制面 + 数据面 + 前端）

---

## 🏛️ 架构

Multica 采用 **control plane / data plane 分离**设计：

```
┌──────────────┐   HTTP    ┌─────────────────┐   WebSocket    ┌──────────────┐
│   web        │ ────────► │   server        │ ◄────────────► │  runtime #1  │ ──► claude
│   (Next.js)  │           │   (控制面)       │   注册 + 派任务  │  +3 agent    │ ──► codex
└──────────────┘           │   Go 后端+DB    │                 │   CLI        │ ──► gemini
                           └─────────────────┘                 └──────────────┘
                                    ▲                           ┌──────────────┐
                                    │  想扩就堆更多 runtime    →  │  runtime #2  │
                                    │                           └──────────────┘
                                    │                                  ...
```

- **server** 负责接 Web 请求、存状态、派任务
- **runtime** 是独立 worker，启动即自动 `setup self-host` + 登录 + 注册到 server，收任务后调用本地 `claude` / `codex` / `gemini` CLI 执行
- runtime 可横向扩：`docker compose up -d --scale runtime=3`

---

## 📦 提供哪些镜像

| 镜像 | 角色 | 内容 |
|---|---|---|
| `ghcr.io/mia-clark/multica-server` | 控制面 | Go 后端 + `multica` CLI（精简，不含 agent CLI） |
| `ghcr.io/mia-clark/multica-runtime` | 数据面 | 复用 server 基底 + Node 22 + `claude` / `codex` / `gemini` CLI + runtime 启动脚本（**ENTRYPOINT 即 `multica daemon start`**） |
| `ghcr.io/mia-clark/multica-web` | 前端 | Next.js standalone |

> ⚠️ **`multica-server-full` 已 deprecated**。它把 server 和 agent 混在一个容器里违反职责分离。现有 tag 保留不删，但不再构建新版本。迁移指南见文末「从 server-full 迁移」。

---

## 🚀 快速开始（使用者）

> 前置依赖：Docker 20+、Docker Compose v2

```bash
# 1. 下载编排文件与 .env 模板（二选一）
curl -O https://raw.githubusercontent.com/mia-clark/multica-docker/main/docker-compose.yml

# 🌟 首选：完整模板（含 runtime 接入 + 反代凭据占位）
curl -O https://raw.githubusercontent.com/mia-clark/multica-docker/main/.env.example.full
cp .env.example.full .env

# 🪶 最小：只要跑起来，之后手动 login
# curl -O https://raw.githubusercontent.com/mia-clark/multica-docker/main/.env.example
# cp .env.example .env

# 2. 编辑 .env：
#    - JWT_SECRET 必填（openssl rand -hex 32）
#    - 用了 .env.example.full：替换所有 `your-xxx` 占位符
#    - MULTICA_TOKEN：暂时留空或占位，启动后在 Web UI 里生成 PAT 再回填

# 3. 启动（首次会拉镜像）
docker compose up -d

# 4. 访问
#    前端  http://localhost:3000
#    后端  http://localhost:8080
```

**首次 bootstrap 注意**：runtime 要连 server 必须登录一次。三种方式任选：

- **方式 A（推荐）**：Web UI 登录后去 Settings → Personal Access Tokens 生成 PAT，填到 `.env` 的 `MULTICA_TOKEN`，然后 `docker compose up -d --force-recreate runtime`，runtime 自动免交互登录
- **方式 B**：`docker compose exec runtime multica login`（邮件 OTP）；登录凭据落到 `multica_config` volume，之后重启都不用再登
- **方式 C（全 headless，无需 Web UI）**：适合内网 / 家庭服务器 / CI 流水线，见下一节

### Bootstrap without Web UI（方式 C）

内网自托管、CI 流水线、或就是懒得点浏览器？用 [`scripts/bootstrap-pat.sh`](./scripts/bootstrap-pat.sh) 直接走上游 HTTP API（`send-code → verify-code → workspace → PAT`）一把梭：

```powershell
# 1. 在 .env 里临时加一行（bootstrap 用完就删）
#    APP_ENV=development
# 这会启用验证码主码 888888；server 重启后生效。

# 2. 起 postgres + server
docker compose up -d server

# 3. 在临时 runtime 容器里跑脚本（借容器内的 curl + jq）
docker compose run --rm --no-deps `
    --entrypoint /bootstrap/bootstrap-pat.sh `
    -v "${PWD}/scripts/bootstrap-pat.sh:/bootstrap/bootstrap-pat.sh:ro" `
    runtime
# 输出最后一行形如：MULTICA_TOKEN=mul_pat_xxxxxxxx...

# 4. 把那行 PAT 覆盖到 .env 的 MULTICA_TOKEN=
# 5. 从 .env 删除 APP_ENV=development（安全起见）
# 6. 起全栈
docker compose up -d
```

**为什么脚本里要主动建 workspace？** 上游 `multica login --token` 成功后会调 `autoWatchWorkspaces()`，若该用户 0 workspace，会阻塞 5 分钟等用户在浏览器里创建。提前建好就能秒启 daemon。

**Linux/macOS 用户** 把反引号换行改成反斜杠 `\` 即可。

**不想开 `APP_ENV=development`？** 两条替代路径（脚本都兼容）：
- 配 `RESEND_API_KEY` 走真邮件：`BOOTSTRAP_EMAIL=you@example.com OTP_CODE=<邮件里的6位> sh bootstrap-pat.sh`
- 从 backend 日志捞 server 打印的 code：`docker compose logs server 2>&1 | Select-String 'Verification code'`，然后 `OTP_CODE=<6位>` 执行脚本

⚠️ **安全警告**：`APP_ENV=development` 会让任何知道邮箱的人用 `888888` 登录。**只在 bootstrap 时短开，跑完 PAT 立刻删掉**。公网直连的实例绝对不要打开。

**常用运维：**

```bash
docker compose logs -f                    # 所有服务日志
docker compose logs -f runtime            # 单独看 runtime
docker compose pull                       # 拉取最新镜像
docker compose up -d                      # 滚动升级
docker compose up -d --scale runtime=3    # 开 3 个 runtime 实例并发跑任务
docker compose down                       # 停止（数据保留）
docker compose down -v                    # 停止并清空数据（谨慎）
```

**锁定版本**：在 `.env` 中把 `MULTICA_TAG=latest` 改为某个 commit 短 hash 或上游 tag（如 `v0.2.13`）。

---

## 🤖 Runtime 详解

### 环境变量速览

| 变量 | 作用 | 默认 |
|---|---|---|
| `MULTICA_SERVER_URL` | daemon 连哪个 server | `http://server:8080` |
| `MULTICA_APP_URL` | 前端访问地址（daemon 生成链接/回调用） | `http://web:3000` |
| `MULTICA_TOKEN` | Personal Access Token，首次启动免交互登录 | 空 |
| `MULTICA_DAEMON_ID` | 每个 runtime 唯一 ID | `$HOSTNAME`（容器名） |
| `MULTICA_DAEMON_DEVICE_NAME` | Web UI 显示名 | 空 |
| `MULTICA_AGENT_RUNTIME_NAME` | runtime 显示名 | 空 |
| `MULTICA_DAEMON_MAX_CONCURRENT_TASKS` | 单个 runtime 并发任务上限 | 由 daemon 决定 |

### 三方 Agent CLI 凭据（runtime 专属）

| CLI | 直连官方 | 走第三方反代 |
|---|---|---|
| Claude Code | `ANTHROPIC_API_KEY` | `ANTHROPIC_BASE_URL` + `ANTHROPIC_AUTH_TOKEN` |
| Codex | `OPENAI_API_KEY` | `OPENAI_BASE_URL` + `OPENAI_API_KEY`<br>（启动时自动生成 `~/.codex/config.toml`） |
| Gemini | `GEMINI_API_KEY`（AI Studio） | 只能用 Vertex 兼容反代：`GOOGLE_API_KEY` + `GOOGLE_GENAI_USE_VERTEXAI=true` + `GOOGLE_CLOUD_PROJECT` |

示例 `.env` 片段（走第三方统一网关）：

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

改完 `.env` 后 `docker compose up -d --force-recreate runtime` 即生效。

### 启动时 runtime 容器做了什么？

runtime 镜像的 ENTRYPOINT 是 [`runtime-entrypoint.sh`](./scripts/runtime-entrypoint.sh)，流程：

1. `multica setup self-host --server-url $MULTICA_SERVER_URL --app-url $MULTICA_APP_URL`
2. 若 `MULTICA_HOME=/root/.multica` 为空且设了 `MULTICA_TOKEN` → `echo $MULTICA_TOKEN | multica login --token` 免交互登录
3. 若设了 `OPENAI_BASE_URL` → 自动生成 `~/.codex/config.toml`（Codex CLI 不认 env，必须写 toml）
4. 若设了 `GEMINI_API_KEY` 或 `GOOGLE_GENAI_USE_VERTEXAI=true` 且 `~/.gemini/settings.json` 不存在 → 写入 `selectedAuthType`
5. `exec multica daemon start --foreground --daemon-id $HOSTNAME`

理想路径 = 改 `.env` → `docker compose up -d` → runtime 自动出现在 Web UI 的 Runtimes 列表里。

### 手动调用 CLI

```bash
docker compose exec runtime claude "帮我重构这段代码"
docker compose exec runtime codex "..."
docker compose exec runtime gemini "..."

docker compose exec runtime multica daemon status
docker compose exec runtime multica daemon logs
```

### 横向扩多个 runtime

```bash
docker compose up -d --scale runtime=3
docker compose ps                           # 看 3 个 runtime 容器
docker compose logs -f --tail=100 runtime   # 多实例日志会合并输出
```

每个实例自动用 `$HOSTNAME` 作为 `--daemon-id`，互不冲突。它们都从同一个 `multica_config` volume 读凭据（所以只需要登录一次）。

---

## 🔄 从 server-full 迁移

如果你之前部署的是 `multica-server-full`（backend 单容器装 CLI），迁移到新架构：

1. **备份**（可选）：`docker compose down`（保留 volume）
2. **拉最新编排**：`curl -O .../docker-compose.yml`（`backend` → `server` + `runtime` 二分）
3. **更新 `.env`**：
   - `BACKEND_IMAGE` → 删除，改用 `SERVER_IMAGE` + `RUNTIME_IMAGE`
   - 新增 `MULTICA_SERVER_URL` / `MULTICA_APP_URL` / `MULTICA_TOKEN`
4. `docker compose pull && docker compose up -d`
5. 老的 `claude_config` / `codex_config` / `gemini_config` volume 名字没变，凭据无缝继承给 runtime；`multica_config` 同理
6. 旧 `backend` 容器可以删：`docker rm -f multica-backend`

---

## 🏗️ 镜像构建（维护者）

### 触发方式

工作流 [`.github/workflows/build-and-push.yml`](./.github/workflows/build-and-push.yml) 支持三种触发：

| 方式 | 说明 |
|---|---|
| 🚀 **Push** | 本仓库 `main` 分支每次 push 自动触发（连续 push 时自动取消旧构建，只保留最新） |
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
┌──────────────────────────────────┐
│  runtime                         │   FROM server:<sha>
│                                  │     + Node 22 + claude/codex/gemini
│                                  │     + scripts/runtime-entrypoint.sh
│                                  │     ENTRYPOINT = multica daemon
└──────────────────────────────────┘
```

三个镜像 SHA 严格对齐，同一次构建的 `runtime:xxx` 必然基于 `server:xxx`。

### 产物镜像

```
ghcr.io/mia-clark/multica-server:latest
ghcr.io/mia-clark/multica-server:<short-sha>
ghcr.io/mia-clark/multica-runtime:latest
ghcr.io/mia-clark/multica-runtime:<short-sha>
ghcr.io/mia-clark/multica-web:latest
ghcr.io/mia-clark/multica-web:<short-sha>
```

按 tag（如 `v0.2.13`）手动触发时，额外推送同名标签。

### ⚠️ 首次部署须知（只需做一次）

GHCR 镜像首次推送默认是 **Private**，需要手动改为 **Public** 别人才能免登录拉取：

1. 打开 <https://github.com/mia-clark?tab=packages>
2. 分别点进 `multica-server`、`multica-runtime`、`multica-web`
3. 右侧 → **Package settings** → 滚动到 **Danger Zone** → **Change visibility** → **Public**

---

## 🔧 故障排查

| 现象 | 排查方向 |
|---|---|
| `docker compose pull` 报 401/403 | 镜像还未改为 Public；或检查 tag 是否存在 |
| server 启动失败，日志 `JWT_SECRET` 相关 | `.env` 未设置或未加载 |
| 前端登录后 WebSocket 连不上 | 后端日志看 `ws: rejected origin`：把实际访问的 origin 加进 `CORS_ORIGINS`；反向代理场景把 `NEXT_PUBLIC_WS_URL` 改成 `wss://your-domain` |
| runtime 一直 Restarting | `docker compose logs runtime`：最常见是没登录（`MULTICA_TOKEN` 空 + `multica_config` volume 空），跑 `docker compose exec runtime multica login` |
| runtime 不出现在 Web UI 的 Runtimes 列表 | 登录凭据不对或 server URL 不对。`docker compose exec runtime multica daemon status` 看连接状态；`MULTICA_SERVER_URL` 是否 runtime 容器能访问到 |
| `codex` 没走反代 | `docker compose exec runtime cat /root/.codex/config.toml`：首行要有 `AUTO-GENERATED` 标记；没生成说明 `OPENAI_BASE_URL` 没传进来 |
| Gemini 填了 key 还弹交互式登录 | `docker compose exec runtime rm /root/.gemini/settings.json` 后 `--force-recreate runtime` 让脚本重写 |
| 想看启动脚本日志 | `docker compose logs runtime \| grep runtime-entrypoint` |
| 想回滚到某个旧版本 | 在 `.env` 中把 `MULTICA_TAG` 改成历史 commit 短 hash |

---

## 📜 许可

镜像中的 Multica 代码遵循上游 [multica-ai/multica](https://github.com/multica-ai/multica) 的许可协议。本仓库仅包含打包与编排脚本。
