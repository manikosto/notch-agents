# 👾 Notch Agents

**Mission control for AI coding agents — in your MacBook notch.**

Notch Agents lives inside the MacBook notch and runs your AI coding fleet:
**Claude Code, Codex and Cursor** in one Dynamic-Island-style panel.
Agent finishes → the notch pops with a summary. Needs approval or asks a
question → you answer right there. Zero window switching.

Native Swift · no Electron · ~1 MB · macOS 13+ · MIT

## Features

- **Live sessions** — Claude Code / Codex / Cursor side by side: project, branch,
  model, last prompt, live status (working / ready / idle).
- **Approvals from the notch** — permission requests appear with the exact
  command or diff and three buttons: Deny / Allow Once / **Always**.
  The terminal dialog never appears; “Always” remembers the rule.
- **Questions inline** — `AskUserQuestion` options render as buttons, plus a
  field for a custom answer.
- **Done screen** — when an agent finishes, the notch shows *which* session
  finished and *what shipped* (the agent’s last message).
- **Plan review** — plans from plan mode show up in the approval card before
  you accept them.
- **Precise terminal jump** — click a session to jump to the exact
  Terminal.app / iTerm2 tab hosting it (by tty); Warp, Ghostty & friends are
  raised as apps; dead sessions are resumed via `claude --resume`.
- **Usage limits** — your 5-hour and weekly Claude quota with reset timers,
  always visible in the header.
- **Zero config** — on first launch the app wires its own Claude Code hooks
  and Codex `notify` (idempotent; your existing hooks are never touched).
- **Model switcher, sounds, login item** — change the default model from the
  notch; gentle pops when something needs you; starts at login.

## Install

Grab the notarized DMG from [Releases](../../releases) (or build it yourself),
drag to Applications, launch. That’s it — hooks are configured automatically.
New Claude Code sessions will start reporting to the notch.

## Build from source

```bash
swift build                  # dev build
scripts/build-app.sh         # release .app → ~/Applications
scripts/release.sh           # signed + notarized DMG (needs Developer ID)
```

## How it works

Two data sources, no cloud, everything local:

1. **Transcripts** — `~/.claude/projects/**/*.jsonl` and
   `~/.codex/sessions/**/rollout-*.jsonl` are scanned every 2 s for the
   session list and statuses.
2. **Hooks** — a tiny HTTP server on `127.0.0.1:48738` receives live events:

   | Hook                        | Effect                                        |
   |-----------------------------|-----------------------------------------------|
   | `PermissionRequest` (long-poll) | Allow/Deny/Always card; decision returned to Claude Code |
   | `PreToolUse` (AskUserQuestion, long-poll) | question card; answer returned as feedback |
   | `Stop`                      | Done screen with the session’s summary        |
   | `Notification`              | “waiting for you” alert                       |
   | Codex `notify`              | Done pop for Codex turns                      |

   If you ignore a card, it falls back to the normal terminal flow — nothing
   is ever lost.

The window sits in its own CGS space (so it never lags behind the hardware
notch when switching Spaces) and morphs with asymmetric springs — bouncy on
expand, critically damped on collapse.

## Landing page

`landing/` is a self-contained static page with a live product simulation.
Deploy on [Railway](https://railway.app): new service from this repo, set
**Root Directory** to `landing` — the Dockerfile (Caddy) does the rest.
Any static host works too.

## License

[MIT](LICENSE) · built by [Aleksei Koledachkin](mailto:akoledachkin@gmail.com)
with Claude Code — and approved from its own notch. 👾
