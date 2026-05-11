#!/usr/bin/env bash
# desk-waifu hud-writer
# 把任意 Claude Code hook payload 翻译成一行事实，写到 ~/.desk-waifu/hud
# 纯 jq + bash，无网络，无 GLM，<10ms 完成。永不阻塞 Claude Code。

set -u
DATA_DIR="${HOME}/.desk-waifu"
HUD_FILE="${DATA_DIR}/hud"
TASK_FILE="${DATA_DIR}/task"
LOG_FILE="${DATA_DIR}/hud.log"
PROSE_HASH_FILE="${DATA_DIR}/.last-prose-hash"

mkdir -p "${DATA_DIR}" 2>/dev/null || exit 0
command -v jq >/dev/null 2>&1 || exit 0

PAYLOAD="$(cat 2>/dev/null || true)"
[ -z "${PAYLOAD}" ] && exit 0

get() { printf '%s' "${PAYLOAD}" | jq -r "$1 // empty" 2>/dev/null; }

# 从 transcript_path 反向扫到最近一个 assistant text 块。
# Claude Code 把 thinking / text / tool_use 切成三种 JSONL 行，
# 每行是一个 content block；取 type==assistant 且 message.content[].type==text 的最后一条。
last_assistant_prose() {
  local tp="$1"
  [ -z "${tp}" ] || [ ! -f "${tp}" ] && return
  jq -rs '
    map(select(.type == "assistant"))
    | map(.message.content[]? | select(.type == "text") | .text)
    | last // empty
  ' "${tp}" 2>/dev/null
}
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
TX="$(  get '.transcript_path')"

# ── 散文优先：如果转录里有新 prose 就直接拿来当 HUD ────────────────
# 命中分支: PreToolUse / PostToolUse / Stop. 其它 (UserPromptSubmit / Notification /
# SessionStart) 仍走各自原本的特殊逻辑, 不被散文劫持.
case "${EVENT}" in
  PreToolUse|PostToolUse|Stop)
    if [ -n "${TX}" ]; then
      PROSE="$(last_assistant_prose "${TX}")"
      if [ -n "${PROSE}" ] && [ "${PROSE}" != "null" ]; then
        # 去 markdown 噪音 (** _ `): 视觉减负, 不动语义
        PROSE_CLEAN="$(printf '%s' "${PROSE}" | sed -E 's/\*\*//g; s/`//g' | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ *//; s/ *$//')"
        # 60 字符（含中英文字符）, 头部最有信息密度
        PROSE_SHORT="$(short "${PROSE_CLEAN}" 60)"
        # 取整段 prose 的 md5 哈希做 dedup —— 不是截短后的, 防"前 60 字相同 + 后续不同"漏推
        PROSE_HASH="$(printf '%s' "${PROSE_CLEAN}" | md5)"
        LAST_HASH="$(cat "${PROSE_HASH_FILE}" 2>/dev/null || echo "")"
        if [ "${PROSE_HASH}" != "${LAST_HASH}" ]; then
          LINE="💬 ${PROSE_SHORT}"
          printf '%s' "${PROSE_HASH}" > "${PROSE_HASH_FILE}" 2>/dev/null
          TS="$(date +%s%N 2>/dev/null || date +%s)"
          TMP="${HUD_FILE}.tmp.$$"
          printf '%s\t%s\n' "${TS}" "${LINE}" > "${TMP}" 2>/dev/null && mv -f "${TMP}" "${HUD_FILE}" 2>/dev/null
          if [ "${DESK_WAIFU_DEBUG:-0}" = "1" ]; then
            printf '[%s] %-18s -> (prose) %s\n' "$(date '+%H:%M:%S')" "${EVENT}/${TOOL:-?}" "${LINE}" >> "${LOG_FILE}" 2>/dev/null
          fi
          exit 0
        fi
        # 散文没变 → 继续走下面的工具活动分支
      fi
    fi
    ;;
esac

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
    # 用户输入只走 task (蓝色 user 气泡); 不再写 HUD —— 灰色气泡回显用户原文是冗余信息.
    P="$(get '.prompt // .user_prompt')"
    if [ -n "${P}" ]; then
      P_CLEAN="$(printf '%s' "${P}" | tr '\n' ' ' | sed -E 's/[[:space:]]+/ /g; s/^ *//; s/ *$//')"
      TS_PIN="$(date +%s%N 2>/dev/null || date +%s)"
      TMP_T="${TASK_FILE}.tmp.$$"
      printf '%s\t%s\n' "${TS_PIN}" "${P_CLEAN}" > "${TMP_T}" 2>/dev/null && mv -f "${TMP_T}" "${TASK_FILE}" 2>/dev/null
    fi
    exit 0
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
    # CC 的 Notification message 通常是 "Claude Code needs your attention" 这种泛泛通知,
    # 信息含量低, 不值得 sticky. 让它走正常 8s fade —— 主人看一眼就够.
    M="$(get '.message')"
    LINE="🔔 $(short "${M}" 80)"
    ;;
  Stop)
    # Z 时代版收工台词. RANDOM 范围 0-32767, % 6 简单选一句.
    POOL=("✓ 妥了" "✓ ohhh完事" "✓ 整完啦" "✓ 搞定~" "✓ 这就完了" "✓ 收工")
    LINE="${POOL[$((RANDOM % ${#POOL[@]}))]}"
    # 一轮结束, 清掉任务 pin (写空文件触发 pathwatcher)
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
