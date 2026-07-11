# Getting Claude *inside* Roblox Studio (MCP)

Two different Claudes work on this game:

| | Where it runs | What it does |
|---|---|---|
| **Cloud Claude** (the one building this repo) | claude.ai cloud container | Writes/reviews all code, pushes to GitHub. Cannot see or touch your Studio. |
| **Local Claude** (Claude Desktop or Claude Code on YOUR PC) | your computer | Via MCP, gets hands *inside* your open Studio: run Luau in the data model, insert models, read console output, start/stop Play mode. |

They meet in the middle: cloud Claude ships code through GitHub → Rojo syncs it into
Studio → local Claude pokes at the live place through MCP.

## Setup (built-in Studio MCP server — recommended)

Recent Roblox Studio ships the MCP server out of the box:

1. Update Roblox Studio to the latest version.
2. In Studio, open **Assistant Settings → MCP Servers**.
3. Turn on **"Enable Studio as MCP server"**.
4. Expand the **Quick connect** dropdown — it lists supported clients found on
   your computer (**Claude Desktop, Claude Code, Cursor, VS Code, Codex CLI,
   Gemini CLI, Antigravity**). Toggle on the one you use.
5. Verify: open **Assistant → … → Manage MCP Servers** and check for the
   **green indicator** showing the client is connected.

Now open Claude Desktop (or run `claude` in a terminal) on your PC and ask it
things like *"list the children of Workspace"* or *"run this Luau in Studio"* —
it will operate on your open place.

## Manual JSON config (if quick connect doesn't list your client)

Claude Desktop → **Settings → Developer → Edit Config** (`claude_desktop_config.json`),
then add the server per the official docs: https://create.roblox.com/docs/studio/mcp

## Legacy option (standalone server)

Roblox's older standalone server ([Roblox/studio-rust-mcp-server](https://github.com/Roblox/studio-rust-mcp-server))
still works but is no longer maintained — its installer configures Claude
Desktop/Cursor automatically and exposes `run_code`, `insert_model`,
`get_console_output`, `start_stop_play`, `run_script_in_play_mode`,
`get_studio_mode`. Prefer the built-in server above.

## Debugging loop that works well

1. `rojo serve` + Rojo plugin **Connect** keeps the place synced with this repo.
2. Press **Play**; if something breaks, either paste the red Output text to
   cloud Claude (fastest for code fixes), or ask local Claude via MCP to
   `get_console_output` and investigate live.
3. Code fixes always land in this repo (keeps git as the source of truth) —
   avoid letting local Claude write big scripts directly into the place, or
   Rojo sync will overwrite them.
