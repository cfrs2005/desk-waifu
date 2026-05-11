#!/usr/bin/env bash
# desk-waifu installer — idempotent, safe to re-run.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DATA_DIR="${HOME}/.desk-waifu"
HS_DIR="${HOME}/.hammerspoon"
CLAUDE_DIR="${HOME}/.claude"
SETTINGS_FILE="${CLAUDE_DIR}/settings.json"
SNIPPET_FILE="${REPO_ROOT}/hooks/settings-snippet.json"
LUA_NAME="desk-waifu.lua"
LUA_SRC="${REPO_ROOT}/hammerspoon/${LUA_NAME}"
HOOK_SRC="${REPO_ROOT}/hooks/state-writer.sh"
BUBBLE_SRC="${REPO_ROOT}/hooks/bubble-writer.sh"
GIFS_SRC="${REPO_ROOT}/assets/gifs"
HERMES_HOOK_SRC="${REPO_ROOT}/hooks/hermes"
HERMES_HOOKS_DIR="${HOME}/.hermes/hooks"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32mok:\033[0m %s\n' "$*"; }

bold "desk-waifu installer"

# --- Dependency checks ----------------------------------------------------
if [ ! -d "/Applications/Hammerspoon.app" ]; then
  err "Hammerspoon not found in /Applications."
  cat <<EOF
Install with:
  brew install --cask hammerspoon
Then launch Hammerspoon once and grant Accessibility permission, then re-run this installer.
EOF
  exit 1
fi
ok "Hammerspoon found"

if ! command -v jq >/dev/null 2>&1; then
  err "jq is required to merge Claude Code hook settings safely."
  echo "Install with: brew install jq"
  exit 1
fi
ok "jq found"

# --- Stage 1: data dir + GIFs --------------------------------------------
mkdir -p "${DATA_DIR}/gifs"
cp -f "${GIFS_SRC}"/*.gif "${DATA_DIR}/gifs/"
info "GIFs copied to ${DATA_DIR}/gifs/"

# initial state
[ -f "${DATA_DIR}/state" ] || echo "idle_blink" > "${DATA_DIR}/state"

# --- Stage 2: hook script -------------------------------------------------
cp -f "${HOOK_SRC}" "${DATA_DIR}/state-writer.sh"
chmod +x "${DATA_DIR}/state-writer.sh"
info "Hook installed at ${DATA_DIR}/state-writer.sh"

if [ -f "${BUBBLE_SRC}" ]; then
  cp -f "${BUBBLE_SRC}" "${DATA_DIR}/bubble-writer.sh"
  chmod +x "${DATA_DIR}/bubble-writer.sh"
  info "Bubble writer installed at ${DATA_DIR}/bubble-writer.sh"
  if [ ! -f "${DATA_DIR}/glm.env" ]; then
    cat > "${DATA_DIR}/glm.env.example" <<'EOF'
# desk-waifu bubble narrator credentials. Copy to glm.env and fill in.
# chmod 600 ~/.desk-waifu/glm.env after editing.
GLM_API_KEY=your-api-key-here
GLM_MODEL=GLM-4-FlashX
GLM_ENDPOINT=https://open.bigmodel.cn/api/paas/v4/chat/completions
EOF
    info "Wrote ${DATA_DIR}/glm.env.example (copy to glm.env to enable bubbles)"
  fi
fi

# --- Stage 3: Hammerspoon Lua --------------------------------------------
mkdir -p "${HS_DIR}"
cp -f "${LUA_SRC}" "${HS_DIR}/${LUA_NAME}"
info "Lua installed at ${HS_DIR}/${LUA_NAME}"

INIT_LUA="${HS_DIR}/init.lua"
touch "${INIT_LUA}"
LOAD_LINE="require('desk-waifu')"
if ! grep -F -q "${LOAD_LINE}" "${INIT_LUA}"; then
  {
    echo ""
    echo "-- desk-waifu (added by installer)"
    echo "${LOAD_LINE}"
  } >> "${INIT_LUA}"
  info "Added require('desk-waifu') to init.lua"
else
  info "init.lua already requires desk-waifu"
fi

# --- Stage 4: merge Claude Code hook settings ----------------------------
mkdir -p "${CLAUDE_DIR}"
[ -f "${SETTINGS_FILE}" ] || echo '{}' > "${SETTINGS_FILE}"

# Backup once
BAK="${SETTINGS_FILE}.bak.desk-waifu"
[ -f "${BAK}" ] || cp "${SETTINGS_FILE}" "${BAK}"
info "Backed up settings.json -> ${BAK}"

# Merge hooks. We tag every entry we add with $.hooks.*[].__desk_waifu = true so
# uninstall can remove only our own. The snippet uses literal "$HOME/..." which
# we expand here to absolute paths to avoid shell-expansion surprises.
TMP_SNIPPET="$(mktemp)"
sed "s|\$HOME|${HOME}|g" "${SNIPPET_FILE}" > "${TMP_SNIPPET}"

jq --slurpfile add "${TMP_SNIPPET}" '
  . as $base
  | ($add[0].hooks // {}) as $new
  | .hooks = (
      ($base.hooks // {}) as $cur
      | reduce ($new | keys[]) as $evt ($cur;
          .[$evt] = (
            ((.[$evt] // []) | map(select((.. | objects | .__desk_waifu? // false) | not)))
            + ([ ($new[$evt][])
                 | .hooks |= map(. + {__desk_waifu: true})
                 | . + {__desk_waifu_event: true}
               ])
          )
        )
    )
' "${SETTINGS_FILE}" > "${SETTINGS_FILE}.tmp"
mv -f "${SETTINGS_FILE}.tmp" "${SETTINGS_FILE}"
rm -f "${TMP_SNIPPET}"
info "Merged hooks into ${SETTINGS_FILE}"

# --- Stage 5: optional Hermes Agent hook ---------------------------------
# If Hermes Agent is installed (~/.hermes/hooks/ exists), drop our HOOK.yaml +
# handler.py into ~/.hermes/hooks/desk-waifu/ so Hermes's gateway picks it up
# at next launch. If Hermes isn't installed, skip silently — it's optional.
if [ -d "${HERMES_HOOKS_DIR}" ] && [ -d "${HERMES_HOOK_SRC}" ]; then
  HERMES_TARGET="${HERMES_HOOKS_DIR}/desk-waifu"
  mkdir -p "${HERMES_TARGET}"
  cp -f "${HERMES_HOOK_SRC}/HOOK.yaml"  "${HERMES_TARGET}/HOOK.yaml"
  cp -f "${HERMES_HOOK_SRC}/handler.py" "${HERMES_TARGET}/handler.py"
  info "Hermes hook installed at ${HERMES_TARGET}"
  info "  → restart Hermes gateway to load: launchctl kickstart -k gui/\$UID/ai.hermes.gateway"
else
  info "Hermes Agent not detected (no ~/.hermes/hooks/) — skipping bridge"
fi

# --- Stage 6: nudge Hammerspoon to reload --------------------------------
if [ -x "/Applications/Hammerspoon.app/Contents/Resources/extensions/hs/ipc/bin/hs" ] \
    && command -v hs >/dev/null 2>&1; then
  hs -c 'hs.reload()' >/dev/null 2>&1 || true
  info "Asked Hammerspoon to reload"
else
  cat <<EOF

Hammerspoon CLI ('hs') is not installed yet. To enable it, in Hammerspoon:
  Console → 'hs.ipc.cliInstall()'
For now, please reload manually:
  Hammerspoon menubar → Reload Config
EOF
fi

bold "done."
cat <<EOF

Test it:
  echo coding > ~/.desk-waifu/state    # waifu should switch animation
  echo idle_blink > ~/.desk-waifu/state

Hotkeys (default):
  ⌘⌥P  show / hide
  ⌘⌥;  cycle screen corner
  ⌘⌥R  reload waifu

Tail the hook log:
  DESK_WAIFU_DEBUG=1 set inside Claude Code (env), then
  tail -f ~/.desk-waifu/state-writer.log

Uninstall:
  ${REPO_ROOT}/scripts/uninstall.sh
EOF
