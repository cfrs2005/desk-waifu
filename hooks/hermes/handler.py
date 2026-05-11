"""desk-waifu × Hermes Agent bridge.

Installed by desk-waifu's `scripts/install.sh` into `~/.hermes/hooks/desk-waifu/`.
Hermes discovers this directory at gateway startup (see Hermes
`gateway/hooks.py`) and dispatches each declared event to `handle()`.

Protocol — write files under `~/.desk-waifu/`:

| event             | slot(s)                                       |
|-------------------|-----------------------------------------------|
| gateway:startup   | bubble  (greeting)                            |
| session:start     | state=peek                                    |
| session:end       | task=∅, state=sleep, thinking=off             |
| session:reset     | task=∅, state=sleep, thinking=off             |
| agent:start       | task=<user msg head>, state=loading, thinking |
| agent:step        | state=<peek|coding|loading>, hud=🔧 <tool>    |
| agent:end         | thinking=off, state=celebrate, hud=✓ <reply>  |

All writes are atomic (`.tmp.<pid>` → `os.replace`) and fire-and-forget.
If `~/.desk-waifu/` does not exist (chibi not installed / Hammerspoon off),
every call short-circuits to a no-op. Errors are swallowed so the hook
never breaks Hermes.

Slot contract reference: desk-waifu README + `docs/HERMES.md`.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

WF = Path.home() / ".desk-waifu"


def _enabled() -> bool:
    return WF.is_dir()


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


def _task(text: str | None) -> None:
    if not text:
        _atomic_write("task", "")
        return
    ts = time.time_ns()
    _atomic_write("task", f"{ts}\t{text}\n")


def _hud(text: str, sticky: bool = False) -> None:
    ts = time.time_ns()
    prefix = "\x01" if sticky else ""
    _atomic_write("hud", f"{ts}\t{prefix}{text}\n")


def _bubble(text: str | None) -> None:
    if not text:
        _atomic_write("bubble", "")
        return
    ts = int(time.time())
    _atomic_write("bubble", f"{ts}\t{text}\n")


def _thinking(on: bool) -> None:
    _atomic_write("thinking", f"{int(time.time())}\n" if on else "")


def _short(text: str, limit: int = 28) -> str:
    text = (text or "").strip().replace("\n", " ")
    return text if len(text) <= limit else text[: limit - 1] + "…"


# Coarse tool-name → state mapping. Last write wins; that's intentional.
_PEEK = ("read", "grep", "search", "ls", "glob", "find", "fetch", "view")
_CODE = ("edit", "write", "patch", "apply", "create_file", "str_replace")
_LOAD = ("bash", "shell", "run", "exec", "install", "build", "compile")


def _state_for_tool(name: str) -> str | None:
    low = (name or "").lower()
    if any(k in low for k in _PEEK):
        return "peek"
    if any(k in low for k in _CODE):
        return "coding"
    if any(k in low for k in _LOAD):
        return "loading"
    return None


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
            names = [n for n in (context.get("tool_names") or []) if n]
            if not names:
                return
            label = names[-1]
            mapped = _state_for_tool(label)
            if mapped:
                _state(mapped)
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
        return
