#!/usr/bin/env bash
# desk-waifu journal stats — quantify hook traffic so we can pick
# which moments deserve a tip without spamming.
#
# Usage:
#   ./scripts/journal-stats.sh                     # all data
#   ./scripts/journal-stats.sh 60                  # last 60 minutes
#   JOURNAL=/path/to/journal.ndjson ./scripts/...  # alternate file

set -u
: "${JOURNAL:=${HOME}/.desk-waifu/journal.ndjson}"

if [ ! -f "${JOURNAL}" ]; then
  echo "no journal at ${JOURNAL}" >&2; exit 1
fi
command -v jq >/dev/null || { echo "need jq" >&2; exit 1; }

WINDOW_MIN="${1:-0}"  # 0 = all
NOW="$(date +%s)"
SINCE=0
[ "${WINDOW_MIN}" -gt 0 ] && SINCE=$(( NOW - WINDOW_MIN * 60 ))

# Filter window into a temp slice to avoid re-parsing
SLICE="$(mktemp)"; trap 'rm -f "${SLICE}"' EXIT
jq -c --argjson since "${SINCE}" 'select(.ts >= $since)' "${JOURNAL}" > "${SLICE}"

TOTAL="$(wc -l < "${SLICE}" | tr -d ' ')"
if [ "${TOTAL}" = "0" ]; then
  echo "no events in window"; exit 0
fi

FIRST_TS="$(head -1 "${SLICE}" | jq -r '.ts')"
LAST_TS="$( tail -1 "${SLICE}" | jq -r '.ts')"
SPAN=$(( LAST_TS - FIRST_TS ))
SPAN_MIN=$(awk -v s="${SPAN}" 'BEGIN{printf "%.1f", s/60}')

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
hr()   { printf '%s\n' '──────────────────────────────────────────────'; }

bold "desk-waifu journal stats"
echo "file:    ${JOURNAL}"
echo "window:  ${WINDOW_MIN}min ($([ ${WINDOW_MIN} -eq 0 ] && echo all))"
echo "events:  ${TOTAL}"
echo "span:    ${SPAN}s (${SPAN_MIN} min)"
if [ "${SPAN}" -gt 0 ]; then
  RATE=$(awk -v t="${TOTAL}" -v s="${SPAN}" 'BEGIN{printf "%.2f", t/(s/60)}')
  echo "rate:    ${RATE} events/min"
fi

hr; bold "1. 各 hook 事件分布"
jq -r '.event // "?"' "${SLICE}" | sort | uniq -c | sort -rn | \
  awk -v t="${TOTAL}" '{ printf "  %-22s %5d  %5.1f%%\n", $2, $1, $1*100/t }'

hr; bold "2. 工具 top 10 (PreToolUse + PostToolUse)"
jq -r 'select(.event=="PreToolUse" or .event=="PostToolUse") | .tool // "?"' "${SLICE}" \
  | sort | uniq -c | sort -rn | head -10 | \
  awk '{ printf "  %-22s %5d\n", $2, $1 }'

hr; bold "3. 错误事件 (exit ≠ 0)"
ERR_COUNT=$(jq -c 'select(.exit != null and .exit != 0)' "${SLICE}" | wc -l | tr -d ' ')
echo "  total errors: ${ERR_COUNT}"
if [ "${ERR_COUNT}" -gt 0 ]; then
  echo "  by tool:"
  jq -r 'select(.exit != null and .exit != 0) | .tool // "?"' "${SLICE}" \
    | sort | uniq -c | sort -rn | awk '{ printf "    %-20s %3d\n", $2, $1 }'
fi

hr; bold "4. 事件间隔 (相邻事件的时差，秒)"
jq -s 'sort_by(.ts)
       | . as $arr
       | [ range(1; length) | ($arr[.].ts - $arr[.-1].ts) | select(. >= 0) ]
       | (sort) as $sorted
       | { p50: $sorted[($sorted|length/2|floor)],
           p90: $sorted[($sorted|length*9/10|floor)],
           p99: $sorted[($sorted|length*99/100|floor)],
           max: ($sorted | max // 0) }' "${SLICE}" \
  | jq -r '"  p50=\(.p50)s  p90=\(.p90)s  p99=\(.p99)s  max=\(.max)s"'

hr; bold "5. 假设触发 GLM 的成本估算"
echo "  (基于当前数据的事件率推算每小时 GLM 调用次数)"
for e in UserPromptSubmit Stop Notification PostToolUse-err PreToolUse PostToolUse; do
  case "${e}" in
    PostToolUse-err)
      N=$(jq -c 'select(.event=="PostToolUse" and .exit != null and .exit != 0)' "${SLICE}" | wc -l | tr -d ' ');;
    *)
      N=$(jq -c --arg e "${e}" 'select(.event==$e)' "${SLICE}" | wc -l | tr -d ' ');;
  esac
  if [ "${SPAN}" -gt 0 ] && [ "${N}" -gt 0 ]; then
    PER_H=$(awk -v n="${N}" -v s="${SPAN}" 'BEGIN{printf "%.1f", n*3600/s}')
    printf "  %-22s %5d 次  → %s 次/小时\n" "${e}" "${N}" "${PER_H}"
  else
    printf "  %-22s %5d 次  → n/a\n" "${e}" "${N}"
  fi
done

hr; bold "6. 静默期 (idle gap >= 60s)"
QUIET=$(jq -s 'sort_by(.ts) | . as $arr
              | [ range(1; length) | ($arr[.].ts - $arr[.-1].ts) | select(. >= 60) ]
              | length' "${SLICE}")
echo "  ≥60s 静默次数: ${QUIET}"

hr; bold "7. 每个 tool 在 journal 中可见的字段（HUD 翻译参考）"
echo "  (按 tool 分组，列出 journal 已记录的非空字段)"
jq -r 'select(.event=="PreToolUse" or .event=="PostToolUse")
       | .tool as $t
       | [ ($t // "?"),
           (if .cmd  then "cmd"  else empty end),
           (if .path then "path" else empty end),
           (if .exit != null then "exit" else empty end)
         ] | @tsv' "${SLICE}" \
  | awk -F'\t' '
      { tool=$1; for (i=2;i<=NF;i++) if ($i!="") seen[tool"|"$i]++ }
      END {
        for (k in seen) {
          split(k, a, "|")
          if (!totals[a[1]]) totals[a[1]] = 0
          totals[a[1]] += seen[k]
          fields[a[1]] = (fields[a[1]] ? fields[a[1]] "," : "") a[2] "(" seen[k] ")"
        }
        for (t in fields) printf "  %-20s %s\n", t, fields[t]
      }' | sort

hr; bold "8. journal 没记录但 hook payload 里可能有的关键字段"
cat <<'EOT'
  (这些字段需要从原始 payload 取，HUD/分析器若想用得在 hud-writer 里取)
    Edit/Write/Read   → tool_input.file_path
    MultiEdit         → tool_input.file_path, tool_input.edits[]
    Bash              → tool_input.command, tool_input.description
    Glob/Grep         → tool_input.pattern, tool_input.path
    Task              → tool_input.description, tool_input.subagent_type
    TodoWrite         → tool_input.todos[]
    WebFetch/Search   → tool_input.url / tool_input.query
    Notification      → message
    UserPromptSubmit  → prompt
    PostToolUse       → tool_response (string/obj，含 exit_code / stderr / stdout)
EOT

hr
echo "tip：免费档 GLM 大约每分钟限速 ~15 次。建议把'每小时 GLM 调用次数'控制在 200 以内（>3/分钟会被偶发限流）。"
echo "tip：HUD 通道纯本地零成本，对每个 Pre/PostToolUse 事件都展示一条 ~800ms。"
