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
  baton-monet.el      -- Optional monet integration: overrides openDiff tool for diff-review awareness
  baton.el            -- Agent-type registry, baton-mode global minor mode, user commands, keymaps
  baton-tests.el      -- ERT test suite (41 tests; 1 skipped without monet)
  Makefile             -- checkdoc / compile / test targets
  .gitignore           -- *.elc
  .claude/
    settings.local.json -- Allowed bash commands for Claude Code
```

## Load Order

Strict require chain -- each file requires only what it needs:

1. `baton-session` -- no baton dependencies (requires only `cl-lib`)
2. `baton-process` -- requires `baton-session`
3. `baton-notify` -- requires `baton-session`
4. `baton-monet` -- requires `baton-session` (monet symbols are `declare-function` only)
5. `baton` -- requires `baton-session`, `baton-process`, `baton-notify`; conditionally loads `baton-monet`

## Key Concepts & Domain Model

### Session (`baton--session`)

The central data structure. A `cl-defstruct` with fields:
- `name` -- unique string, also the registry key (auto-generated as `"<agent-prefix>-<n>"` or user-provided). Duplicates are rejected at creation time with an error.
- `agent-type` -- symbol key into `baton-agent-types` (e.g., `'claude-code`, `'aider`)
- `command`, `directory`, `buffer` -- the shell command, working dir, and vterm buffer
- `status` -- one of: `running`, `waiting`, `idle`
- `waiting-reason` -- string describing why the agent is waiting (e.g., "permission prompt")
- `created-at`, `updated-at` -- `float-time` timestamps
- `metadata` -- plist for internal state (`:watcher-timer`, `:last-output-hash`, `:last-output-time`, `:current-hash`, `:last-seen-hash`)

### Agent-Type Registry (`baton-agent-types`)

A hash-table (`eq` test) mapping agent-type symbols to definition plists. Each plist has:
- `:command` -- shell command string
- `:args` -- default argument list
- `:waiting-patterns` -- alist of `(REGEXP . REASON)` for detecting "needs attention"

Register new types with `baton-define-agent-type`. Three built-in: `claude-code`, `aider`, `codex`.

### Session Registries

- `baton--sessions` -- hash-table (session name string -> session struct)
- `baton--session-counters` -- hash-table (agent-type symbol -> integer counter)

### Status Observation

State is **derived fresh each watcher tick** — not accumulated via a state machine:

- `running` -- output hash changed since last tick
- `waiting` -- output has been stable ≥ 0.5s AND a waiting pattern matches
- `idle` -- output has been stable ≥ 0.5s AND no waiting pattern matches

When a session's process exits, the vterm buffer is killed and the watcher self-cancels. There is no `done` state.

### Unread Tracking

Session metadata tracks two hashes:
- `:current-hash` -- MD5 of last 250 lines, updated every watcher tick
- `:last-seen-hash` -- hash saved while the buffer is visible in any window

`baton-session-unread-p` returns `t` when the buffer is not currently visible and `:current-hash ≠ :last-seen-hash`. This is purely computed — no stored boolean flag.

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
4. If hash stable ≥ 0.5s: run `baton-process--match-patterns`; derive `waiting` or `idle`
5. `set-status` is guarded — only fires the hook when state or reason actually changes
6. If buffer is visible in any window: update `:last-seen-hash` (marks session read)
7. Fire `baton-session-unread-changed-hook` if session transitioned read→unread this tick
8. Call `force-mode-line-update t` to keep unread counts current

The pattern matcher (`baton-process--match-patterns`) is **pure** -- takes `(text waiting-patterns)`, returns `(cons :waiting REASON)` or `nil`. No vterm dependency, fully unit-testable.

### Notification Surface

- **Modeline**: `baton-notify--modeline-string` returns `" B[Nw/Ni/Nr N*]"` — zero counts omitted, `N*` only when unread > 0, yellow when waiting > 0, clickable
- **Status buffer**: `*Baton*` -- `tabulated-list-mode` derivative with ibuffer-style mark/kill/jump; idle sessions show `○` indicator, `○*` when unread
- **Notification function**: `baton-notify-function` (default: echo-area message) — called on `waiting` transitions and on unread transitions

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
make test                        # all tests (40 pass, 1 skipped without monet)
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

4. **`baton-process--on-input` resets the quiet-period clock**. When the user types in a `waiting` or `idle` session, `:last-output-time` is reset to now, preventing the watcher from immediately re-deriving the prior state before the agent has had a chance to respond.

5. **Unread is purely computed** via `baton-session-unread-p` — no stored flag. It compares `:current-hash` (updated each tick) to `:last-seen-hash` (updated while buffer is visible). The `baton-session-unread-changed-hook` is fired only on the first tick where a session transitions from read to unread.

6. **The test isolation macro `baton-test-with-clean-state`** rebinds all global state (sessions, counters, agent-types, hooks including `baton-session-unread-changed-hook`) with `let`. Always use it in tests to avoid cross-contamination.

7. **The monet test requires monet** (`skip-unless (featurep 'monet)`). Set `MONET_DIR=../monet` in make invocations for full test coverage.

8. **`baton-monet.el` wraps monet callbacks** by passing a custom diff function to `monet-make-open-diff-handler` that intercepts accept/quit to reset baton session status.

9. **`baton-mode` is a global minor mode**. Enabling it wires hooks, enables `baton-modeline-mode`, and sets up the monet bridge. Disabling it tears down hooks and the modeline.

10. **No `:lighter` on `baton-mode`**. The modeline indicator comes from `baton-modeline-mode` which adds to `global-mode-string`, not from the mode lighter.

11. **Session auto-naming** uses the first segment of the agent-type symbol name (e.g., `claude-code` -> `"claude-1"`). The counter is per agent-type. `C-u baton-new` prompts for an explicit name.

12. **`baton-monet--find-session`** prefers `claude-code` sessions when multiple sessions share a directory. This is intentional -- monet integration is specific to Claude Code.

13. **Duplicate session names are rejected**. `baton-session-create` signals an error if a session with the given name already exists. There is no separate `id` field -- `name` is the unique identifier and registry key.

14. **Monet `ideName` format** in lockfiles is `"Emacs (<session-key> @ <port>)"`, not just `"Emacs (<session-key>)"`. The port disambiguates multiple Emacs instances.

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

## User Commands & Keymap

Interactive commands (bind `baton-global-map` under a prefix, e.g., `C-c b`):

| Key | Command                  | Description                                      |
|-----|--------------------------|--------------------------------------------------|
| `n` | `baton-new`             | Spawn a new agent session; `C-u` prompts for name|
| `k` | `baton-kill`            | Kill a session by name                           |
| `K` | `baton-kill-all`        | Kill all sessions                                |
| `l` | `baton-list`            | Open `*Baton*` status buffer                    |
| `j` | `baton-jump`            | Jump to any session (completing-read)            |
| `w` | `baton-jump-to-waiting` | Jump to a waiting session                        |
| `d` | `baton-review-diff`     | Open pending diff (monet integration)            |

Status buffer keybindings (`baton-list-mode-map`): `d` flag delete, `x` execute, `RET` jump, `N` new, `g` refresh, `m`/`u`/`U` mark/unmark, `r` review pending diff.