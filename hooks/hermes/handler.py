"""Bridge Hermes lifecycle events to the desk-waifu chibi pet.

Protocol: write files under ~/.desk-waifu/. Fire-and-forget; if the
directory does not exist (desk-waifu not installed / Hammerspoon off),
every call short-circuits to a no-op.

See ~/Desktop/desk-waifu-integration.md for the slot contract.
"""

from __future__ import annotations

import json
import os
import subprocess
import time
from pathlib import Path

WF = Path.home() / ".desk-waifu"
REMOTE_FORWARD = WF / "remote-forward.sh"
REMOTE_ENV = WF / "remote.env"


def _enabled() -> bool:
    return WF.is_dir()


def _remote_forward(event_type: str, value: str) -> None:
    """Async fire-and-forget bypass: pipe a JSON line into remote-forward.sh
    with agent=hermes. The shell script handles env loading, instance_id,
    ms timestamps, curl background, and silent-on-missing-config.

    Why we have to be careful here:
      - `cat` in remote-forward.sh blocks until EOF — we MUST close stdin
      - Popen handle has to live long enough for the kernel to deliver the
        bytes; if the Python process is short-lived, the child can be killed
        before it sends the curl. start_new_session=True detaches it.
      - We don't wait() — that would block Hermes."""
    if not REMOTE_ENV.is_file() or not REMOTE_FORWARD.is_file():
        return
    try:
        payload = json.dumps({"agent": "hermes", "type": event_type, "value": value})
        proc = subprocess.Popen(
            ["/bin/bash", str(REMOTE_FORWARD)],
            stdin=subprocess.PIPE,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
            env={**os.environ, "DESK_WAIFU_AGENT": "hermes"},
        )
        proc.stdin.write(payload.encode())
        proc.stdin.close()  # ← critical: gives the bash side an EOF on cat
    except Exception:
        pass


def _atomic_write(name: str, body: str) -> None:
    target = WF / name
    tmp = WF / f".{name}.tmp.{os.getpid()}"
    try:
        tmp.write_text(body, encoding="utf-8")
        os.replace(tmp, target)
    except Exception:
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass


def _state(name: str) -> None:
    _atomic_write("state", name + "\n")
    _remote_forward("state", name)


def _task(text: str | None) -> None:
    # Two channels in office land:
    #   task = master's order, sticky until session:end clears it
    #   hud  = rolling activity (tool calls, AI prose)
    # Forward to the dedicated `task` channel so the office can render it as
    # a persistent multi-line speech bubble distinct from rolling HUD.
    if text is None or text == "":
        _atomic_write("task", "")
        _remote_forward("task", "")
        return
    ts = time.time_ns()
    _atomic_write("task", f"{ts}\t{text}\n")
    _remote_forward("task", text)


def _hud(text: str, sticky: bool = False) -> None:
    ts = time.time_ns()
    prefix = "\x01" if sticky else ""
    _atomic_write("hud", f"{ts}\t{prefix}{text}\n")
    _remote_forward("hud", text)


def _bubble(text: str | None) -> None:
    if text is None or text == "":
        _atomic_write("bubble", "")
        return
    ts = int(time.time())
    _atomic_write("bubble", f"{ts}\t{text}\n")
    # Bubble has 28-char server cap; _short() already trims to 28 upstream.
    _remote_forward("bubble", text[:28])


def _thinking(on: bool) -> None:
    if on:
        _atomic_write("thinking", f"{int(time.time())}\n")
    else:
        _atomic_write("thinking", "")


# Trim long inbound text to keep the chibi readable (~14 CJK chars ideal).
def _short(text: str, limit: int = 28) -> str:
    text = (text or "").strip().replace("\n", " ")
    return text if len(text) <= limit else text[: limit - 1] + "…"


async def handle(event_type: str, context: dict) -> None:
    if not _enabled():
        return

    try:
        if event_type == "gateway:startup":
            platforms = context.get("platforms") or []
            _state("idle_blink")
            _bubble(f"Hermes 上线 · {len(platforms)} 平台" if platforms else "Hermes 上线")
            return

        if event_type == "session:start":
            _state("peek")
            _bubble(None)
            return

        if event_type in ("session:end", "session:reset"):
            _task(None)
            _state("sleep")
            _thinking(False)
            return

        if event_type == "agent:start":
            msg = _short(context.get("message", ""))
            if msg:
                _task(msg)
            _state("loading")
            _thinking(True)
            return

        if event_type == "agent:step":
            names = context.get("tool_names") or []
            shown = [n for n in names if n]
            if not shown:
                return
            label = shown[-1]
            # Coarse state hint by tool family — last-write-wins is fine.
            low = label.lower()
            if any(k in low for k in ("read", "grep", "search", "ls", "glob", "find")):
                _state("peek")
            elif any(k in low for k in ("edit", "write", "patch", "apply")):
                _state("coding")
            elif any(k in low for k in ("bash", "shell", "run", "exec", "install", "build")):
                _state("loading")
            _hud(f"🔧 {label}")
            return

        if event_type == "agent:end":
            _thinking(False)
            _state("celebrate")
            resp = _short(context.get("response", ""))
            if resp:
                _hud(f"✓ {resp}")
            return

    except Exception:
        # Hermes already swallows hook errors, but be defensive.
        return
