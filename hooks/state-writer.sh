#!/usr/bin/env bash
# desk-waifu state-writer
# Reads Claude Code hook JSON from stdin, maps to a desk-waifu state name,
# atomically writes it to ~/.desk-waifu/state.
# Failures are silent: this hook MUST NOT block Claude Code.

set -u
DATA_DIR="${HOME}/.desk-waifu"
STATE_FILE="${DATA_DIR}/state"
LOG_FILE="${DATA_DIR}/state-writer.log"

mkdir -p "${DATA_DIR}" 2>/dev/null || exit 0

# Read all of stdin (small JSON, hook payloads are typically <4KB)
PAYLOAD="$(cat 2>/dev/null || true)"

# Append to rolling journal (ndjson) for the cognition loop.
JOURNAL="${DATA_DIR}/journal.ndjson"
if command -v jq >/dev/null 2>&1; then
  TS_NOW="$(date +%s)"
  printf '%s' "${PAYLOAD}" | jq -c --arg ts "${TS_NOW}" '{
    ts: ($ts|tonumber),
    event: .hook_event_name,
    tool: .tool_name,
    exit: (.tool_response.exit_code // .tool_response_exit_code // null),
    cmd: (.tool_input.command // null),
    path: (.tool_input.file_path // .tool_input.path // null),
    notif: .message
  }' 2>/dev/null >> "${JOURNAL}" || true
  # Keep last 256 lines
  LINES=$(wc -l < "${JOURNAL}" 2>/dev/null || echo 0)
  if [ "${LINES}" -gt 320 ]; then
    tail -n 256 "${JOURNAL}" > "${JOURNAL}.trim" 2>/dev/null && mv -f "${JOURNAL}.trim" "${JOURNAL}" 2>/dev/null
  fi
fi

# Fire-and-forget HUD writer — visualization layer for every Claude decision.
# 纯本地、零网络、几毫秒，背景跑也不阻塞。
HUD_WRITER="${DATA_DIR}/hud-writer.sh"
if [ -x "${HUD_WRITER}" ]; then
  ( printf '%s' "${PAYLOAD}" | nohup "${HUD_WRITER}" >/dev/null 2>&1 & ) >/dev/null 2>&1
fi

# Fire-and-forget bubble narrator for end-of-turn / notification / errors.
# Backgrounded so the GLM round-trip never blocks Claude Code.
BUBBLE_WRITER="${DATA_DIR}/bubble-writer.sh"
if [ -x "${BUBBLE_WRITER}" ]; then
  # GLM 只在两类「需要温度」的稀疏时刻开口，其余交给 HUD 事实化展示。
  case "${PAYLOAD}" in
    *'"hook_event_name":"Stop"'*|\
    *'"hook_event_name":"Notification"'*)
      ( printf '%s' "${PAYLOAD}" | nohup "${BUBBLE_WRITER}" >/dev/null 2>&1 & ) >/dev/null 2>&1
      ;;
  esac
fi

# Pull fields with jq if available; fall back to regex grep so we never hard-fail
get_field() {
  local key="$1"
  if command -v jq >/dev/null 2>&1; then
    printf '%s' "${PAYLOAD}" | jq -r --arg k "${key}" '.[$k] // empty' 2>/dev/null || true
  else
    printf '%s' "${PAYLOAD}" \
      | grep -oE "\"${key}\"[[:space:]]*:[[:space:]]*\"[^\"]*\"" \
      | head -1 | sed -E 's/.*:[[:space:]]*"([^"]*)".*/\1/'
  fi
}

EVENT="$(get_field hook_event_name)"
TOOL="$(get_field tool_name)"
EXIT_CODE="$(get_field tool_response_exit_code)"
# Some hook versions nest exit code under tool_response.exit_code
if [ -z "${EXIT_CODE}" ] && command -v jq >/dev/null 2>&1; then
  EXIT_CODE="$(printf '%s' "${PAYLOAD}" | jq -r '.tool_response.exit_code // empty' 2>/dev/null || true)"
fi

# Bash command (only present for Bash tool); used to refine peek vs coding
BASH_CMD=""
if command -v jq >/dev/null 2>&1; then
  BASH_CMD="$(printf '%s' "${PAYLOAD}" | jq -r '.tool_input.command // empty' 2>/dev/null || true)"
fi

map_state() {
  case "${EVENT}" in
    SessionStart|SubagentStop)
      echo "sleep"; return ;;
    Stop)
      # End of an assistant turn — celebrate. The Hammerspoon daemon will
      # auto-revert to "sleep" after ~60s unless a new turn starts first.
      echo "celebrate"; return ;;
    UserPromptSubmit)
      # User just sent a prompt — assistant is now actively working.
      echo "coding"; return ;;
    Notification)
      echo "supervise"; return ;;
    PreToolUse)
      case "${TOOL}" in
        Edit|Write|MultiEdit|NotebookEdit) echo "coding"; return ;;
        Read|Glob|Grep|LS|WebFetch|WebSearch) echo "peek"; return ;;
        TodoWrite|Task) echo "supervise"; return ;;
        Bash)
          case "${BASH_CMD}" in
            *"npm install"*|*"pnpm install"*|*"yarn install"*|*"pdm install"*|\
            *"pip install"*|*"brew install"*|*"apt-get install"*|*"cargo build"*|\
            *"go build"*|*"make"*|*"docker build"*|*"npm run build"*|*"pnpm build"*)
              echo "loading"; return ;;
            grep*|rg*|find*|ls*|cat*|head*|tail*|wc*|file*|stat*|awk*|sed\ -n*)
              echo "peek"; return ;;
            *) echo "coding"; return ;;
          esac ;;
        *) echo "coding"; return ;;
      esac ;;
    PostToolUse)
      if [ -n "${EXIT_CODE}" ] && [ "${EXIT_CODE}" != "0" ]; then
        echo "error_shrug"; return
      fi
      # Tool succeeded but the turn isn't over yet — keep coding.
      echo "coding"; return ;;
    *)
      echo "sleep"; return ;;
  esac
}

NEW_STATE="$(map_state 2>/dev/null || echo "idle_blink")"
[ -z "${NEW_STATE}" ] && NEW_STATE="idle_blink"

# Atomic write: write to .tmp then rename
TMP="${STATE_FILE}.tmp.$$"
printf '%s\n' "${NEW_STATE}" > "${TMP}" 2>/dev/null && mv -f "${TMP}" "${STATE_FILE}" 2>/dev/null

# Optional debug log (truncated to last 200 lines)
if [ "${DESK_WAIFU_DEBUG:-0}" = "1" ]; then
  {
    printf '[%s] event=%s tool=%s exit=%s cmd=%s -> %s\n' \
      "$(date '+%H:%M:%S')" "${EVENT}" "${TOOL}" "${EXIT_CODE}" "${BASH_CMD:0:60}" "${NEW_STATE}"
  } >> "${LOG_FILE}" 2>/dev/null
  if [ -f "${LOG_FILE}" ]; then
    tail -n 200 "${LOG_FILE}" > "${LOG_FILE}.trim" 2>/dev/null && mv -f "${LOG_FILE}.trim" "${LOG_FILE}" 2>/dev/null
  fi
fi

# Always succeed so we never block Claude Code
exit 0
