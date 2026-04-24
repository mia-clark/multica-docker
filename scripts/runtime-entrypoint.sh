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
#   3) 根据 OPENAI_BASE_URL / GEMINI_API_KEY 等自动生成
#      ~/.codex/config.toml、~/.gemini/settings.json
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

# ---------- Step 3: 三方 Agent CLI 凭据（Codex / Gemini） ----------
init_codex() {
    [ -n "${OPENAI_BASE_URL:-}" ] || return 0

    codex_dir="${CODEX_HOME:-/root/.codex}"
    codex_conf="${codex_dir}/config.toml"
    mkdir -p "${codex_dir}"

    if [ -f "${codex_conf}" ] && ! head -n 1 "${codex_conf}" | grep -q "multica-runtime"; then
        log "codex: user-authored ${codex_conf} detected, leaving untouched"
        return 0
    fi

    provider_name="${CODEX_PROVIDER_NAME:-multica-custom}"
    model_name="${OPENAI_MODEL:-gpt-4o-mini}"
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
model_provider = "${provider_name}"
model = "${model_name}"

[model_providers.${provider_name}]
name = "${provider_name}"
base_url = "${OPENAI_BASE_URL}"
wire_api = "${wire_api}"
env_key = "OPENAI_API_KEY"
EOF
    log "codex: wrote ${codex_conf} (provider=${provider_name}, model=${model_name})"
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

init_codex
init_gemini

# ---------- Step 4: 前台跑 daemon ----------
log "starting daemon (id=${DAEMON_ID})"
exec multica daemon start --foreground \
    --daemon-id "${DAEMON_ID}" \
    ${MULTICA_DAEMON_DEVICE_NAME:+--device-name "${MULTICA_DAEMON_DEVICE_NAME}"} \
    ${MULTICA_AGENT_RUNTIME_NAME:+--runtime-name "${MULTICA_AGENT_RUNTIME_NAME}"} \
    ${MULTICA_DAEMON_MAX_CONCURRENT_TASKS:+--max-concurrent-tasks "${MULTICA_DAEMON_MAX_CONCURRENT_TASKS}"}
