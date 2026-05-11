#!/usr/bin/env bash
# desk-waifu remote-forward
# 旁路: 把 state / bubble 事件转发到云端 hub POST /events。
# 设计原则:
#   - 未配 ~/.desk-waifu/remote.env 时静默 exit 0
#   - curl --max-time 3 + fork 到后台, 绝不阻塞主 hook
#   - 单文件 mkdir lock 保证多 hook 并发生成 instance_id 时不重复
#   - stderr 全丢; debug 模式下落 ~/.desk-waifu/remote-forward.log
#
# 输入: stdin 一行 JSON, 形如 {"agent":"claude-code","type":"state","value":"coding"}

set -u
DATA_DIR="${HOME}/.desk-waifu"
ENV_FILE="${DATA_DIR}/remote.env"
INST_DIR="${DATA_DIR}/instances"
LOG_FILE="${DATA_DIR}/remote-forward.log"

# 没配凭证 → 整条逻辑沉默, 这是核心可选语义
[ -f "${ENV_FILE}" ] || exit 0

# shellcheck disable=SC1090
. "${ENV_FILE}" 2>/dev/null
: "${HUB_URL:=}"; : "${API_KEY:=}"
[ -n "${HUB_URL}" ] && [ -n "${API_KEY}" ] || exit 0

command -v curl >/dev/null 2>&1 || exit 0
command -v jq   >/dev/null 2>&1 || exit 0

mkdir -p "${INST_DIR}" 2>/dev/null

PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "${PAYLOAD}" ] && exit 0

AGENT="$(printf '%s' "${PAYLOAD}" | jq -r '.agent // empty' 2>/dev/null)"
TYPE="$(printf  '%s' "${PAYLOAD}" | jq -r '.type  // empty' 2>/dev/null)"
VALUE="$(printf '%s' "${PAYLOAD}" | jq -r '.value // empty' 2>/dev/null)"

[ -n "${AGENT}" ] && [ -n "${TYPE}" ] || exit 0

# 取 / 生成 instance_id, 用 mkdir 做并发锁 (POSIX 原子)
INST_FILE="${INST_DIR}/${AGENT}.id"
if [ ! -f "${INST_FILE}" ]; then
  LOCK_DIR="${INST_DIR}/.${AGENT}.lock"
  acquired=0
  i=0
  while [ "${i}" -lt 20 ]; do
    if mkdir "${LOCK_DIR}" 2>/dev/null; then
      acquired=1
      break
    fi
    # 别的进程已经在生成, 等等再读
    if [ -f "${INST_FILE}" ]; then
      break
    fi
    sleep 0.05 2>/dev/null || sleep 1
    i=$((i+1))
  done

  if [ "${acquired}" -eq 1 ] && [ ! -f "${INST_FILE}" ]; then
    if command -v uuidgen >/dev/null 2>&1; then
      NEW_ID="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"
    else
      NEW_ID="${AGENT}-$(date +%s)-$$"
    fi
    printf '%s\n' "${NEW_ID}" > "${INST_FILE}.tmp.$$" 2>/dev/null \
      && mv -f "${INST_FILE}.tmp.$$" "${INST_FILE}" 2>/dev/null
  fi
  [ "${acquired}" -eq 1 ] && rmdir "${LOCK_DIR}" 2>/dev/null
fi

INST="$(cat "${INST_FILE}" 2>/dev/null | head -1)"
[ -n "${INST}" ] || exit 0

# X-Client-Id 做幂等
if command -v uuidgen >/dev/null 2>&1; then
  CID="$(uuidgen 2>/dev/null | tr 'A-Z' 'a-z')"
else
  CID="${INST}-$(date +%s%N 2>/dev/null || date +%s)-$$"
fi

# 毫秒精度时间戳 (server 端按 ms 比较 Date.now())。
# 优先级: GNU date %3N (gnu-coreutils) > python3 > perl > 秒*1000 兜底
if TS_NOW="$(date +%s%3N 2>/dev/null)" && [ "${TS_NOW}" -gt 1000000000000 ] 2>/dev/null; then
  : # GNU date 在 mac 上一般是 gdate, 本地原生 BSD date 不支持 %3N 会返回带 'N' 的串
elif command -v python3 >/dev/null 2>&1; then
  TS_NOW="$(python3 -c 'import time;print(int(time.time()*1000))' 2>/dev/null)"
elif command -v perl >/dev/null 2>&1; then
  TS_NOW="$(perl -MTime::HiRes -e 'printf("%d", Time::HiRes::time()*1000)' 2>/dev/null)"
else
  TS_NOW="$(($(date +%s) * 1000))"
fi
BODY="$(jq -nc \
  --arg agent    "${AGENT}" \
  --arg instance "${INST}" \
  --arg type     "${TYPE}" \
  --arg value    "${VALUE}" \
  --argjson ts   "${TS_NOW}" \
  '{agent:$agent, instance:$instance, type:$type, value:$value, ts:$ts}')"

URL="${HUB_URL%/}/events"

# fork 到后台 + max-time 3s + stderr 全丢; debug 模式下捕获输出到日志
if [ "${DESK_WAIFU_DEBUG:-0}" = "1" ]; then
  (
    OUT="$(curl -sS -w 'HTTP %{http_code} in %{time_total}s' --max-time 3 \
      -X POST "${URL}" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Client-Id: ${CID}" \
      -H "Content-Type: application/json" \
      -d "${BODY}" -o /dev/null 2>&1)"
    printf '[%s] agent=%s type=%s value=%s -> %s\n' \
      "$(date '+%H:%M:%S')" "${AGENT}" "${TYPE}" "${VALUE}" "${OUT}" \
      >> "${LOG_FILE}" 2>/dev/null
    if [ -f "${LOG_FILE}" ]; then
      tail -n 200 "${LOG_FILE}" > "${LOG_FILE}.trim" 2>/dev/null \
        && mv -f "${LOG_FILE}.trim" "${LOG_FILE}" 2>/dev/null
    fi
  ) >/dev/null 2>&1 &
else
  ( curl -fsS --max-time 3 \
      -X POST "${URL}" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Client-Id: ${CID}" \
      -H "Content-Type: application/json" \
      -d "${BODY}" >/dev/null 2>&1 ) &
fi

exit 0
