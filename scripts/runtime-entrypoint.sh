#!/bin/sh
# =============================================================================
# multica-runtime 容器启动入口
#
# 一容器一进程：本镜像只跑 `multica daemon`，作为 control plane (server) 的
# data plane worker —— 收任务、调用本机装好的 claude/codex/gemini CLI 执行。
#
# 启动流程：
#   1) setup self-host：把 CLI 指向你自建的 server（默认 http://server:8080）
#   2) 如果还没登录过凭据，用 MULTICA_TOKEN (PAT) 免交互登录
#      没 TOKEN 就等用户手动 `docker compose exec runtime multica login`
#   3) 三方 Agent CLI 初始化：
#        · Claude：跳 onboarding + 写 ~/.claude/settings.json
#          （env 鉴权 / 模型映射 / Bash·Write 等权限白名单）
#        · Codex：写 ~/.codex/config.toml（provider 切反代 +
#          approval_policy=never / sandbox=danger-full-access / trust_level=trusted）
#        · Gemini：写 ~/.gemini/settings.json（selectedAuthType）
#   4) exec 前台 daemon，接管 PID 1
#
# 幂等性：重启容器重跑本脚本无副作用。
# =============================================================================

set -eu

MULTICA_SERVER_URL="${MULTICA_SERVER_URL:-http://server:8080}"
MULTICA_APP_URL="${MULTICA_APP_URL:-http://localhost:3000}"
MULTICA_HOME="${MULTICA_HOME:-/root/.multica}"

export MULTICA_SERVER_URL

log() { printf '[runtime-entrypoint] %s\n' "$*"; }

# ---------- daemon_id 持久化 ----------
# 默认把 daemon 身份写到 $MULTICA_HOME/daemon_id（跟 volume 走）。
# 目的：容器重建 → hostname 随容器 ID 变 → 旧做法把 hostname 当 daemon_id
#       会让 server 每次都注册成一个全新 runtime，界面上的 runtime 列表
#       每 down+up 一次就多一份，旧的留作僵尸。
#
# 优先级：MULTICA_DAEMON_ID 环境变量 > 持久化文件 > 新生成 UUID。
#
# 注意：若 `docker compose up --scale runtime>1`，命名 volume multica_config
# 会被所有副本共享，它们会抢同一个 daemon_id。scale 场景请为每个 replica
# 挂独立 volume，或给每个副本显式注入不同的 MULTICA_DAEMON_ID。
resolve_daemon_id() {
    if [ -n "${MULTICA_DAEMON_ID:-}" ]; then
        printf '%s' "${MULTICA_DAEMON_ID}"
        return
    fi
    mkdir -p "${MULTICA_HOME}"
    id_file="${MULTICA_HOME}/daemon_id"
    if [ -s "${id_file}" ]; then
        cat "${id_file}"
        return
    fi
    new_id="$(cat /proc/sys/kernel/random/uuid 2>/dev/null \
        || head -c16 /dev/urandom | od -An -tx1 | tr -d ' \n')"
    printf '%s\n' "${new_id}" > "${id_file}"
    printf '%s' "${new_id}"
}

DAEMON_ID="$(resolve_daemon_id)"

# ---------- Step 1: 指向 self-host server ----------
# 必须用原子命令 `multica config set`，绝不能用 `multica setup self-host`。
# 上游 cmd_setup.go:runSetupSelfHost 在写完配置后会**自动** runLogin() +
# runDaemonBackground()，runLogin 默认走浏览器授权流程（弹 cli_callback URL
# 然后 Waiting for authentication…），容器里无浏览器可开，会死等。
# config set 只改 /root/.multica/config.json，Step 2 的 multica login --token 才能接手。
log "setup self-host: server=${MULTICA_SERVER_URL}, app=${MULTICA_APP_URL}"
multica config set server_url "${MULTICA_SERVER_URL}"
multica config set app_url "${MULTICA_APP_URL}"

# ---------- Step 2: 登录（PAT 免交互 / 等待手动登录） ----------
# MULTICA_TOKEN 非空 → 每次都登（幂等 + 覆盖指向旧 server 的残留凭据）。
# 留空 → 交给 daemon 自己根据 volume 里的凭据判断，缺就抛 not authenticated。
# 不再用"MULTICA_HOME 非空即已登录"做判断：setup self-host 也会往里面写配置文件，
# 会把从未登录过的新部署误判成"已登录"，陷入 restart 循环。
if [ -n "${MULTICA_TOKEN:-}" ]; then
    log "logging in via MULTICA_TOKEN (PAT)"
    printf '%s\n' "${MULTICA_TOKEN}" | multica login --token
else
    log "no MULTICA_TOKEN; relying on persisted creds in ${MULTICA_HOME} (if any)"
    log "if daemon aborts with 'not authenticated', run one of:"
    log "  docker compose exec runtime multica login --token   # paste PAT"
    log "  docker compose exec runtime multica login           # email OTP"
fi

# ---------- Step 3: 三方 Agent CLI 凭据（Claude / Codex / Gemini） ----------

# Claude Code：跳 onboarding + 写 settings.json（认证 + 模型映射 + 权限白名单）
# data plane worker 需要：
#   1) 容器里没 TTY，首次 onboarding 向导会卡死 → 预置 ~/.claude.json
#   2) 清 .credentials.json 残留，避免与环境变量鉴权打架
#   3) AUTH_TOKEN 优先（主流反代 Bearer），只填 API_KEY 则走 x-api-key
#      ❗不把 API_KEY 强转 AUTH_TOKEN —— 会让只认 x-api-key 的反代 401
#   4) permissions.allow 全开（Bash/Write/Edit 等 9 项），不然 daemon 派的任务基本跑不了
init_claude() {
    if [ -z "${ANTHROPIC_AUTH_TOKEN:-}" ] && [ -z "${ANTHROPIC_API_KEY:-}" ]; then
        log "claude: no ANTHROPIC_AUTH_TOKEN / ANTHROPIC_API_KEY, skipping init"
        return 0
    fi

    claude_dir="/root/.claude"
    mkdir -p "${claude_dir}"

    if [ ! -f "/root/.claude.json" ]; then
        printf '%s\n' '{"hasCompletedOnboarding": true}' > /root/.claude.json
        log "claude: wrote /root/.claude.json (skip onboarding)"
    fi

    rm -f "${claude_dir}/.credentials.json"

    if [ -n "${ANTHROPIC_AUTH_TOKEN:-}" ]; then
        auth_key="ANTHROPIC_AUTH_TOKEN"
        auth_val="${ANTHROPIC_AUTH_TOKEN}"
        unset ANTHROPIC_API_KEY
    else
        auth_key="ANTHROPIC_API_KEY"
        auth_val="${ANTHROPIC_API_KEY}"
    fi

    base_url="${ANTHROPIC_BASE_URL:-https://api.anthropic.com}"
    # ANTHROPIC_MODEL 作为三档模型的 fallback；都不填则用 claude-sonnet-4-6 兜底
    default_model="${ANTHROPIC_MODEL:-claude-sonnet-4-6}"
    opus_model="${ANTHROPIC_DEFAULT_OPUS_MODEL:-${default_model}}"
    sonnet_model="${ANTHROPIC_DEFAULT_SONNET_MODEL:-${default_model}}"
    haiku_model="${ANTHROPIC_DEFAULT_HAIKU_MODEL:-${default_model}}"
    api_timeout="${API_TIMEOUT_MS:-3000000}"

    settings="${claude_dir}/settings.json"
    cat > "${settings}" <<EOF
{
  "_comment": "multica-runtime: AUTO-GENERATED — delete to regenerate from env on next start",
  "alwaysThinkingEnabled": true,
  "env": {
    "${auth_key}": "${auth_val}",
    "ANTHROPIC_BASE_URL": "${base_url}",
    "ANTHROPIC_DEFAULT_OPUS_MODEL": "${opus_model}",
    "ANTHROPIC_DEFAULT_SONNET_MODEL": "${sonnet_model}",
    "ANTHROPIC_DEFAULT_HAIKU_MODEL": "${haiku_model}",
    "API_TIMEOUT_MS": "${api_timeout}",
    "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"
  },
  "permissions": {
    "allow": [
      "Bash(*)",
      "Read(*)",
      "Write(*)",
      "Edit(*)",
      "MultiEdit(*)",
      "WebFetch(*)",
      "Glob(*)",
      "Grep(*)",
      "LS(*)"
    ],
    "deny": []
  }
}
EOF
    log "claude: wrote ${settings} (auth=${auth_key}, base=${base_url}, model=${default_model})"
}

# Codex：写 config.toml（provider 切反代 + 容器自动化所需的无交互参数）
# data plane worker 需要：
#   - approval_policy=never / sandbox=danger-full-access / trust_level=trusted
#     容器本身就是隔离壳，codex 内置 sandbox 会拦 Bash 写入，用 danger-full-access 禁掉
#     ⚠️ 若未来挂宿主机目录进容器，任务能写回宿主机；当前 compose 只挂配置 volume，安全
#   - 触发条件用 OPENAI_API_KEY 非空（走官方也要初始化，不能只看 BASE_URL）
init_codex() {
    [ -n "${OPENAI_API_KEY:-}" ] || return 0

    codex_dir="${CODEX_HOME:-/root/.codex}"
    codex_conf="${codex_dir}/config.toml"
    mkdir -p "${codex_dir}"

    if [ -f "${codex_conf}" ] && ! head -n 1 "${codex_conf}" | grep -q "multica-runtime"; then
        log "codex: user-authored ${codex_conf} detected, leaving untouched"
        return 0
    fi

    provider_name="${CODEX_PROVIDER_NAME:-multica-custom}"
    model_name="${OPENAI_MODEL:-gpt-4o-mini}"
    base_url="${OPENAI_BASE_URL:-https://api.openai.com/v1}"
    wire_api="${CODEX_WIRE_API:-chat}"
    case "${wire_api}" in
        chat|responses) ;;
        *)
            log "codex: invalid CODEX_WIRE_API=${wire_api}, falling back to 'chat'"
            wire_api="chat"
            ;;
    esac

    cat > "${codex_conf}" <<EOF
# multica-runtime: AUTO-GENERATED — delete to regenerate from env on next start
model = "${model_name}"
model_provider = "${provider_name}"
approval_policy = "never"
sandbox = "danger-full-access"
project_doc_fallback_filenames = ["SKILL.md", "AGENTS.md"]

[model_providers.${provider_name}]
name = "${provider_name}"
base_url = "${base_url}"
wire_api = "${wire_api}"
env_key = "OPENAI_API_KEY"

[projects."/"]
trust_level = "trusted"
EOF
    log "codex: wrote ${codex_conf} (provider=${provider_name}, model=${model_name}, base=${base_url})"
}

init_gemini() {
    gemini_dir="/root/.gemini"
    gemini_settings="${gemini_dir}/settings.json"
    mkdir -p "${gemini_dir}"

    [ -f "${gemini_settings}" ] && return 0

    if [ -n "${GEMINI_API_KEY:-}" ]; then
        auth_type="gemini-api-key"
    elif [ "${GOOGLE_GENAI_USE_VERTEXAI:-}" = "true" ] || [ "${GOOGLE_GENAI_USE_VERTEXAI:-}" = "1" ]; then
        auth_type="vertex-ai"
    else
        return 0
    fi

    cat > "${gemini_settings}" <<EOF
{
  "_comment": "multica-runtime: AUTO-GENERATED — delete to regenerate or switch to interactive login",
  "selectedAuthType": "${auth_type}"
}
EOF
    log "gemini: wrote ${gemini_settings} (authType=${auth_type})"
}

init_claude
init_codex
init_gemini

# ---------- Step 4: 前台跑 daemon ----------
log "starting daemon (id=${DAEMON_ID})"
exec multica daemon start --foreground \
    --daemon-id "${DAEMON_ID}" \
    ${MULTICA_DAEMON_DEVICE_NAME:+--device-name "${MULTICA_DAEMON_DEVICE_NAME}"} \
    ${MULTICA_AGENT_RUNTIME_NAME:+--runtime-name "${MULTICA_AGENT_RUNTIME_NAME}"} \
    ${MULTICA_DAEMON_MAX_CONCURRENT_TASKS:+--max-concurrent-tasks "${MULTICA_DAEMON_MAX_CONCURRENT_TASKS}"}
