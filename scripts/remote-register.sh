#!/usr/bin/env bash
# desk-waifu remote-register
# 在云端 hub 注册一个 desk-waifu 账户, 拿回 api_key 落到 ~/.desk-waifu/remote.env。
# 用法: ./scripts/remote-register.sh <hub_url> <username>
# 例:   ./scripts/remote-register.sh https://desk.example.com zhangqy

set -u
DATA_DIR="${HOME}/.desk-waifu"
ENV_FILE="${DATA_DIR}/remote.env"
INST_DIR="${DATA_DIR}/instances"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32mok:\033[0m %s\n' "$*"; }

usage() {
  cat <<EOF
用法: $0 <hub_url> <username>

  <hub_url>   云端 hub 根地址, 例 https://desk.example.com
  <username>  3-32 字符, 仅含 [a-z0-9_-]

注册成功后会把凭证写到 ${ENV_FILE} (mode 600)。
EOF
}

[ $# -eq 2 ] || { usage; exit 1; }

HUB_URL="$1"
USERNAME="$2"

# 校验 username
if ! printf '%s' "${USERNAME}" | grep -Eq '^[a-z0-9_-]{3,32}$'; then
  err "username 必须是 3-32 个字符且只含 [a-z0-9_-]: ${USERNAME}"
  exit 1
fi

# 校验依赖
command -v curl >/dev/null 2>&1 || { err "需要 curl"; exit 1; }
command -v jq   >/dev/null 2>&1 || { err "需要 jq (brew install jq)"; exit 1; }

# 已注册过则拒绝
if [ -f "${ENV_FILE}" ]; then
  err "${ENV_FILE} 已存在, 先 mv 备份再执行:"
  echo "  mv ${ENV_FILE} ${ENV_FILE}.bak.\$(date +%s)"
  exit 1
fi

mkdir -p "${DATA_DIR}" "${INST_DIR}" 2>/dev/null

# 规整 HUB_URL: 去掉末尾斜杠
HUB_URL="${HUB_URL%/}"

bold "向 ${HUB_URL} 注册用户 ${USERNAME}..."

RESP="$(curl -fsS --max-time 15 \
  -X POST "${HUB_URL}/register" \
  -H "Content-Type: application/json" \
  -d "$(jq -nc --arg u "${USERNAME}" '{username:$u}')" 2>&1)" || {
  err "注册失败 (curl): ${RESP}"
  exit 1
}

API_KEY="$(printf '%s' "${RESP}" | jq -r '.api_key // empty' 2>/dev/null)"
SRV_USER="$(printf '%s' "${RESP}" | jq -r '.username // empty' 2>/dev/null)"

if [ -z "${API_KEY}" ] || [ -z "${SRV_USER}" ]; then
  err "服务端响应缺字段, 原文:"
  echo "${RESP}"
  exit 1
fi

# 写 env (先写后 chmod, 保证不会有窗口期暴露 key)
umask 077
cat > "${ENV_FILE}" <<EOF
# desk-waifu 云端 hub 凭证 - mode 600, 别提交到 git
HUB_URL=${HUB_URL}
USERNAME=${SRV_USER}
API_KEY=${API_KEY}
EOF
chmod 600 "${ENV_FILE}"

ok "凭证已落到 ${ENV_FILE} (mode 600)"
ok "实例目录 ${INST_DIR}/ 已就绪"

# ── 顺手把 GIF 也同步过去, 让 "注册" 一条龙 ──────────────────────────
# 跳过条件:
#   --no-sync  flag (兼容旧脚本, 想分两步的人)
#   ~/.desk-waifu/gifs/ 不存在 (install.sh 还没跑)
SYNC_SH="$(cd "$(dirname "$0")" && pwd)/remote-sync.sh"
SKIP_SYNC=0
for arg in "$@"; do
  case "$arg" in --no-sync) SKIP_SYNC=1 ;; esac
done

if [ "${SKIP_SYNC}" = "1" ]; then
  info ""
  info "已传 --no-sync, 跳过 GIF 同步。手动跑: ${SYNC_SH}"
elif [ ! -d "${DATA_DIR}/gifs" ] || [ -z "$(ls -A "${DATA_DIR}/gifs" 2>/dev/null)" ]; then
  info ""
  info "未发现 ${DATA_DIR}/gifs/ (install.sh 没跑过?) — 跳过 GIF 同步。"
  info "  后续装好 desk-waifu 本体后跑: ${SYNC_SH}"
elif [ ! -x "${SYNC_SH}" ]; then
  info ""
  info "找不到 remote-sync.sh 或不可执行 — 跳过 GIF 同步。"
else
  echo
  bold "顺手同步 9 张 GIF 到 hub..."
  "${SYNC_SH}" || info "(同步出错, 不致命; 稍后可重跑 ${SYNC_SH})"
fi

cat <<EOF

完成。后续 Claude Code / Hermes 触发的 state / bubble / hud 事件
会自动旁路上报到 ${HUB_URL}。浏览器打开 ${HUB_URL%/}/ 就能看到
@${SRV_USER} 工位活起来。

未配 remote.env 时整条逻辑沉默, 不影响本地体验。
EOF
