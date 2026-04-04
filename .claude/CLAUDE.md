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
  Makefile             -- checkdoc / compile / test / pre-commit targets; TEST_FILES variable
  .gitignore           -- *.elc
  .claude/
    CLAUDE.md           -- This file
    domain-model.md     -- Session struct, agent registry, status observation, unread, hooks
    architecture.md     -- Output watcher, notification surface, monet integration
    gotchas.md          -- Critical idiosyncrasies and non-obvious behaviors
    commands.md         -- User commands and transient dispatch reference
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

## Further Reading

- **[domain-model.md](domain-model.md)** -- Session struct, agent registry, status observation, unread tracking, alert backends, hooks
- **[architecture.md](architecture.md)** -- Output watcher algorithm, notification surface, monet integration
- **[gotchas.md](gotchas.md)** -- Critical idiosyncrasies and non-obvious behaviors (18 items)
- **[commands.md](commands.md)** -- User commands and transient dispatch keybindings
