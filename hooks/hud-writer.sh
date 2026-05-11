#!/usr/bin/env bash
# desk-waifu hud-writer
# 把任意 Claude Code hook payload 翻译成一行事实，写到 ~/.desk-waifu/hud
# 纯 jq + bash，无网络，无 GLM，<10ms 完成。永不阻塞 Claude Code。

set -u
DATA_DIR="${HOME}/.desk-waifu"
HUD_FILE="${DATA_DIR}/hud"
TASK_FILE="${DATA_DIR}/task"
LOG_FILE="${DATA_DIR}/hud.log"

mkdir -p "${DATA_DIR}" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "${PAYLOAD}" ] && exit 0

get() { printf '%s' "${PAYLOAD}" | jq -r "$1 // empty" 2>/dev/null; }
short() {
  local s="$1" n="${2:-60}"
  printf '%s' "${s}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ *//; s/ *$//' | head -c "${n}"
}
basenm() {
  local p="$1"
  [ -z "${p}" ] && return
  printf '%s' "${p##*/}"
}

EVENT="$(get '.hook_event_name')"
TOOL="$( get '.tool_name')"
EXIT="$( get '.tool_response.exit_code // .tool_response_exit_code')"

# ── 工具静默名单 (config.hud_mute) ─────────────────────────────
# 默认 mute: Edit/MultiEdit/TodoWrite/TaskCreate/TaskUpdate
#   - Edit/MultiEdit:  ~40% 事件占比，文件名信号弱，太刷屏
#   - TodoWrite:       内部待办，看不到具体内容
#   - TaskCreate/Update: 任务编排 churn，无业务价值
# 用户在 ~/.desk-waifu/config.json 里加 "hud_mute":[...] 可覆盖；
# 设成 [] 显示所有，加更多名字进一步静默。
CONFIG_FILE="${DATA_DIR}/config.json"
DEFAULT_MUTE='["Edit","MultiEdit","TodoWrite","TaskCreate","TaskUpdate"]'
MUTED="$(jq -r --argjson def "${DEFAULT_MUTE}" '
  (.hud_mute // $def) | .[]
' "${CONFIG_FILE}" 2>/dev/null || printf 'Edit\nMultiEdit\nTodoWrite\nTaskCreate\nTaskUpdate\n')"

if [ -n "${TOOL}" ] && [ "${EVENT}" = "PreToolUse" ]; then
  if printf '%s\n' "${MUTED}" | grep -Fxq "${TOOL}"; then
    if [ "${DESK_WAIFU_DEBUG:-0}" = "1" ]; then
      printf '[%s] %-18s -> (muted)\n' "$(date '+%H:%M:%S')" "${EVENT}/${TOOL}" >> "${LOG_FILE}" 2>/dev/null
    fi
    exit 0
  fi
fi

LINE=""
case "${EVENT}" in
  UserPromptSubmit)
    P="$(get '.prompt // .user_prompt')"
    if [ -n "${P}" ]; then
      LINE="💬 $(short "${P}" 80)"
      # 同时写到 task pin，持续挂在 bubble 顶部直到 Stop / 下一次 UserPromptSubmit
      TS_PIN="$(date +%s%N 2>/dev/null || date +%s)"
      TMP_T="${TASK_FILE}.tmp.$$"
      printf '%s\t%s\n' "${TS_PIN}" "${LINE}" > "${TMP_T}" 2>/dev/null && mv -f "${TMP_T}" "${TASK_FILE}" 2>/dev/null
    fi
    ;;
  PreToolUse)
    case "${TOOL}" in
      Edit|MultiEdit|NotebookEdit)
        P="$(get '.tool_input.file_path // .tool_input.notebook_path')"
        LINE="✏️  Edit · $(basenm "${P}")"
        ;;
      Write)
        P="$(get '.tool_input.file_path')"
        LINE="📝 Write · $(basenm "${P}")"
        ;;
      Read)
        P="$(get '.tool_input.file_path')"
        LINE="👁  Read · $(basenm "${P}")"
        ;;
      Glob)
        Q="$(get '.tool_input.pattern')"
        LINE="🔍 Glob · $(short "${Q}" 50)"
        ;;
      Grep)
        Q="$(get '.tool_input.pattern')"
        LINE="🔎 Grep · $(short "${Q}" 50)"
        ;;
      LS)
        P="$(get '.tool_input.path')"
        LINE="📂 LS · $(basenm "${P}")"
        ;;
      Bash)
        C="$(get '.tool_input.command')"
        LINE="\$ $(short "${C}" 70)"
        ;;
      Task)
        D="$(get '.tool_input.description // .tool_input.subagent_type // .tool_input.prompt')"
        LINE="→ Task · $(short "${D}" 60)"
        ;;
      TodoWrite)
        N="$(printf '%s' "${PAYLOAD}" | jq -r '.tool_input.todos | length // 0' 2>/dev/null)"
        LINE="📋 Todo · ${N:-0} 条"
        ;;
      WebFetch)
        U="$(get '.tool_input.url')"
        LINE="🌐 Fetch · $(short "${U}" 60)"
        ;;
      WebSearch)
        Q="$(get '.tool_input.query')"
        LINE="🔭 Search · $(short "${Q}" 60)"
        ;;
      AskUserQuestion)
        LINE="❓ 等主人决定"
        ;;
      ExitPlanMode)
        LINE="🗺  退出计划模式"
        ;;
      *)
        LINE="• ${TOOL}"
        ;;
    esac
    ;;
  PostToolUse)
    # 成功的 PostTool 太密，跳过；只显示失败
    if [ -n "${EXIT}" ] && [ "${EXIT}" != "0" ]; then
      LINE="❌ ${TOOL} exit=${EXIT}"
    else
      exit 0
    fi
    ;;
  Notification)
    M="$(get '.message')"
    LINE="🔔 $(short "${M}" 80)"
    ;;
  Stop)
    LINE="✓ 回合结束"
    # 一轮结束，清掉任务 pin（写空文件触发 pathwatcher）
    : > "${TASK_FILE}" 2>/dev/null
    ;;
  SubagentStop)
    LINE="✓ 子代理收工"
    ;;
  SessionStart)
    LINE="🌅 新会话"
    ;;
  *)
    exit 0
    ;;
esac

[ -z "${LINE}" ] && exit 0

# 纳秒级 ts 保证 pathwatcher 即便 1s 内连发多次也每次都看到新内容
TS="$(date +%s%N 2>/dev/null || date +%s)"
TMP="${HUD_FILE}.tmp.$$"
printf '%s\t%s\n' "${TS}" "${LINE}" > "${TMP}" 2>/dev/null && mv -f "${TMP}" "${HUD_FILE}" 2>/dev/null

if [ "${DESK_WAIFU_DEBUG:-0}" = "1" ]; then
  printf '[%s] %-18s -> %s\n' "$(date '+%H:%M:%S')" "${EVENT}/${TOOL:-?}" "${LINE}" >> "${LOG_FILE}" 2>/dev/null
  tail -n 300 "${LOG_FILE}" > "${LOG_FILE}.trim" 2>/dev/null && mv -f "${LOG_FILE}.trim" "${LOG_FILE}" 2>/dev/null
fi

exit 0
