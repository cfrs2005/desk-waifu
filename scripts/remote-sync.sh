#!/usr/bin/env bash
# desk-waifu remote-sync
# 把 ~/.desk-waifu/gifs/*.gif 上传到云端 hub 的 PUT /assets/:state。
# 已同步 (hash 未变) 时服务端返回 304, 跳过。失败重试 2 次 (1s/2s 指数退避)。

set -u
DATA_DIR="${HOME}/.desk-waifu"
ENV_FILE="${DATA_DIR}/remote.env"
GIFS_DIR="${DATA_DIR}/gifs"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '  %s\n' "$*"; }
err()  { printf '\033[31merror:\033[0m %s\n' "$*" >&2; }
ok()   { printf '\033[32mok:\033[0m %s\n' "$*"; }

if [ ! -f "${ENV_FILE}" ]; then
  err "${ENV_FILE} 不存在, 先跑:"
  echo "  $(dirname "$0")/remote-register.sh <hub_url> <username>"
  exit 1
fi

# shellcheck disable=SC1090
. "${ENV_FILE}"
: "${HUB_URL:=}"; : "${API_KEY:=}"; : "${USERNAME:=}"

if [ -z "${HUB_URL}" ] || [ -z "${API_KEY}" ]; then
  err "remote.env 缺 HUB_URL / API_KEY"
  exit 1
fi

command -v curl >/dev/null 2>&1 || { err "需要 curl"; exit 1; }

# 计算 sha256, 优先 shasum (macOS 自带)
sha256_of() {
  if command -v shasum >/dev/null 2>&1; then
    shasum -a 256 "$1" 2>/dev/null | awk '{print $1}'
  elif command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
  else
    echo ""
  fi
}

if [ ! -d "${GIFS_DIR}" ]; then
  err "${GIFS_DIR} 不存在, 先跑 install.sh 把 GIF 拷进去"
  exit 1
fi

shopt -s nullglob 2>/dev/null || true
GIFS=( "${GIFS_DIR}"/*.gif )

if [ ${#GIFS[@]} -eq 0 ]; then
  err "${GIFS_DIR} 下没有 GIF"
  exit 1
fi

bold "向 ${HUB_URL} 同步 ${#GIFS[@]} 个 GIF (用户=${USERNAME})..."

UPDATED=0
SKIPPED=0
FAILED=0

for gif in "${GIFS[@]}"; do
  state="$(basename "${gif}" .gif)"
  hash="$(sha256_of "${gif}")"
  [ -z "${hash}" ] && { err "无法计算 ${gif} 的 sha256"; FAILED=$((FAILED+1)); continue; }

  attempt=0
  delay=1
  while :; do
    attempt=$((attempt+1))
    # -w 拿状态码, body 丢弃
    CODE="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 20 \
      -X PUT "${HUB_URL}/assets/${state}" \
      -H "Authorization: Bearer ${API_KEY}" \
      -H "X-Content-Sha256: ${hash}" \
      -F "gif=@${gif}" 2>/dev/null || echo "000")"

    case "${CODE}" in
      200|201|204)
        ok "${state} 已更新"
        UPDATED=$((UPDATED+1))
        break ;;
      304)
        info "${state} 已同步 (304)"
        SKIPPED=$((SKIPPED+1))
        break ;;
      *)
        if [ "${attempt}" -ge 3 ]; then
          err "${state} 失败 (code=${CODE}, 重试 ${attempt} 次)"
          FAILED=$((FAILED+1))
          break
        fi
        sleep "${delay}"
        delay=$((delay*2))
        ;;
    esac
  done
done

echo ""
bold "完工汇总: ${#GIFS[@]} 个 GIF: ${UPDATED} 已更新, ${SKIPPED} 已同步(304), ${FAILED} 失败"
[ "${FAILED}" -eq 0 ] || exit 2
exit 0
