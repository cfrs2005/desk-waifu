#!/usr/bin/env bash
# desk-waifu uninstaller — reverses install.sh.
set -euo pipefail

DATA_DIR="${HOME}/.desk-waifu"
HS_DIR="${HOME}/.hammerspoon"
SETTINGS_FILE="${HOME}/.claude/settings.json"
HERMES_HOOK_DIR="${HOME}/.hermes/hooks/desk-waifu"
LUA_NAME="desk-waifu.lua"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }

bold "desk-waifu uninstaller"

# --- Stage 1: remove our hook entries from settings.json -----------------
if [ -f "${SETTINGS_FILE}" ] && command -v jq >/dev/null 2>&1; then
  TMP="${SETTINGS_FILE}.tmp"
  jq '
    if .hooks == null then .
    else .hooks |= with_entries(
      .value |= map(select(.__desk_waifu_event != true))
    )
    | .hooks |= with_entries(select(.value | length > 0))
    | (if (.hooks // {} | length) == 0 then del(.hooks) else . end)
    end
  ' "${SETTINGS_FILE}" > "${TMP}" && mv -f "${TMP}" "${SETTINGS_FILE}"
  info "Removed desk-waifu hook entries from settings.json"
else
  info "No settings.json (or no jq) — skipping hook cleanup"
fi

# --- Stage 2: remove Lua + init.lua reference ----------------------------
if [ -f "${HS_DIR}/${LUA_NAME}" ]; then
  rm -f "${HS_DIR}/${LUA_NAME}"
  info "Removed ${HS_DIR}/${LUA_NAME}"
fi

if [ -f "${HS_DIR}/init.lua" ]; then
  # Remove the require line and the marker comment we added (one or both)
  TMP="${HS_DIR}/init.lua.tmp"
  awk '
    /^-- desk-waifu \(added by installer\)$/ { skip=2; next }
    skip > 0 { skip--; if ($0 ~ /^require\(.desk-waifu.\)$/) next; else next }
    /^require\(.desk-waifu.\)$/ { next }
    { print }
  ' "${HS_DIR}/init.lua" > "${TMP}" && mv -f "${TMP}" "${HS_DIR}/init.lua"
  info "Cleaned init.lua"
fi

# --- Stage 2.5: remove Hermes Agent hook (if present) -------------------
if [ -d "${HERMES_HOOK_DIR}" ]; then
  rm -rf "${HERMES_HOOK_DIR}"
  info "Removed ${HERMES_HOOK_DIR}"
fi

# --- Stage 3: nuke data dir (asks first, unless --yes) -------------------
NUKE=0
for arg in "$@"; do [ "${arg}" = "--yes" ] && NUKE=1; done

if [ -d "${DATA_DIR}" ]; then
  if [ "${NUKE}" = "1" ]; then
    rm -rf "${DATA_DIR}"
    info "Removed ${DATA_DIR}"
  else
    printf "Remove %s ? [y/N] " "${DATA_DIR}"
    read -r ans
    case "${ans}" in
      y|Y|yes|YES) rm -rf "${DATA_DIR}"; info "Removed ${DATA_DIR}" ;;
      *) info "Kept ${DATA_DIR}" ;;
    esac
  fi
fi

# --- Stage 4: reload Hammerspoon if available ----------------------------
if command -v hs >/dev/null 2>&1; then
  hs -c 'hs.reload()' >/dev/null 2>&1 || true
fi

bold "done."
