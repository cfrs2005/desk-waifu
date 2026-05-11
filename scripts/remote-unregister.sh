#!/usr/bin/env bash
# desk-waifu remote-unregister
# 只清本地 remote.env 和 instances/, 不调云端删账号 (首版不暴露 delete API)。

set -u
DATA_DIR="${HOME}/.desk-waifu"
ENV_FILE="${DATA_DIR}/remote.env"
INST_DIR="${DATA_DIR}/instances"

info() { printf '  %s\n' "$*"; }
ok()   { printf '\033[32mok:\033[0m %s\n' "$*"; }

removed=0
if [ -f "${ENV_FILE}" ]; then
  rm -f "${ENV_FILE}" && { ok "已删除 ${ENV_FILE}"; removed=1; }
fi
if [ -d "${INST_DIR}" ]; then
  rm -rf "${INST_DIR}" && { ok "已删除 ${INST_DIR}/"; removed=1; }
fi

if [ "${removed}" -eq 0 ]; then
  info "没有本地云端凭证可删 (未注册过)"
fi

cat <<EOF

提醒: 这只是本地脱钩, 云端账号仍在 hub 上保留。
重新接入跑:
  $(dirname "$0")/remote-register.sh <hub_url> <username>
EOF
