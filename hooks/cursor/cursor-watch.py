#!/usr/bin/env python3
"""Cursor → desk-waifu bridge — v1 (turn-aware).

Watches Cursor sqlite for turn lifecycle and drives ~/.desk-waifu/ chibi.

State machine (replaces old idle-based design):
  IDLE
   └─ type=1 bubble in cursorDiskKV  ──→  IN_TURN
         set_task(user_text), set_state("loading"), set_thinking(True)
  IN_TURN
   ├─ type=2 with toolFormerData.status="loading"  → state per TOOL_TO_STATE
   ├─ type=2 with toolFormerData.status="error"    → state=error_shrug
   ├─ type=2 with non-empty text                   → hud preview
   ├─ aiService.prompts grew in any workspace      → CELEBRATE → IDLE  (real signal)
   └─ 60s with no bubble/prompt activity           → CELEBRATE → IDLE  (safety only)

Why this works (verified by capture 2026-05-10):
  Cursor writes the user's prompt into workspace ItemTable['aiService.prompts']
  only AFTER the whole assistant turn finishes. Tool 'completed' / 'cancelled'
  status is an in-place sqlite UPDATE (same rowid) so a rowid-poller cannot
  observe it — prompts-array growth is the only reliable end-of-turn signal.

Slot writes (unchanged contract with desk-waifu):
  state:    coding | peek | loading | celebrate | error_shrug | supervise | sleep
  task:     blue user-message pill (persists across whole conversation)
  hud:      8s fade-out facts (✓ tool_name, ✗ errors, etc.)
  thinking: dots while assistant is generating
"""

from __future__ import annotations

import json
import os
import sqlite3
import sys
import time
from pathlib import Path

HOME = Path.home()
GLOBAL_DB = HOME / "Library/Application Support/Cursor/User/globalStorage/state.vscdb"
WORKSPACE_BASE = HOME / "Library/Application Support/Cursor/User/workspaceStorage"
WF = HOME / ".desk-waifu"
POLL_S = 0.5
SAFETY_IDLE_S = 60.0  # safety only — Cursor crashed / network died

TOOL_TO_STATE = {
    "read_file": "peek", "read_file_v2": "peek", "grep_search": "peek",
    "codebase_search": "peek", "list_dir": "peek", "file_search": "peek",
    "glob_file_search": "peek", "web_search": "peek", "fetch_rules": "peek",
    "edit_file": "coding", "search_replace": "coding", "edit_notebook": "coding",
    "delete_file": "coding", "reapply": "coding", "create_file": "coding",
    "run_terminal_cmd": "loading",
    "mcp_sequential_thinking_sequentialthinking": "supervise",
    "mcp_sequential-thinking_sequentialthinking": "supervise",
}


# -------- desk-waifu slot writers --------

def _enabled() -> bool:
    return WF.is_dir()


def _atomic_write(name: str, body: str) -> None:
    target = WF / name
    tmp = WF / f".{name}.tmp.{os.getpid()}"
    try:
        tmp.write_text(body, encoding="utf-8")
        os.replace(tmp, target)
    except Exception as e:
        log(f"[warn] write {name} failed: {e}")
        try:
            tmp.unlink(missing_ok=True)
        except Exception:
            pass


def set_state(name: str) -> None:
    _atomic_write("state", name + "\n")


def set_task(text: str | None) -> None:
    if not text:
        _atomic_write("task", "")
        return
    _atomic_write("task", f"{time.time_ns()}\t{text}\n")


def set_hud(text: str, sticky: bool = False) -> None:
    prefix = "\x01" if sticky else ""
    _atomic_write("hud", f"{time.time_ns()}\t{prefix}{text}\n")


def set_thinking(on: bool) -> None:
    _atomic_write("thinking", f"{int(time.time())}\n" if on else "")


def short(text: str, limit: int = 28) -> str:
    text = (text or "").strip().replace("\n", " ")
    return text if len(text) <= limit else text[: limit - 1] + "…"


# -------- helpers --------

def log(msg: str) -> None:
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)


def open_ro(path: Path) -> sqlite3.Connection:
    conn = sqlite3.connect(f"file:{path}?mode=ro", uri=True, timeout=2.0)
    conn.execute("PRAGMA query_only = 1")
    return conn


# -------- state machine --------

class State:
    def __init__(self) -> None:
        self.in_turn: bool = False
        self.last_activity_ts: float = 0.0
        self.last_tool_name: str | None = None
        # workspace_db_path -> last seen aiService.prompts length
        self.prompt_counts: dict[str, int] = {}


def celebrate(st: State, reason: str) -> None:
    log(f"TURN END ({reason}) last_tool={st.last_tool_name}")
    set_thinking(False)
    set_state("celebrate")
    set_hud(f"✓ done · {st.last_tool_name}" if st.last_tool_name else "✓ done")
    st.in_turn = False
    st.last_tool_name = None


def handle_user_bubble(obj: dict, st: State) -> None:
    text = short(obj.get("text") or "") or "..."
    log(f"USER: {text!r}")
    set_task(text)
    set_state("loading")
    set_thinking(True)
    st.in_turn = True
    st.last_activity_ts = time.time()
    st.last_tool_name = None


def handle_assistant_bubble(obj: dict, st: State) -> None:
    st.last_activity_ts = time.time()

    tfd = obj.get("toolFormerData")
    if isinstance(tfd, dict) and tfd:
        name = tfd.get("name") or "?"
        status = tfd.get("status") or "?"
        st.last_tool_name = name

        if status == "loading":
            mapped = TOOL_TO_STATE.get(name, "loading")
            log(f"ASSIST tool→ {name} [loading] state={mapped}")
            set_state(mapped)
            set_hud(f"🔧 {name}")
        elif status == "error":
            log(f"ASSIST tool ✗ {name}")
            set_state("error_shrug")
            set_hud(f"✗ {name}", sticky=True)
        # 'completed' / 'cancelled' are in-place updates we can't observe.
        # Real turn end comes from aiService.prompts growth.
        return

    text = obj.get("text") or ""
    if isinstance(text, str) and text.strip():
        log(f"ASSIST text: {short(text)!r}")
        set_hud(f"💭 {short(text)}")
    # else: empty placeholder bubble — no UI change, but activity timestamp updated


def check_turn_end(st: State) -> None:
    """aiService.prompts growth in any workspace = the turn just ended."""
    if not WORKSPACE_BASE.is_dir():
        return
    for d in WORKSPACE_BASE.iterdir():
        db = d / "state.vscdb"
        if not db.exists():
            continue
        try:
            c = open_ro(db)
            row = c.execute(
                "SELECT value FROM ItemTable WHERE key='aiService.prompts'"
            ).fetchone()
            c.close()
        except Exception:
            continue
        if not row or not row[0]:
            continue
        v = row[0]
        if isinstance(v, bytes):
            v = v.decode("utf-8", errors="replace")
        try:
            arr = json.loads(v)
        except Exception:
            continue
        if not isinstance(arr, list):
            continue
        key = str(db)
        cur = len(arr)
        prev = st.prompt_counts.get(key)
        if prev is None:
            st.prompt_counts[key] = cur
            continue
        if cur > prev:
            st.prompt_counts[key] = cur
            if st.in_turn:
                celebrate(st, f"prompts {prev}→{cur} @ {d.name}")
        elif cur < prev:
            # Cursor truncated/rewrote the array — just resync.
            st.prompt_counts[key] = cur


def safety_idle(st: State) -> None:
    if not st.in_turn:
        return
    if time.time() - st.last_activity_ts >= SAFETY_IDLE_S:
        celebrate(st, f"safety idle {SAFETY_IDLE_S:.0f}s")


# -------- main loop --------

def main() -> int:
    if not GLOBAL_DB.exists():
        log(f"[fatal] global DB missing: {GLOBAL_DB}")
        return 1
    if not _enabled():
        log(f"[fatal] ~/.desk-waifu/ not found — desk-waifu must be installed")
        return 1

    log(f"start  global DB: {GLOBAL_DB.stat().st_size / 1e9:.2f} GB")
    log(f"start  desk-waifu: {WF}")

    conn = open_ro(GLOBAL_DB)
    last_rowid = conn.execute("SELECT MAX(rowid) FROM cursorDiskKV").fetchone()[0] or 0
    conn.close()
    log(f"start  rowid baseline = {last_rowid}")

    st = State()
    # Bootstrap workspace prompt counts so we don't fire celebrate on startup.
    check_turn_end(st)
    log(f"start  workspaces tracked: {len(st.prompt_counts)}")
    log(f"start  poll every {POLL_S}s (Ctrl-C to stop)")
    log("=" * 60)

    while True:
        t0 = time.time()
        try:
            conn = open_ro(GLOBAL_DB)
            rows = conn.execute(
                "SELECT rowid, key, value FROM cursorDiskKV "
                "WHERE rowid > ? AND key LIKE 'bubbleId:%' ORDER BY rowid",
                (last_rowid,),
            ).fetchall()
            conn.close()
        except Exception as e:
            log(f"[warn] poll failed: {e}")
            time.sleep(POLL_S)
            continue

        for rid, k, v in rows:
            if rid > last_rowid:
                last_rowid = rid
            if isinstance(v, bytes):
                v = v.decode("utf-8", errors="replace")
            try:
                obj = json.loads(v)
            except Exception as e:
                log(f"[warn] parse rowid={rid}: {e}")
                continue
            t = obj.get("type")
            if t == 1:
                handle_user_bubble(obj, st)
            elif t == 2:
                handle_assistant_bubble(obj, st)

        check_turn_end(st)
        safety_idle(st)
        time.sleep(max(0.0, POLL_S - (time.time() - t0)))


if __name__ == "__main__":
    try:
        sys.exit(main() or 0)
    except KeyboardInterrupt:
        log("interrupted")
