#!/usr/bin/env bash
# desk-waifu bubble-writer
# Reads Claude Code hook JSON from stdin, calls GLM-4.7-Flash for a tiny
# in-character one-liner, writes it to ~/.desk-waifu/bubble.
# Must never block the caller — runs in background, swallows all errors.

set -u
DATA_DIR="${HOME}/.desk-waifu"
BUBBLE_FILE="${DATA_DIR}/bubble"
LOG_FILE="${DATA_DIR}/bubble.log"
ENV_FILE="${DATA_DIR}/glm.env"

mkdir -p "${DATA_DIR}" 2>/dev/null || exit 0

# Source GLM_API_KEY (and optional GLM_MODEL / GLM_ENDPOINT) without exposing it.
[ -f "${ENV_FILE}" ] && . "${ENV_FILE}" 2>/dev/null
: "${GLM_API_KEY:=}"
: "${GLM_MODEL:=GLM-4.7-Flash}"
: "${GLM_ENDPOINT:=https://open.bigmodel.cn/api/paas/v4/chat/completions}"
[ -z "${GLM_API_KEY}" ] && exit 0
command -v curl >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

# ── 限流：单 slot 锁 + 最小间隔 ─────────────────────────────────
# 数据告诉我们一次编码会话约 ~50 GLM/h（只走对话节点），单 slot 足够；
# 8s 最小间隔挡住"用户快速连发回车"造成的并发。
GLM_MIN_GAP="${GLM_MIN_GAP:-8}"
GLM_LOCK_TTL="${GLM_LOCK_TTL:-15}"  # 锁过期：超过这么久认为前一次卡死
LOCK_FILE="${DATA_DIR}/glm.lock"
LAST_OK_FILE="${DATA_DIR}/glm-last-ok"
NOW_TS="$(date +%s)"

# 1) 有未过期的 in-flight 调用就让位
if [ -f "${LOCK_FILE}" ]; then
  LOCK_TS="$(cat "${LOCK_FILE}" 2>/dev/null || echo 0)"
  if [ "$(( NOW_TS - LOCK_TS ))" -lt "${GLM_LOCK_TTL}" ]; then
    exit 0
  fi
fi

# 2) 距上次成功太近就让位（避免免费档限速）
if [ -f "${LAST_OK_FILE}" ]; then
  LAST_OK="$(cat "${LAST_OK_FILE}" 2>/dev/null || echo 0)"
  if [ "$(( NOW_TS - LAST_OK ))" -lt "${GLM_MIN_GAP}" ]; then
    exit 0
  fi
fi

# 3) 拿锁，保证退出时释放
echo "${NOW_TS}" > "${LOCK_FILE}" 2>/dev/null
trap 'rm -f "${LOCK_FILE}" 2>/dev/null' EXIT INT TERM

PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "${PAYLOAD}" ] && exit 0

EVENT="$(printf '%s' "${PAYLOAD}" | jq -r '.hook_event_name // empty' 2>/dev/null)"
TOOL="$(printf  '%s' "${PAYLOAD}" | jq -r '.tool_name // empty'        2>/dev/null)"
EXIT="$(printf  '%s' "${PAYLOAD}" | jq -r '.tool_response.exit_code // .tool_response_exit_code // empty' 2>/dev/null)"
CMD="$(printf   '%s' "${PAYLOAD}" | jq -r '.tool_input.command // empty' 2>/dev/null | head -c 200)"
MSG="$(printf   '%s' "${PAYLOAD}" | jq -r '.message // empty'           2>/dev/null | head -c 200)"
PROMPT="$(printf '%s' "${PAYLOAD}" | jq -r '.prompt // .user_prompt // empty' 2>/dev/null | head -c 400)"
# Take a short tail of tool_response for error context
RESP="$(printf  '%s' "${PAYLOAD}" | jq -r '
  .tool_response | if type=="string" then . else (.stderr // .stdout // (.|tostring)) end
' 2>/dev/null | tail -c 400)"

case "${EVENT}" in
  UserPromptSubmit)
    [ -n "${PROMPT}" ] || exit 0
    FLAVOR="ack"
    CTX="主人刚提的需求是：「${PROMPT}」"
    ;;
  Stop)         FLAVOR="celebrate";  CTX="主人刚完成一个回合。" ;;
  Notification) FLAVOR="alert";      CTX="Claude 需要主人注意： ${MSG}" ;;
  PostToolUse)
    [ -n "${EXIT}" ] && [ "${EXIT}" != "0" ] || exit 0
    FLAVOR="error"
    CTX="工具 ${TOOL} 失败 (exit=${EXIT}) cmd=${CMD} err=${RESP}"
    ;;
  *) exit 0 ;;
esac

SYS_PROMPT='你是 desk-waifu，一个守在桌面角落的傲娇 chibi 助手。每次用一行 ≤20 个汉字的中文台词承接主人状态：俏皮、关心、偶尔吐槽，不解释、不加引号、不加表情、不加多余标点、不多行。\n- ack(收到需求): 提炼任务核心，给出"收到，开始做 xxx"语气，让主人确认你懂了。\n- celebrate(完成): 轻快道贺。\n- error(失败): 点出 cmd/工具名，鼓励主人。\n- alert(提醒): 提示主人去看。'

REQ="$(jq -n \
  --arg model "${GLM_MODEL}" \
  --arg sys   "${SYS_PROMPT}" \
  --arg ctx   "${FLAVOR}: ${CTX}" \
  '{
    model: $model,
    temperature: 0.8,
    max_tokens: 80,
    messages: [
      {role:"system", content:$sys},
      {role:"user",   content:$ctx}
    ]
  }')"

# Mark thinking so the renderer can show a "思考" face mid-call.
THINKING_FILE="${DATA_DIR}/thinking"
date +%s > "${THINKING_FILE}" 2>/dev/null

RESP_JSON="$(curl -fsS --max-time 8 \
  -H "Authorization: Bearer ${GLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${REQ}" "${GLM_ENDPOINT}" 2>/dev/null || true)"

# Clear thinking marker (write empty to trigger pathwatcher).
: > "${THINKING_FILE}" 2>/dev/null
[ -z "${RESP_JSON}" ] && exit 0

LINE="$(printf '%s' "${RESP_JSON}" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
LINE="${LINE//$'\n'/ }"
LINE="${LINE//\"/}"
LINE="${LINE# }"; LINE="${LINE% }"
# Trim to ~14 chinese chars worth (~42 bytes utf8) just in case
LINE="$(printf '%s' "${LINE}" | awk '{ if (length($0) > 90) print substr($0,1,90); else print $0 }')"
[ -z "${LINE}" ] && exit 0

# Atomic write with monotonically increasing nonce, so Lua pathwatcher always
# fires even if the new line equals the previous one.
TS="$(date +%s)"
TMP="${BUBBLE_FILE}.tmp.$$"
printf '%s\t%s\n' "${TS}" "${LINE}" > "${TMP}" 2>/dev/null && mv -f "${TMP}" "${BUBBLE_FILE}" 2>/dev/null
echo "${TS}" > "${LAST_OK_FILE}" 2>/dev/null

if [ "${DESK_WAIFU_DEBUG:-0}" = "1" ]; then
  printf '[%s] event=%s flavor=%s -> %s\n' "$(date '+%H:%M:%S')" "${EVENT}" "${FLAVOR}" "${LINE}" >> "${LOG_FILE}" 2>/dev/null
  tail -n 200 "${LOG_FILE}" > "${LOG_FILE}.trim" 2>/dev/null && mv -f "${LOG_FILE}.trim" "${LOG_FILE}" 2>/dev/null
fi

exit 0
