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
# grapheme-safe 截断: 按 unicode 字符数 (非字节) 切, 末尾追加 …。
# 用 python3 (macOS 自带), 编码处理直接, 不会双重编码。
# fallback: 没 python3 就退到字节截断 (老行为, 可能出乱码但不阻塞)。
short() {
  local s n
  s="$(printf '%s' "$1" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ *//; s/ *$//')"
  n="${2:-60}"
  if command -v python3 >/dev/null 2>&1; then
    python3 -c '
import sys
s, n = sys.argv[1], int(sys.argv[2])
sys.stdout.write(s if len(s) <= n else s[:n] + "…")
' "$s" "$n" 2>/dev/null
  else
    printf '%s' "$s" | head -c "$n"
  fi
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
      # HUD: 一行短摘要 (grapheme-safe), 出现在右下气泡流水
      LINE="💬 $(short "${P}" 40)"
      # TASK: 写完整 prompt 不截断 (PRD §4.5: 用户输入永不截断, 自动撑高).
      #       Lua 端 user_canvas 自动按 max_w 换行多行展示.
      # 把 prompt 中可能的换行折成空格, 避免破坏 ts\ttext 单行格式.
      P_CLEAN="$(printf '%s' "${P}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ *//; s/ *$//')"
      TS_PIN="$(date +%s%N 2>/dev/null || date +%s)"
      TMP_T="${TASK_FILE}.tmp.$$"
      printf '%s\t%s\n' "${TS_PIN}" "${P_CLEAN}" > "${TMP_T}" 2>/dev/null && mv -f "${TMP_T}" "${TASK_FILE}" 2>/dev/null
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
    # 前导 \1 (SOH) 是 sticky 标记: Lua 端识别后不启动 fade_timer (PRD §4.7).
    LINE="$(printf '\1')🔔 $(short "${M}" 80)"
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
