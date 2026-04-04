# Domain Model

## Session (`baton--session`)

The central data structure. A `cl-defstruct` with fields:
- `name` -- unique string, also the registry key (auto-generated as `"<agent-prefix>-<n>"` or user-provided). Duplicates are rejected at creation time with an error.
- `agent` -- symbol key into `baton-agents` (e.g., `'claude-code`, `'aider`)
- `command`, `directory`, `buffer` -- the shell command, working dir, and vterm buffer
- `status` -- symbol: `running`, `waiting`, `idle`, `error`, or `other`
- `waiting-reason` -- string describing why the agent is waiting, in error, or in other status (e.g., "permission prompt")
- `created-at`, `updated-at` -- `float-time` timestamps
- `metadata` -- plist for internal state (`:watcher-timer`, `:last-output-hash`, `:last-output-time`, `:current-hash`, `:last-seen-hash`, `:state`). The `:state` field (used by `:on-event` agents) is a plist `(:status SYMBOL :reason STRING-OR-NIL :at FLOAT-TIME)` written by `baton-monet--set-state`.

## Agent Registry (`baton-agents`)

A hash-table (`eq` test) mapping agent symbols to definition plists. Each plist has:
- `:command` -- shell command string
- `:args` -- default argument list
- `:status-function` -- optional function `(SESSION) -> (cons SYMBOL REASON) | nil`. Receives a `baton--session` struct; call `baton-process-session-tail` internally to get buffer text if needed. SYMBOL is a plain symbol (`waiting`, `error`, `other`, `running`, `idle`) -- not a keyword. `nil` also means idle. `baton-process-make-regex-status-function` builds a pattern-based status function (calls `baton-process-session-tail` automatically); its alist format is `(REGEXP . (SYMBOL . REASON))`.
- `:status-function-trigger` -- required symbol: `:periodic` (watcher calls status function each tick) or `:on-event` (status function is driven by external hooks, not the watcher). `baton-define-agent` validates this value and signals an error for anything else.

Register new agents with `baton-define-agent`. Three built-in: `claude-code`, `aider`, `codex` (all `:periodic`).

## Session Registries

- `baton--sessions` -- hash-table (session name string -> session struct)
- `baton--session-counters` -- hash-table (agent symbol -> integer counter)

## Status Observation

State is **derived fresh each watcher tick** — not accumulated via a state machine:

- `running` -- output hash changed since last tick (or `:status-function` returns `running`)
- `waiting` -- output has been stable ≥ 0.5s AND `:status-function` returns `waiting`
- `error` -- output has been stable ≥ 0.5s AND `:status-function` returns `error`
- `other` -- output has been stable ≥ 0.5s AND `:status-function` returns `other`
- `idle` -- output has been stable ≥ 0.5s AND `:status-function` returns nil or `idle`

When a session's process exits, the vterm buffer is killed and the watcher self-cancels. There is no `done` state.

## Unread Tracking

Session metadata tracks two hashes:
- `:current-hash` -- MD5 of last 250 lines, updated every watcher tick
- `:last-seen-hash` -- hash saved while the buffer is visible in any window

`baton-session-unread-p` returns `t` when the buffer is not currently visible and `:current-hash ≠ :last-seen-hash`. This is purely computed — no stored boolean flag.

## Alert Backend Registry (`baton-alert--backends`)

An ordered alist where each entry is `(NAME :predicate PRED :handler HANDLER)`. `baton-alert--dispatch` iterates front-to-back; the first backend whose `:predicate` returns non-nil fires. User-registered backends prepend (higher priority); built-ins append.

Built-in backends in priority order:
1. **`alerter`** -- macOS `alerter` CLI; disabled over SSH
2. **`osc777`** -- OSC 777 terminal escape; active only in SSH sessions
3. **`notifications`** -- Emacs built-in D-Bus/Windows notifications; non-macOS, non-SSH
4. **`echo`** -- echo-area `message`; always available fallback

Key private symbols (double-dash, architected for future promotion to public):
- `baton-alert--register-backend` / `baton-alert--deregister-backend` -- manage user backends
- `baton-alert--dispatch` -- installed as `baton-notify-function` by `baton-alert--setup`
- `baton-alert--format` -- builds `(:title :body :icon)` plist from a session
- `baton-alert--sanitize-terminal` -- strips control characters for safe OSC 777 injection
- `baton-alert--icon-path` -- resolved from `logo.png` adjacent to the .el file at load time

## Hooks

- `baton-session-created-hook` -- args: `(session)`
- `baton-session-killed-hook` -- args: `(session)`
- `baton-session-status-changed-hook` -- args: `(session old-status new-status)`
- `baton-session-unread-changed-hook` -- args: `(session)` — fires on read→unread transition

These are wired up by `baton--setup-hooks` when `baton-mode` is enabled.
