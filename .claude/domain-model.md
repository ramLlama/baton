# Domain Model

## Session (`baton--session`)

The central data structure. A `cl-defstruct` with fields:
- `name` -- unique string, also the registry key (auto-generated as `"<agent-prefix>-<n>"` or user-provided). Duplicates are rejected at creation time with an error.
- `agent` -- symbol key into `baton-agents` (e.g., `'claude-code`, `'aider`)
- `command`, `directory`, `buffer` -- the shell command, working dir, and vterm buffer
- `executor` -- symbol selecting *how/where* the command runs (default `exec` = direct host execution). Orthogonal to `agent` (*what* runs). See [Executor](#executor-baton-executor) below.
- `status` -- symbol: `running`, `waiting`, `idle`, `error`, or `other`
- `waiting-reason` -- string describing why the agent is waiting, in error, or in other status (e.g., "permission prompt")
- `created-at`, `updated-at` -- `float-time` timestamps
- `metadata` -- plist for internal state (`:watcher-timer`, `:last-output-hash`, `:last-output-time`, `:state`, `:unread`, `:notified-at`). The `:state` field is a plist `(:status SYMBOL :reason STRING-OR-NIL :at FLOAT-TIME)` written by `baton-process--tick-set-status` (for `:periodic` agents) and `baton-monet--set-state` (for `:on-event` agents). `:unread` is a boolean flag. `:notified-at` is a `float-time` timestamp of the last notification sent.

## Agent Registry (`baton-agents`)

A hash-table (`eq` test) mapping agent symbols to definition plists. Each plist has:
- `:command` -- shell command string
- `:args` -- default argument list
- `:status-function` -- optional function `(SESSION) -> (cons SYMBOL REASON) | nil`. Receives a `baton--session` struct; call `baton-process-session-tail` internally to get buffer text if needed. SYMBOL is a plain symbol (`waiting`, `error`, `other`, `running`, `idle`) -- not a keyword. `nil` also means idle. `baton-process-make-regex-status-function` builds a pattern-based status function (calls `baton-process-session-tail` automatically); its alist format is `(REGEXP . (SYMBOL . REASON))`.
- `:status-function-trigger` -- required symbol: `:periodic` (watcher calls status function each tick) or `:on-event` (status function is driven by external hooks, not the watcher). `baton-define-agent` validates this value and signals an error for anything else.
- `:env-functions` -- list of functions, each `(SESSION-NAME DIRECTORY) -> (:env STRINGS :ports PORTS) | nil`. `:env` is a list of `"VAR=VALUE"` strings injected into the agent's environment; `:ports` is a list of host ports the agent process must be able to reach. Returning nil contributes nothing. **Any other return shape (including a bare list of `"VAR=VALUE"` strings) is a hard error** -- the contract is enforced fail-fast in `baton-executor--agent-env`, with no legacy tolerance. Append functions with `baton-add-env-function` (idempotent).

Register new agents with `baton-define-agent`. Three built-in: `claude-code`, `aider`, `codex` (all `:periodic`).

## Session Registries

- `baton--sessions` -- hash-table (session name string -> session struct)
- `baton--session-counters` -- hash-table (agent symbol -> integer counter)

## Executor (`baton-executor`)

The **executor** is the second of a session's two orthogonal axes: the `agent` decides *what* runs (`baton-agents`), the `executor` decides *how/where* it runs (the session's `executor` slot). Executors plug in via `cl-defgeneric` dispatch on the executor symbol, mirroring `baton-term.el`'s terminal-backend dispatch. Lives in `baton-executor.el` (requires only `cl-lib` + `baton-session`, plus a `defvar baton-agents` declaration).

Generic interface:
- `baton-executor--resolve (executor session)` -- pre-spawn setup; returns a plist `(:directory DIR :command CMD :extra-env ENV)`. `:extra-env` is a list of `"VAR=VALUE"` strings prepended to the host `process-environment`, or nil when the executor delivers env another way. `baton-process-spawn` calls this and treats the result as opaque, so spawning is executor-agnostic.
- `baton-executor--teardown (executor session)` -- release resources held for the session. Default method is a no-op. **Implementations must be idempotent.**
- `baton-executor--teardown-on-kill (session)` -- dispatches teardown for the session's executor; registered on `baton-session-killed-hook` **at load time** (not by `baton-mode`), so it survives `baton-mode` toggles.
- `baton-executor--agent-env (session dir)` -- evaluates the agent's `:env-functions` **exactly once** with `(SESSION-NAME DIR)`, aggregating results into `(:env STRINGS :ports PORTS)` (ports deduped via `delete-dups`). Enforces the env-function plist contract (errors on any other shape).

Built-in executor:
- **`exec`** -- direct host execution (the default). `baton-executor--resolve` uses the session's own directory and command, and exposes aggregated agent `:env` as `:extra-env`. `:ports` is ignored because localhost is already reachable.

> Forward pointer: `exec` is Phase 1 of a planned multi-executor design. **Phase 2 (built)** adds optional `baton-sodagun.el` — see [sodagun Integration](#sodagun-integration-baton-sodagun) below — which creates git worktrees via the `sodagun` CLI but still runs the session on the host under the `exec` executor (no new executor symbol yet). **Phase 3 (not built)** will add a real `sodagun` executor running the session in a microVM sandbox (transient `-s` flag), where `:ports` will drive guest→host port forwarding. Do not assume the sandbox executor exists.

## sodagun Integration (`baton-sodagun`)

Optional module integrating the external **sodagun CLI** (worktree/sandbox manager). Requires `cl-lib`, `baton-session`, `baton-executor`. Loaded by `baton-mode` only when the `sodagun` binary is on `exec-path`; `baton.el` references its symbols via `declare-function`.

- `baton-sodagun-available-p` -- non-nil when the `sodagun` binary is on `exec-path`.
- `baton-sodagun--run (&rest args)` -- synchronous `call-process` wrapper. Always passes the global flags `--output json --quiet` **before** the subcommand ARGS. sodagun prints its result as a single JSON line, but setup scripts may log progress lines above it, so the wrapper parses the **last line starting with `{`** (`re-search-backward "^{"`), returns it as an alist (`json-parse-buffer :object-type 'alist`), and signals an error (shell-quoted command + captured output) on non-zero exit or when no JSON line is found.
- `baton-sodagun--add-worktree (branch repo &optional base)` -- shells `sodagun git add-worktree BRANCH REPO [--base BASE]`. Parses `rootdir` from the JSON, then reads `<rootdir>/sodagun.json` for `worktree_path`. Returns `(ROOTDIR . WORKTREE-PATH)`. **Fails fast** when the metadata file is missing/unreadable, when either path is absent, or when either path is non-absolute (downstream code anchors sessions to these paths verbatim).

This module does **not** define an executor or register hooks; worktree sessions run under the default `exec` executor. See [architecture.md](architecture.md#worktree-spawn-baton-new) for how `baton-new` consumes it.

## Status Observation

State is **derived fresh each watcher tick** — not accumulated via a state machine:

- `running` -- output hash changed since last tick (or `:status-function` returns `running`)
- `waiting` -- output has been stable ≥ 0.5s AND `:status-function` returns `waiting`
- `error` -- output has been stable ≥ 0.5s AND `:status-function` returns `error`
- `other` -- output has been stable ≥ 0.5s AND `:status-function` returns `other`
- `idle` -- output has been stable ≥ 0.5s AND `:status-function` returns nil or `idle`

When a session's process exits, the vterm buffer is killed and the watcher self-cancels. There is no `done` state.

## Unread Tracking

Unread state is stored as a boolean `:unread` flag in session metadata.

- **Set to `t`**: by `baton-notify--on-status-changed-mark-unread` (on `baton-session-status-changed-hook`) when transitioning to `waiting`/`idle`/`error`/`other` and the buffer is not visible
- **Set to `nil`**: by `baton-notify--global-tick` (0.5s global timer) when the buffer becomes visible in any window

`baton-session-unread-p` reads the `:unread` flag from session metadata.

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

Most are wired up by `baton--setup-hooks` when `baton-mode` is enabled. Exception: `baton-executor--teardown-on-kill` is added to `baton-session-killed-hook` at `baton-executor.el` **load time**, independent of `baton-mode`, so executor teardown runs even when `baton-mode` is off or has been toggled.
