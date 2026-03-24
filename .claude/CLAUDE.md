# Birbal

## What This Project Does

Birbal is an Emacs Lisp package for managing multiple AI coding agents (Claude Code, Aider, Codex, Gemini CLI, etc.) from a unified interface inside Emacs. Agents run in vterm terminal buffers. Birbal monitors their output for status transitions (running/waiting/done) and surfaces status via a modeline badge, a tabulated-list status buffer, and optional OS notifications.

## Tech Stack

- **Language**: Emacs Lisp (lexical-binding throughout)
- **Emacs minimum**: 29.1
- **Required dependency**: vterm (>= 0.0.2) -- agents run in vterm buffers
- **Optional dependency**: monet (sibling repo at `../monet`) -- diff review integration
- **Testing**: ERT (Emacs Regression Testing framework)
- **Build**: GNU Make (`make checkdoc`, `make compile`, `make test`)

## Repository Structure

```
birbal/
  birbal-session.el    -- Session struct (cl-defstruct), hash-table registries, lifecycle hooks
  birbal-process.el    -- vterm spawning, 500ms debounced output watcher, pure pattern matcher
  birbal-notify.el     -- Modeline segment B[running/waiting], *Birbal* tabulated-list buffer, birbal-jump
  birbal-bridge.el     -- Optional monet integration: overrides openDiff tool for diff-review awareness
  birbal.el            -- Agent-type registry, birbal-mode global minor mode, user commands, keymaps
  birbal-tests.el      -- ERT test suite (31 tests; 1 skipped without monet)
  Makefile             -- checkdoc / compile / test targets
  .gitignore           -- *.elc
  .claude/
    settings.local.json -- Allowed bash commands for Claude Code
```

## Load Order

Strict require chain -- each file requires only what it needs:

1. `birbal-session` -- no birbal dependencies (requires only `cl-lib`)
2. `birbal-process` -- requires `birbal-session`
3. `birbal-notify` -- requires `birbal-session`
4. `birbal-bridge` -- requires `birbal-session` (monet symbols are `declare-function` only)
5. `birbal` -- requires `birbal-session`, `birbal-process`, `birbal-notify`; conditionally loads `birbal-bridge`

## Key Concepts & Domain Model

### Session (`birbal--session`)

The central data structure. A `cl-defstruct` with fields:
- `id` -- unique timestamp-based string
- `name` -- display name (auto-generated as `"<agent-prefix>-<n>"` or user-provided)
- `agent-type` -- symbol key into `birbal-agent-types` (e.g., `'claude-code`, `'aider`)
- `command`, `directory`, `buffer` -- the shell command, working dir, and vterm buffer
- `status` -- one of: `running`, `waiting`, `idle`, `done`, `error`
- `waiting-reason` -- string describing why the agent is waiting (e.g., "permission prompt")
- `metadata` -- plist for internal state (`:watcher-timer`, `:last-output-hash`, `:last-output-time`)

### Agent-Type Registry (`birbal-agent-types`)

A hash-table (`eq` test) mapping agent-type symbols to definition plists. Each plist has:
- `:command` -- shell command string
- `:args` -- default argument list
- `:waiting-patterns` -- alist of `(REGEXP . REASON)` for detecting "needs attention"
- `:done-patterns` -- list of regexps for detecting session completion

Register new types with `birbal-define-agent-type`. Three built-in: `claude-code`, `aider`, `codex`.

### Session Registries

- `birbal--sessions` -- hash-table (string ID -> session struct)
- `birbal--session-counters` -- hash-table (agent-type symbol -> integer counter)

### Status Lifecycle

```
running  -->  waiting  (output matches a waiting-pattern after 500ms quiet)
waiting  -->  running  (user types in the vterm buffer, or birbal-send-*)
running  -->  done     (output matches a done-pattern after 500ms quiet)
*        -->  running  (reset via birbal-process--reset-to-running)
```

### Hooks

- `birbal-session-created-hook` -- args: `(session)`
- `birbal-session-killed-hook` -- args: `(session)`
- `birbal-session-status-changed-hook` -- args: `(session old-status new-status)`

These are wired up by `birbal--setup-hooks` when `birbal-mode` is enabled.

## Architecture Overview

### Output Watcher

The watcher is a repeating timer (0.5s interval) per session. On each tick:
1. Read last 250 lines of the vterm buffer
2. MD5-hash the text; if changed, update `:last-output-time`
3. If output has been quiet >= 0.5s, run pattern matching
4. `birbal-process--match-patterns` checks waiting-patterns first (priority), then done-patterns
5. On match, call `birbal-session-set-status` which fires the status-changed hook

The pattern matcher (`birbal-process--match-patterns`) is **pure** -- no vterm dependency, fully unit-testable.

### Notification Surface

- **Modeline**: `birbal-notify--modeline-string` returns `" B[<running>/<waiting>]"`, clickable
- **Status buffer**: `*Birbal*` -- `tabulated-list-mode` derivative with ibuffer-style mark/kill/jump
- **Notification function**: `birbal-notify-function` (default: echo-area message)

### Monet Bridge (Optional)

`birbal-bridge.el` intercepts monet's `openDiff` tool via `monet-make-tool :set :birbal`. When Claude Code requests a diff review:
1. Finds the birbal session matching the monet session's directory
2. Sets it to `waiting` with reason `"diff review"`
3. Wraps monet's accept/quit callbacks to reset the birbal session to `running`
4. Uses `cl-letf` to temporarily advise `monet-simple-diff-tool` for callback wrapping

`birbal-mode` automatically calls `birbal-bridge-setup` when monet is loaded (via `with-eval-after-load`).

## Development Workflow

### Install dependencies

Ensure `vterm` is installed in your Emacs. Optionally clone monet to `../monet`.

### Run tests

```bash
make test                        # all tests (30 pass, 1 skipped without monet)
make test MATCH=bridge           # run only tests matching "bridge"
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
M-x ert RET birbal-test-session-create-returns-struct RET
```

## Critical Idiosyncrasies & Gotchas

1. **vterm buffers are space-prefixed** (e.g., `" *birbal-vterm-<id>*"`). This hides them from the buffer list. Use `birbal-list` or `birbal-jump` to navigate to them.

2. **Pattern matching requires quiet period**. The watcher only checks patterns after 500ms of no output change. This debounce prevents false positives on streaming output.

3. **Waiting patterns take priority over done patterns** in `birbal-process--match-patterns`. If both match, the session transitions to `waiting`, not `done`.

4. **The test isolation macro `birbal-test-with-clean-state`** rebinds all global state (sessions, counters, agent-types, hooks) with `let`. Always use it in tests to avoid cross-contamination.

5. **The bridge test requires monet** (`skip-unless (featurep 'monet)`). Set `MONET_DIR=../monet` in make invocations for full test coverage.

6. **`birbal-bridge.el` uses `cl-letf` for temporary function advice** on `monet-simple-diff-tool`. This is scoped and does not persist.

7. **`birbal-mode` is a global minor mode**. Enabling it wires hooks, enables `birbal-modeline-mode`, and sets up the monet bridge. Disabling it tears down hooks and the modeline.

8. **No `:lighter` on `birbal-mode`**. The modeline indicator comes from `birbal-modeline-mode` which adds to `global-mode-string`, not from the mode lighter.

9. **Session auto-naming** uses the first segment of the agent-type symbol name (e.g., `claude-code` -> `"claude-1"`). The counter is per agent-type.

10. **`birbal-bridge--find-session`** prefers `claude-code` sessions when multiple sessions share a directory. This is intentional -- monet integration is specific to Claude Code.

## Style Conventions

- All files use `lexical-binding: t`
- Private symbols use double-dash (`birbal--session`, `birbal-process--match-patterns`)
- Public API uses single-dash (`birbal-session-create`, `birbal-jump`)
- Hooks follow `<package>-<noun>-<event>-hook` naming
- All `defvar` and `defun` have docstrings (enforced by `make checkdoc`)
- `cl-lib` is used throughout (`cl-defstruct`, `cl-defun`, `cl-find`, `cl-remove-if-not`, `cl-letf`)
- `when-let*` is preferred over nested `when`/`let` for nil-guarded bindings
- No `require 'vterm` at top level -- only inside functions that need it (`birbal-process-spawn`)
- Optional dependencies use `declare-function` for byte-compiler silence + `featurep` guards at runtime

## User Commands & Keymap

Interactive commands (bind `birbal-global-map` under a prefix, e.g., `C-c b`):

| Key | Command                  | Description                          |
|-----|--------------------------|--------------------------------------|
| `n` | `birbal-new`             | Spawn a new agent session            |
| `k` | `birbal-kill`            | Kill a session by name               |
| `K` | `birbal-kill-all`        | Kill all sessions                    |
| `l` | `birbal-list`            | Open `*Birbal*` status buffer        |
| `j` | `birbal-jump`            | Jump to any session (completing-read)|
| `w` | `birbal-jump-to-waiting` | Jump to a waiting session            |
| `r` | `birbal-send-return`     | Send RET to a session                |
| `e` | `birbal-send-escape`     | Send ESC to a session                |

Status buffer keybindings (`birbal-list-mode-map`): `d` flag delete, `x` execute, `RET` jump, `N` new, `g` refresh, `m`/`u`/`U` mark/unmark.