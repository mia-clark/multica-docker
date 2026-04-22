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
DAEMON_ID="${MULTICA_DAEMON_ID:-$(hostname)}"

export MULTICA_SERVER_URL

log() { printf '[runtime-entrypoint] %s\n' "$*"; }

# ---------- Step 1: 指向 self-host server ----------
log "setup self-host: server=${MULTICA_SERVER_URL}, app=${MULTICA_APP_URL}"
multica setup self-host \
    --server-url "${MULTICA_SERVER_URL}" \
    --app-url "${MULTICA_APP_URL}" \
    >/dev/null

# ---------- Step 2: 登录（PAT 免交互 / 等待手动登录） ----------
# 登录凭据实际落盘位置由上游决定；目录非空就视为已登录
if [ -d "${MULTICA_HOME}" ] && [ -n "$(ls -A "${MULTICA_HOME}" 2>/dev/null || true)" ]; then
    log "detected existing auth in ${MULTICA_HOME}, skip login"
elif [ -n "${MULTICA_TOKEN:-}" ]; then
    log "logging in via MULTICA_TOKEN (PAT)"
    # `multica login --token` 交互式要求粘贴 token；通过 stdin 喂给它
    printf '%s\n' "${MULTICA_TOKEN}" | multica login --token
else
    log "WARN: no MULTICA_TOKEN and no existing auth."
    log "WARN: daemon will start but fail to authenticate. Run one of:"
    log "WARN:   docker compose exec runtime multica login --token   # paste PAT"
    log "WARN:   docker compose exec runtime multica login           # email OTP"
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
