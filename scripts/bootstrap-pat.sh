#!/usr/bin/env sh
# =============================================================================
# Multica · Headless PAT bootstrap — 免 Web UI 签一个 Personal Access Token
#
# 上游 multica-server 的登录流程强依赖 Web UI（或 CLI 跳浏览器）。
# 本脚本用上游的纯 HTTP API 走完：触发验证码 → 换 JWT → 建 workspace → 签 PAT。
# 适合：内网 / 家庭服务器 / CI 流水线自托管，不希望 bootstrap 阶段手动点浏览器。
#
# 前置（二选一）：
#   · server 以 APP_ENV=development 启动 → 能用验证码主码 888888（本脚本默认）
#   · server 配好 RESEND_API_KEY → 能收真实验证码，用 OTP_CODE=<6位> 覆盖
#   · 或从 server 容器日志里捞 code：
#       docker compose logs server | grep 'Verification code'
#
# 执行方式（在宿主机运行，内部自动进 runtime 容器借 curl+jq）：
#
#   # 1. 先确保 server 已在跑
#   docker compose up -d server
#
#   # 2. 起 bootstrap（Linux/macOS）
#   docker compose run --rm --no-deps \
#       --entrypoint /bootstrap/bootstrap-pat.sh \
#       -v "$PWD/scripts/bootstrap-pat.sh:/bootstrap/bootstrap-pat.sh:ro" \
#       runtime
#
#   # 2. 起 bootstrap（Windows PowerShell）
#   docker compose run --rm --no-deps `
#       --entrypoint /bootstrap/bootstrap-pat.sh `
#       -v "${PWD}/scripts/bootstrap-pat.sh:/bootstrap/bootstrap-pat.sh:ro" `
#       runtime
#
# 输出形如：
#   MULTICA_TOKEN=mul_pat_xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx
#
# 回填到 .env 后，触发 runtime 重建即可自动登录：
#   docker compose up -d --force-recreate runtime
#
# 环境变量（可选，全部有默认值）：
#   BOOTSTRAP_EMAIL       bootstrap 用户邮箱                default: admin@local
#   OTP_CODE              验证码                            default: 888888
#   BOOTSTRAP_WORKSPACE   首个 workspace 名字               default: default
#   BOOTSTRAP_PAT_NAME    PAT 在列表里的显示名              default: runtime-boot-YYYYMMDD
#   SERVER_URL            server 基地址                    default: http://server:8080
# =============================================================================

set -eu

EMAIL="${BOOTSTRAP_EMAIL:-admin@local}"
CODE="${OTP_CODE:-888888}"
WORKSPACE_NAME="${BOOTSTRAP_WORKSPACE:-default}"
PAT_NAME="${BOOTSTRAP_PAT_NAME:-runtime-boot-$(date -u +%Y%m%d)}"
SERVER_URL="${SERVER_URL:-http://server:8080}"

log() { printf '[bootstrap] %s\n' "$*" >&2; }

# ---------- 依赖自检 ----------
command -v curl >/dev/null 2>&1 || { log "ERROR: curl not found"; exit 127; }
command -v jq   >/dev/null 2>&1 || { log "ERROR: jq not found";   exit 127; }

# ---------- Step 1: 触发一条 verification code 记录落库 ----------
# 即使 Resend 没配，server 会在发邮件之前把 code 写进 verification_codes 表。
# 返回 500 也不影响后续 verify-code（主码 888888 仍可通过）。
log "step 1/4: trigger verification code for ${EMAIL}"
curl -s -o /dev/null \
    -X POST "${SERVER_URL}/auth/send-code" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"email":"%s"}' "${EMAIL}")" || true

# ---------- Step 2: verify-code 换 JWT ----------
log "step 2/4: verify code → JWT (email=${EMAIL}, code=${CODE})"
VERIFY_RESP=$(curl -s -w '\n%{http_code}' \
    -X POST "${SERVER_URL}/auth/verify-code" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"email":"%s","code":"%s"}' "${EMAIL}" "${CODE}")") || true

VERIFY_HTTP=$(printf '%s\n' "${VERIFY_RESP}" | tail -n1)
VERIFY_BODY=$(printf '%s\n' "${VERIFY_RESP}" | sed '$d')

if [ "${VERIFY_HTTP}" != "200" ]; then
    log "ERROR: verify-code returned HTTP ${VERIFY_HTTP}: ${VERIFY_BODY}"
    log "hints:"
    log "  1) server 必须以 APP_ENV=development 启动才能用 888888"
    log "     在 .env 里加 APP_ENV=development，然后 docker compose up -d server"
    log "  2) 或用真实 code 覆盖:"
    log "       docker compose logs server 2>&1 | grep -i 'verification code'"
    log "       OTP_CODE=<6位真码> sh $0"
    exit 1
fi

JWT=$(printf '%s' "${VERIFY_BODY}" | jq -r '.token // empty')
if [ -z "${JWT}" ]; then
    log "ERROR: verify-code returned 200 but no .token field: ${VERIFY_BODY}"
    exit 1
fi
log "  -> JWT acquired"

AUTH_HEADER="Authorization: Bearer ${JWT}"

# ---------- Step 3: 确保至少 1 个 workspace ----------
# 上游 multica login --token 成功后会调 autoWatchWorkspaces，若 0 个 workspace
# 会阻塞最多 5 分钟等用户在浏览器里创建。提前建好就能秒起 daemon。
log "step 3/4: ensure at least one workspace"
WS_COUNT=$(curl -sf -H "${AUTH_HEADER}" "${SERVER_URL}/api/workspaces" | jq -r 'length // 0')

if [ "${WS_COUNT}" = "0" ]; then
    curl -sf -X POST "${SERVER_URL}/api/workspaces" \
        -H "${AUTH_HEADER}" \
        -H "Content-Type: application/json" \
        -d "$(printf '{"name":"%s"}' "${WORKSPACE_NAME}")" >/dev/null
    log "  -> created workspace '${WORKSPACE_NAME}'"
else
    log "  -> ${WS_COUNT} workspace(s) already exist, skip"
fi

# ---------- Step 4: 签 PAT ----------
log "step 4/4: create PAT '${PAT_NAME}'"
PAT_RESP=$(curl -sf -X POST "${SERVER_URL}/api/tokens" \
    -H "${AUTH_HEADER}" \
    -H "Content-Type: application/json" \
    -d "$(printf '{"name":"%s"}' "${PAT_NAME}")")

PAT=$(printf '%s' "${PAT_RESP}" | jq -r '.token // empty')
if [ -z "${PAT}" ]; then
    log "ERROR: failed to create PAT. response: ${PAT_RESP}"
    exit 1
fi

log ""
log "DONE. Copy the line below into .env (replace existing MULTICA_TOKEN=):"
log "----------------------------------------------------------------------"
printf 'MULTICA_TOKEN=%s\n' "${PAT}"
log "----------------------------------------------------------------------"
log "then: docker compose up -d --force-recreate runtime"
log ""
log "SECURITY REMINDER: 若你只是为了 bootstrap 临时开了 APP_ENV=development，"
log "bootstrap 完成后请改回 production（或从 .env 删除该行），避免主码 888888 长期有效。"
