#!/bin/sh
# =============================================================================
# multica-server-full 的容器启动前置脚本
#
# 作用：把 compose / .env 里传进来的第三方 Agent 环境变量，翻译成各 CLI 实际
# 需要的配置文件 / 环境变量，让 `claude` / `codex` / `gemini` 在容器启动后
# 无需手动 login 即可直接使用。
#
# 三家 CLI 的配置策略：
#   - Claude Code : 原生读 ANTHROPIC_API_KEY / ANTHROPIC_AUTH_TOKEN /
#                   ANTHROPIC_BASE_URL / ANTHROPIC_MODEL，env 透传即可。
#   - Codex       : env 只认 OPENAI_API_KEY；自定义 endpoint 必须通过
#                   ~/.codex/config.toml 的 [model_providers.*]。本脚本
#                   在 OPENAI_BASE_URL 非空时自动生成该文件。
#   - Gemini      : 原生读 GEMINI_API_KEY / GOOGLE_API_KEY +
#                   GOOGLE_GENAI_USE_VERTEXAI，env 透传即可；官方无自定义
#                   endpoint 变量，走中转需用 Vertex 兼容代理。
#
# 幂等性：生成的 config.toml 带 AUTO-GENERATED 标记；若检测到用户手写的
# 配置（无标记），则保留不覆盖。
# =============================================================================

set -eu

AUTO_MARK="# multica-agents-init: AUTO-GENERATED — safe to delete, will be re-created from env on next start"

# ---------- Codex：根据 env 生成 ~/.codex/config.toml ----------
init_codex() {
    # 没配自定义 endpoint 就什么都不做，让用户的 login / 手写 config 正常工作
    if [ -z "${OPENAI_BASE_URL:-}" ]; then
        return 0
    fi

    codex_dir="${CODEX_HOME:-/root/.codex}"
    codex_conf="${codex_dir}/config.toml"
    mkdir -p "${codex_dir}"

    # 如果用户已经手写了 config.toml（没有我们的标记），不动它
    if [ -f "${codex_conf}" ] && ! head -n 1 "${codex_conf}" | grep -q "multica-agents-init"; then
        echo "[agents-init] 已存在用户自定义 ${codex_conf}，跳过自动生成"
        return 0
    fi

    provider_name="${CODEX_PROVIDER_NAME:-multica-custom}"
    model_name="${OPENAI_MODEL:-gpt-4o-mini}"
    wire_api="${CODEX_WIRE_API:-chat}"

    # wire_api 只允许 chat / responses
    case "${wire_api}" in
        chat|responses) ;;
        *)
            echo "[agents-init] 警告：CODEX_WIRE_API=${wire_api} 不合法，回退为 chat" >&2
            wire_api="chat"
            ;;
    esac

    cat > "${codex_conf}" <<EOF
${AUTO_MARK}
# 源自 docker-compose 环境变量：
#   OPENAI_BASE_URL    = ${OPENAI_BASE_URL}
#   OPENAI_MODEL       = ${model_name}
#   CODEX_WIRE_API     = ${wire_api}
#   CODEX_PROVIDER_NAME= ${provider_name}

model_provider = "${provider_name}"
model = "${model_name}"

[model_providers.${provider_name}]
name = "${provider_name}"
base_url = "${OPENAI_BASE_URL}"
wire_api = "${wire_api}"
env_key = "OPENAI_API_KEY"
EOF

    echo "[agents-init] 已生成 ${codex_conf}（provider=${provider_name}, model=${model_name}）"
}

# ---------- Gemini：兜底把 API key / Vertex 设置落到 settings.json ----------
# 官方推荐走 env，但有些版本需要 ~/.gemini/settings.json 显式声明 selectedAuthType。
# 此处只做最小干预：若 volume 里还没有 settings.json，且用户确实设了 API key，
# 则写一份 "使用 Gemini API key" 的最简配置，避免交互式引导。
init_gemini() {
    gemini_dir="/root/.gemini"
    gemini_settings="${gemini_dir}/settings.json"
    mkdir -p "${gemini_dir}"

    # 用户已经有设置文件就完全不碰
    if [ -f "${gemini_settings}" ]; then
        return 0
    fi

    if [ -n "${GEMINI_API_KEY:-}" ]; then
        auth_type="gemini-api-key"
    elif [ "${GOOGLE_GENAI_USE_VERTEXAI:-}" = "true" ] || [ "${GOOGLE_GENAI_USE_VERTEXAI:-}" = "1" ]; then
        auth_type="vertex-ai"
    else
        return 0
    fi

    cat > "${gemini_settings}" <<EOF
{
  "_comment": "multica-agents-init: AUTO-GENERATED — delete to regenerate or to go back to interactive login",
  "selectedAuthType": "${auth_type}"
}
EOF

    echo "[agents-init] 已生成 ${gemini_settings}（authType=${auth_type}）"
}

init_codex
init_gemini

# 把控制权交回给上游 server 镜像的原 entrypoint
exec /app/entrypoint.sh "$@"
