#!/usr/bin/env bash
# desk-waifu speech-tick — 主动台词决策器
# 由 Hammerspoon 每 ~5 分钟调用一次。读 journal 最近 5 分钟做聚合，
# 满足触发条件就调 GLM 写一句陪伴台词到 ~/.desk-waifu/bubble。
# 永远静默退出，不影响主流程。

set -u
DATA_DIR="${HOME}/.desk-waifu"
JOURNAL="${DATA_DIR}/journal.ndjson"
BUBBLE_FILE="${DATA_DIR}/bubble"
LAST_TICK_FILE="${DATA_DIR}/last_tick"
LOG_FILE="${DATA_DIR}/speech-tick.log"
ENV_FILE="${DATA_DIR}/glm.env"

[ -f "${ENV_FILE}" ] && . "${ENV_FILE}" 2>/dev/null
: "${GLM_API_KEY:=}"
: "${GLM_MODEL:=GLM-4-FlashX}"
: "${GLM_ENDPOINT:=https://open.bigmodel.cn/api/paas/v4/chat/completions}"
[ -z "${GLM_API_KEY}" ] && exit 0
[ -f "${JOURNAL}" ]  || exit 0
command -v jq   >/dev/null 2>&1 || exit 0
command -v curl >/dev/null 2>&1 || exit 0

# 共享 bubble-writer 那套锁：避免主动台词撞到 ack 之类
GLM_MIN_GAP="${GLM_MIN_GAP:-8}"
GLM_LOCK_TTL="${GLM_LOCK_TTL:-15}"
LOCK_FILE="${DATA_DIR}/glm.lock"
LAST_OK_FILE_GLM="${DATA_DIR}/glm-last-ok"
NOW_LOCK="$(date +%s)"
if [ -f "${LOCK_FILE}" ]; then
  LOCK_TS="$(cat "${LOCK_FILE}" 2>/dev/null || echo 0)"
  [ "$(( NOW_LOCK - LOCK_TS ))" -lt "${GLM_LOCK_TTL}" ] && exit 0
fi
if [ -f "${LAST_OK_FILE_GLM}" ]; then
  LAST_OK="$(cat "${LAST_OK_FILE_GLM}" 2>/dev/null || echo 0)"
  [ "$(( NOW_LOCK - LAST_OK ))" -lt "${GLM_MIN_GAP}" ] && exit 0
fi
echo "${NOW_LOCK}" > "${LOCK_FILE}" 2>/dev/null
trap 'rm -f "${LOCK_FILE}" 2>/dev/null' EXIT INT TERM

NOW="$(date +%s)"
WINDOW_BEGIN=$(( NOW - 300 ))           # 最近 5 分钟
SILENCE_MIN=$(( ${SPEECH_MIN_GAP:-180} )) # 距离上次台词至少多少秒才再说

LAST_TICK=0
[ -f "${LAST_TICK_FILE}" ] && LAST_TICK="$(cat "${LAST_TICK_FILE}" 2>/dev/null || echo 0)"
if [ "$(( NOW - LAST_TICK ))" -lt "${SILENCE_MIN}" ]; then
  exit 0
fi

# ── 聚合最近 5 分钟 ──────────────────────────────────────────────
SUMMARY="$(jq -s --argjson begin "${WINDOW_BEGIN}" '
  map(select(.ts >= $begin)) as $win
  | {
      n_events: ($win | length),
      n_errors: ($win | map(select(.exit != null and .exit != 0)) | length),
      tools:    ($win | map(.tool // "?") | group_by(.) | map({k:.[0], v:length}) | sort_by(-.v) | .[0:3]),
      files:    ($win | map(.path) | map(select(. != null)) | unique | length),
      last_err: ($win | map(select(.exit != null and .exit != 0)) | last),
      last_cmd: ($win | map(select(.cmd != null)) | last | .cmd // null),
      span_sec: (if ($win|length) > 0 then (($win|last).ts - ($win|first).ts) else 0 end),
      idle_sec: (if ($win|length) > 0 then ('${NOW}' - ($win|last).ts) else 999 end)
    }
' "${JOURNAL}" 2>/dev/null)"

[ -z "${SUMMARY}" ] && exit 0

N_EVENTS=$(printf '%s' "${SUMMARY}"  | jq -r '.n_events')
N_ERRORS=$(printf '%s' "${SUMMARY}"  | jq -r '.n_errors')
SPAN=$(printf '%s' "${SUMMARY}"      | jq -r '.span_sec')
IDLE=$(printf '%s' "${SUMMARY}"      | jq -r '.idle_sec')
N_FILES=$(printf '%s' "${SUMMARY}"   | jq -r '.files')
TOP_TOOL=$(printf '%s' "${SUMMARY}"  | jq -r '.tools[0].k // "无"')
TOP_COUNT=$(printf '%s' "${SUMMARY}" | jq -r '.tools[0].v // 0')

# ── 触发器：满足任一就开口 ───────────────────────────────────────
TRIGGER=""
if [ "${N_ERRORS}" -ge 3 ]; then
  TRIGGER="repeat_error"
elif [ "${IDLE}" -ge 120 ] && [ "${N_EVENTS}" -gt 0 ]; then
  TRIGGER="long_idle"          # 之前在干活，最近 2 分钟突然安静
elif [ "${SPAN}" -ge 600 ] && [ "${N_EVENTS}" -ge 8 ]; then
  TRIGGER="long_session"       # 一直在忙活
elif [ "${N_FILES}" -ge 5 ]; then
  TRIGGER="multi_file"
elif [ "${TOP_COUNT}" -ge 8 ]; then
  TRIGGER="tool_focused"       # 反复用同一工具
fi

[ -z "${TRIGGER}" ] && exit 0  # 没啥好说的就闭嘴

# ── 调 GLM ──────────────────────────────────────────────────────
SYS_PROMPT='你是 desk-waifu，一个守在桌面右下角的傲娇 chibi 助手。每次只能用一行 ≤14 个汉字的中文台词主动陪伴主人。台词要基于"刚才在干嘛"的语境，俏皮、关心、偶尔吐槽；不解释、不加引号、不加表情、不加多余标点、不加多行。'
USER_CTX="$(jq -n \
  --arg trigger "${TRIGGER}" \
  --arg n_events "${N_EVENTS}" \
  --arg n_errors "${N_ERRORS}" \
  --arg tool "${TOP_TOOL}" \
  --arg n_files "${N_FILES}" \
  --arg span "${SPAN}" \
  '"触发: \($trigger)。最近5分钟: 事件\($n_events) 错误\($n_errors) 主要工具\($tool) 涉及文件\($n_files) 持续\($span)秒。说一句陪伴话。"' | jq -r .)"

REQ="$(jq -n \
  --arg model "${GLM_MODEL}" \
  --arg sys "${SYS_PROMPT}" \
  --arg ctx "${USER_CTX}" \
  '{
    model: $model,
    temperature: 0.85,
    max_tokens: 40,
    messages: [
      {role:"system", content:$sys},
      {role:"user",   content:$ctx}
    ]
  }')"

RESP_JSON="$(curl -fsS --max-time 8 \
  -H "Authorization: Bearer ${GLM_API_KEY}" \
  -H "Content-Type: application/json" \
  -d "${REQ}" "${GLM_ENDPOINT}" 2>/dev/null || true)"
[ -z "${RESP_JSON}" ] && exit 0

LINE="$(printf '%s' "${RESP_JSON}" | jq -r '.choices[0].message.content // empty' 2>/dev/null)"
LINE="${LINE//$'\n'/ }"
LINE="${LINE//\"/}"
LINE="${LINE# }"; LINE="${LINE% }"
[ -z "${LINE}" ] && exit 0

TS="$(date +%s)"
TMP="${BUBBLE_FILE}.tmp.$$"
printf '%s\t%s\n' "${TS}" "${LINE}" > "${TMP}" 2>/dev/null && mv -f "${TMP}" "${BUBBLE_FILE}" 2>/dev/null
echo "${TS}" > "${LAST_TICK_FILE}"    2>/dev/null
echo "${TS}" > "${LAST_OK_FILE_GLM}"  2>/dev/null

if [ "${DESK_WAIFU_DEBUG:-0}" = "1" ]; then
  printf '[%s] trig=%s ev=%s err=%s tool=%s -> %s\n' \
    "$(date '+%H:%M:%S')" "${TRIGGER}" "${N_EVENTS}" "${N_ERRORS}" "${TOP_TOOL}" "${LINE}" >> "${LOG_FILE}" 2>/dev/null
  tail -n 200 "${LOG_FILE}" > "${LOG_FILE}.trim" 2>/dev/null && mv -f "${LOG_FILE}.trim" "${LOG_FILE}" 2>/dev/null
fi

exit 0
