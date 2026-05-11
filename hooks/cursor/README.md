# desk-waifu × Cursor bridge

A polling daemon that watches Cursor's sqlite state and drives the
`~/.desk-waifu/` chibi pet — same slot contract as the Hermes bridge
under `hooks/hermes/`, but for Cursor (which has no hook API).

## Run

```bash
python3 hooks/cursor/cursor-watch.py
```

Requires Python ≥ 3.9 and an installed desk-waifu (`~/.desk-waifu/`
must exist). Polls Cursor's sqlite every 500 ms, read-only.

Stick it in launchd / a tmux pane / wherever — it's stateless, safe
to restart any time.

## What it reads

| path                                                                  | role                              |
|-----------------------------------------------------------------------|-----------------------------------|
| `~/Library/Application Support/Cursor/User/globalStorage/state.vscdb` | bubble events (user / assistant)  |
| `~/Library/Application Support/Cursor/User/workspaceStorage/*/state.vscdb` | per-workspace turn-end signal |

Both opened `?mode=ro` with `PRAGMA query_only=1`. Never writes Cursor data.

## State machine

```
IDLE
 └─ type=1 bubble (cursorDiskKV)  ──→  IN_TURN
      set_task, set_state("loading"), set_thinking(True)

IN_TURN
 ├─ type=2 + toolFormerData.status="loading"  → state per TOOL_TO_STATE
 ├─ type=2 + toolFormerData.status="error"    → state=error_shrug (sticky hud)
 ├─ type=2 + non-empty text                   → 💭 hud preview
 ├─ aiService.prompts grew (any workspace)    → CELEBRATE → IDLE   ⭐ turn-end
 └─ 60 s idle with no activity                → CELEBRATE → IDLE   (safety only)
```

### Why `aiService.prompts` is the turn-end signal

Verified by db-delta capture across three live turns: Cursor writes
the user's prompt into workspace `ItemTable['aiService.prompts']`
**only after** the assistant finishes its whole turn (tool calls +
final text). The tool `completed` / `cancelled` status is an in-place
sqlite `UPDATE` on the same `rowid`, so a rowid-tail poller cannot
observe it — `aiService.prompts` growth is the only reliable signal.

This is also why we **don't** use idle-timeout as the primary
celebrate trigger: between two slow tool calls there can be a 5–10 s
gap with no new bubble, which would falsely celebrate, then flap
back to `coding` when the next tool arrives.

## Slot contract

Same as `hooks/hermes/handler.py`:

| slot     | content                                                       |
|----------|---------------------------------------------------------------|
| state    | `coding` / `peek` / `loading` / `celebrate` / `error_shrug` / `supervise` / `sleep` |
| task     | blue user-message pill (persists across whole conversation)   |
| hud      | 8 s fade-out facts (`🔧 tool`, `✓ done`, `✗ error`, `💭 text`) |
| thinking | dots while assistant is generating                            |

All writes go through `.tmp.<pid>` → `os.replace` (atomic). Silently
no-ops if `~/.desk-waifu/` is missing.

## Tool → state mapping

| tool families                                                                 | state    |
|-------------------------------------------------------------------------------|----------|
| `read_file*`, `grep_search`, `codebase_search`, `list_dir`, `file_search`, `glob_file_search`, `web_search`, `fetch_rules` | peek     |
| `edit_file`, `search_replace`, `edit_notebook`, `delete_file`, `reapply`, `create_file` | coding   |
| `run_terminal_cmd`                                                            | loading  |
| `mcp_sequential[_-]thinking_sequentialthinking`                               | supervise |
| anything else                                                                 | loading  |

Edit `TOOL_TO_STATE` at the top of `cursor-watch.py` to extend.
