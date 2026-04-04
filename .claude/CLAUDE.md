# Baton

## What This Project Does

Baton is an Emacs Lisp package for managing multiple AI coding agents (Claude Code, Aider, Codex, Gemini CLI, etc.) from a unified interface inside Emacs. Agents run in vterm terminal buffers. Baton monitors their output for status transitions (running/waiting/idle) and surfaces status via a modeline badge, a tabulated-list status buffer, and optional OS notifications.

## Tech Stack

- **Language**: Emacs Lisp (lexical-binding throughout)
- **Emacs minimum**: 29.1
- **Required dependency**: vterm (>= 0.0.2) -- agents run in vterm buffers
- **Optional dependency**: monet (sibling repo at `../monet`) -- diff review integration
- **Testing**: ERT (Emacs Regression Testing framework)
- **Build**: GNU Make (`make checkdoc`, `make compile`, `make test`)

## Repository Structure

```
baton/
  baton-session.el    -- Session struct (cl-defstruct), hash-table registries, lifecycle hooks
  baton-process.el    -- vterm spawning, 500ms debounced output watcher, pure pattern matcher
  baton-notify.el     -- Modeline segment B[Nw/Ni/Nr N*], *Baton* tabulated-list buffer, baton-jump
  baton-alert.el      -- Desktop alert backend registry: alerter, OSC 777, D-Bus/toast, echo fallback
  baton-monet.el      -- Optional monet integration: overrides openDiff tool for diff-review awareness
  baton.el            -- Agent-type registry, baton-mode global minor mode, user commands, keymaps
  test/
    baton-test-helpers.el   -- Shared ERT macros (baton-test-with-clean-state, baton-alert-test-with-clean-state)
    baton-session-tests.el  -- Session lifecycle and unread tests
    baton-process-tests.el  -- Agent registry, status-function dispatch, env-functions
    baton-notify-tests.el   -- Modeline, timers, status buffer, error/other notify
    baton-monet-tests.el    -- Monet diff workflow
    baton-alert-tests.el    -- Alert backends
  Makefile             -- checkdoc / compile / test targets; TEST_FILES variable
  .gitignore           -- *.elc
  .claude/
    settings.local.json -- Allowed bash commands for Claude Code
```

## Load Order

Strict require chain -- each file requires only what it needs:

1. `baton-session` -- no baton dependencies (requires only `cl-lib`)
2. `baton-process` -- requires `baton-session`
3. `baton-notify` -- requires `baton-session`
4. `baton-alert` -- requires `baton-session`, `baton-notify`
5. `baton-monet` -- requires `baton-session` (monet symbols are `declare-function` only)
6. `baton` -- requires `baton-session`, `baton-process`, `baton-notify`, `baton-alert`; conditionally loads `baton-monet`

## Key Concepts & Domain Model

### Session (`baton--session`)

The central data structure. A `cl-defstruct` with fields:
- `name` -- unique string, also the registry key (auto-generated as `"<agent-prefix>-<n>"` or user-provided). Duplicates are rejected at creation time with an error.
- `agent-type` -- symbol key into `baton-agent-types` (e.g., `'claude-code`, `'aider`)
- `command`, `directory`, `buffer` -- the shell command, working dir, and vterm buffer
- `status` -- symbol: `running`, `waiting`, `idle`, `error`, or `other`
- `waiting-reason` -- string describing why the agent is waiting, in error, or in other status (e.g., "permission prompt")
- `created-at`, `updated-at` -- `float-time` timestamps
- `metadata` -- plist for internal state (`:watcher-timer`, `:last-output-hash`, `:last-output-time`, `:current-hash`, `:last-seen-hash`)

### Agent-Type Registry (`baton-agent-types`)

A hash-table (`eq` test) mapping agent-type symbols to definition plists. Each plist has:
- `:command` -- shell command string
- `:args` -- default argument list
- `:status-function` -- optional function `(SESSION) -> (cons KEYWORD VALUE) | nil`. Receives a `baton--session` struct; call `baton-process-session-tail` internally to get buffer text if needed. KEYWORD may be `:waiting`, `:error`, `:other`, `:running`, or `:idle` (nil also means idle). `baton-process-make-regex-status-function` builds a pattern-based status function (calls `baton-process-session-tail` automatically); its alist format is `(REGEXP . (KEYWORD . REASON))`.
- `:status-function-trigger` -- required symbol: `:periodic` (watcher calls status function each tick) or `:on-event` (status function is driven by external hooks, not the watcher). `baton-define-agent` validates this value and signals an error for anything else.

Register new types with `baton-define-agent`. Three built-in: `claude-code`, `aider`, `codex` (all `:periodic`).

### Session Registries

- `baton--sessions` -- hash-table (session name string -> session struct)
- `baton--session-counters` -- hash-table (agent-type symbol -> integer counter)

### Status Observation

State is **derived fresh each watcher tick** — not accumulated via a state machine:

- `running` -- output hash changed since last tick (or `:status-function` returns `:running`)
- `waiting` -- output has been stable ≥ 0.5s AND `:status-function` returns `:waiting`
- `error` -- output has been stable ≥ 0.5s AND `:status-function` returns `:error`
- `other` -- output has been stable ≥ 0.5s AND `:status-function` returns `:other`
- `idle` -- output has been stable ≥ 0.5s AND `:status-function` returns nil or `:idle`

When a session's process exits, the vterm buffer is killed and the watcher self-cancels. There is no `done` state.

### Unread Tracking

Session metadata tracks two hashes:
- `:current-hash` -- MD5 of last 250 lines, updated every watcher tick
- `:last-seen-hash` -- hash saved while the buffer is visible in any window

`baton-session-unread-p` returns `t` when the buffer is not currently visible and `:current-hash ≠ :last-seen-hash`. This is purely computed — no stored boolean flag.

### Alert Backend Registry (`baton-alert--backends`)

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

### Hooks

- `baton-session-created-hook` -- args: `(session)`
- `baton-session-killed-hook` -- args: `(session)`
- `baton-session-status-changed-hook` -- args: `(session old-status new-status)`
- `baton-session-unread-changed-hook` -- args: `(session)` — fires on read→unread transition

These are wired up by `baton--setup-hooks` when `baton-mode` is enabled.

## Architecture Overview

### Output Watcher

The watcher is a repeating timer (0.5s interval) per session. On each tick:
1. Read last 250 lines of the vterm buffer; MD5-hash the text
2. Update `:current-hash` in metadata
3. If hash changed: update `:last-output-time`; derive status `running`
4. If hash stable ≥ 0.5s AND trigger is `:periodic`: call `:status-function` with the session struct; dispatch on keyword: `:waiting` -> waiting, `:running` -> running, `:error` -> error, `:other` -> other, nil/unknown -> idle. For `:on-event` sessions the watcher skips the status function call and falls through to idle.
5. `set-status` is guarded — only fires the hook when state or reason actually changes
6. If buffer is visible in any window: update `:last-seen-hash` (marks session read)
7. Fire `baton-session-unread-changed-hook` if session transitioned read→unread this tick
8. Call `force-mode-line-update t` to keep unread counts current

The `:status-function` takes `(SESSION)` (a `baton--session` struct), returns `(cons KEYWORD REASON)` or `nil`. Use `baton-process-session-tail` inside a status function to get the last 250 lines of buffer text. `baton-process-make-regex-status-function` builds a pattern-based status function that calls `baton-process-session-tail` automatically. The watcher only invokes the status function for `:periodic` agents; `:on-event` agents will be driven by external hooks (not yet implemented).

### Notification Surface

- **Modeline**: `baton-notify--modeline-string` returns `" B[Nw/Ni/Nr/Ne/No N*]"` — zero counts omitted, `N*` only when unread > 0, alert face (yellow) when waiting > 0 or error > 0, clickable
- **Status buffer**: `*Baton*` -- `tabulated-list-mode` derivative with ibuffer-style mark/kill/jump; idle sessions show `○` indicator, `○*` when unread
- **Desktop alerts**: `baton-alert--dispatch` (installed by `baton-alert--setup`) replaces `baton-notify-function` — called on `waiting` transitions, and on unread transitions for all statuses (including `error` and `other`). Tries backends in priority order; handler errors are caught by `condition-case-unless-debug` to avoid breaking the watcher timer.

### Monet Integration (Optional)

`baton-monet.el` intercepts monet's `openDiff` tool via `monet-make-tool :set :baton`. When Claude Code requests a diff review:
1. Finds the baton session matching the monet session's directory
2. Sets it to `waiting` with reason `"diff review"`
3. Wraps monet's accept/quit callbacks to reset the baton session to `running`
4. Delegates to `monet-make-open-diff-handler` with a custom diff function that wraps the callbacks

`baton-mode` automatically calls `baton-monet-setup` when monet is loaded (via `with-eval-after-load`).

## Development Workflow

### Install dependencies

Ensure `vterm` is installed in your Emacs. Optionally clone monet to `../monet`.

### Run tests

```bash
make test                        # all tests in test/ directory (1 skipped without monet)
make test MATCH=monet            # run only tests matching "monet"
make test MONET_DIR=../monet     # include monet for full coverage
```

### Byte-compile

```bash
make compile                     # clean + byte-compile; vterm warnings suppressed
```

### Checkdoc

```bash
make checkdoc                    # lint all .el files (suppresses "should be imperative")
```

### Run a single test interactively

```
M-x ert RET baton-test-session-create-returns-struct RET
```

## Critical Idiosyncrasies & Gotchas

1. **vterm buffers are NOT space-prefixed** (e.g., `"*baton:claude-1*"`). They appear in the buffer list. The space-prefix was deliberately removed: vterm's C module applies colors via the `font-lock-face` text property, which requires `font-lock-mode` to be active; `global-font-lock-mode` skips space-prefixed buffers entirely, causing all color rendering to silently fail.

2. **Pattern matching requires quiet period**. The watcher only checks patterns after 500ms of no output change. This debounce prevents false positives on streaming output.

3. **State is derived, not accumulated**. Every watcher tick re-derives the status from current observations. `set-status` is guarded to only fire the hook when status/reason actually changes — so `idle` sessions don't spam the hook every 0.5s.

4. **`baton-process--on-input` resets the quiet-period clock**. When the user types in any non-running session, `:last-output-time` is reset to now and the session is set to `running`, preventing the watcher from immediately re-deriving the prior state before the agent has had a chance to respond.

5. **Unread is purely computed** via `baton-session-unread-p` — no stored flag. It compares `:current-hash` (updated each tick) to `:last-seen-hash` (updated while buffer is visible). The `baton-session-unread-changed-hook` is fired only on the first tick where a session transitions from read to unread.

6. **The test isolation macro `baton-test-with-clean-state`** lives in `test/baton-test-helpers.el`. It rebinds all global state (sessions, counters, agent-types, hooks including `baton-session-unread-changed-hook`) with `let`. Always use it in tests to avoid cross-contamination.

7. **The monet test requires monet** (`skip-unless (featurep 'monet)`). Set `MONET_DIR=../monet` in make invocations for full test coverage.

8. **`baton-monet.el` wraps monet callbacks** by passing a custom diff function to `monet-make-open-diff-handler` that intercepts accept/quit to reset baton session status.

9. **`baton-mode` is a global minor mode**. Enabling it wires hooks, enables `baton-modeline-mode`, installs `baton-alert--dispatch` as the notify function, and sets up the monet bridge. Disabling it tears down hooks, reverts `baton-notify-function`, and the modeline.

10. **No `:lighter` on `baton-mode`**. The modeline indicator comes from `baton-modeline-mode` which adds to `global-mode-string`, not from the mode lighter.

11. **Session auto-naming** uses the first segment of the agent-type symbol name (e.g., `claude-code` -> `"claude-1"`). The counter is per agent-type. `C-u baton-new` prompts for an explicit name.

12. **`baton-monet--find-session`** prefers `claude-code` sessions when multiple sessions share a directory. This is intentional -- monet integration is specific to Claude Code.

13. **Duplicate session names are rejected**. `baton-session-create` signals an error if a session with the given name already exists. There is no separate `id` field -- `name` is the unique identifier and registry key.

14. **Monet `ideName` format** in lockfiles is `"Emacs (<session-key> @ <port>)"`, not just `"Emacs (<session-key>)"`. The port disambiguates multiple Emacs instances.

15. **The `notifications` package is lazy-loaded** (`require 'notifications nil t`) inside the backend predicate to avoid load errors on macOS where D-Bus is unavailable. `declare-function notifications-notify` silences the byte-compiler.

16. **OSC 777 terminal injection prevention**. `baton-alert--sanitize-terminal` strips all control characters from title/body before embedding in the escape sequence. This guards against session names or waiting-reasons containing escape codes.

17. **Alert handler errors are caught** by `condition-case-unless-debug` in `baton-alert--dispatch`. A failing backend logs once to `*Messages*` but does not propagate into the watcher timer.

18. **All `baton-alert--` symbols are private** by double-dash convention. The API is architected for future promotion to public (single-dash) naming but is not yet stable.

## Style Conventions

- All files use `lexical-binding: t`
- Private symbols use double-dash (`baton--session`, `baton-process--match-patterns`)
- Public API uses single-dash (`baton-session-create`, `baton-jump`)
- Hooks follow `<package>-<noun>-<event>-hook` naming
- All `defvar` and `defun` have docstrings (enforced by `make checkdoc`)
- `cl-lib` is used throughout (`cl-defstruct`, `cl-defun`, `cl-find`, `cl-remove-if-not`, `cl-letf`)
- `when-let*` is preferred over nested `when`/`let` for nil-guarded bindings
- No `require 'vterm` at top level -- only inside functions that need it (`baton-process-spawn`)
- Optional dependencies use `declare-function` for byte-compiler silence + `featurep` guards at runtime

## User Commands & Transient Dispatch

Invoke via `M-x baton` or bind with `(global-set-key (kbd "C-c b") #'baton)`.

`baton` is a `transient-define-prefix` with these groups:

**Sessions** (infixes apply to the next `baton-new` only):

| Key  | Command / Infix          | Description                                      |
|------|--------------------------|--------------------------------------------------|
| `-a` | `baton--agent-infix`    | Agent for this spawn (ephemeral)                 |
| `-n` | `baton--name-infix`     | Session name for this spawn (ephemeral)          |
| `n`  | `baton-new`             | Spawn a new agent session                        |
| `k`  | `baton-kill`            | Kill a session by name                           |
| `K`  | `baton-kill-all`        | Kill all sessions                                |

**Navigate**:

| Key  | Command                  | Description                                      |
|------|--------------------------|--------------------------------------------------|
| `l`  | `baton-list`            | Open `*Baton*` status buffer                    |
| `j`  | `baton-jump`            | Jump to any session (completing-read)            |
| `w`  | `baton-jump-to-waiting` | Jump to a waiting session                        |

**Diff Review** (only shown when monet is loaded; `r` is greyed out when no pending diff):

| Key  | Command                  | Description                                      |
|------|--------------------------|--------------------------------------------------|
| `r`  | `baton-review-diff`     | Open pending diff                                |

**Configure**:

| Key  | Infix                         | Description                                      |
|------|-------------------------------|--------------------------------------------------|
| `-d` | `baton--default-agent-infix` | Persistent default agent for `baton-new`         |

Status buffer keybindings (`baton-list-mode-map`): `d` flag delete, `x` execute, `RET` jump, `N` new, `g` refresh, `m`/`u`/`U` mark/unmark, `r` review pending diff.