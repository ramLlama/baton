# Progress: Integrate monet Claude Hooks into Baton

## Plan Reference
`~/.claude/plans/elegant-strolling-donut.md`

## Status
Commit 1 (monet) complete. Commits 2–4 (baton) not started.

---

## Completed

### monet — Commit 0 (pre-commit hook)
- Added `pre-commit` Make target (`checkdoc + test`) to `/Users/ram/repos/monet/Makefile`
- Created `.git/hooks/pre-commit` calling `make pre-commit`
- Committed: `build: add pre-commit target and git hook`

### monet — Commit 1 (Python hook script + nested JSON + UserPromptSubmit)
- **New**: `monet-claude-hook.py` replaces `monet-claude-hook.sh`
  - Reads JSON payload from stdin; handles `JSONDecodeError` gracefully
  - Collects `MONET_CTX_*` env vars → ctx dict (prefix stripped, lowercased)
  - Wraps both in `{"hook_payload": ..., "monet_context": ...}` envelope
  - Escapes tmpfile path before Elisp interpolation (injection fix)
  - Logs emacsclient failures to stderr + exits with same return code
  - Cleans up temp file in `finally` block
- **`monet-claude-hook-receive`**: parses envelope; dispatches 3-arg `(event-name data ctx)`
- **`monet--log-hook(event-name data ctx)`**: new; logs to `*Monet Log*` under same
  `monet--logging-enabled` flag as MCP traffic; one formatted line per event
- **`monet-install-claude-hooks`** + **`monet-remove-claude-hooks`**: now include
  `UserPromptSubmit` alongside `Stop`, `SubagentStop`, `Notification`
- Tests updated: 3-arg handlers, envelope JSON format, `UserPromptSubmit` in install/remove tests
- `.claude/CLAUDE.md` and `.claude/hooks.md` updated in monet repo
- Committed: `feat(hooks): replace shell hook script with Python + nested envelope`

---

## Remaining

### Commit 2 — baton: status-fn API + `:status-function-trigger`
**Files**: `baton-process.el`, `baton.el`, `test/baton-process-tests.el`, `.claude/CLAUDE.md`

Key changes:
- **`baton-process-session-tail(session)`**: new public fn; returns last 250 lines of
  session's buffer as string, or `""` if buffer dead
- **`baton-process-make-regex-status-function`**: returned fn now takes `SESSION` (not
  `TEXT`); calls `baton-process-session-tail` internally
- **`baton-define-agent`**: new required key `:status-function-trigger` (`:periodic` or
  `:on-event`); signals error if absent
- All three built-in agents (`claude-code`, `aider`, `codex`): add `:status-function-trigger :periodic`
- **Watcher** (`baton-process--watcher-tick`): check `:status-function-trigger :periodic`
  before calling status-fn; call `(funcall status-fn session)` not `(funcall status-fn text)`
- **Tests**: all `baton-define-agent` calls need `:status-function-trigger`; lambda
  signatures change from `(_text)` to `(_session)`; `baton-test-agent-status-function`
  rewritten to use session+buffer; new tests for `baton-process-session-tail` (live/dead)
  and trigger behavior (`:on-event` skips fn)
- **`.claude/CLAUDE.md`**: `:status-function` takes `(SESSION)`; document
  `:status-function-trigger`; remove "pure" characterization

Note: at commit 2 entry point, `baton-process.el` has a partial edit already applied
(the `baton-process-session-tail` function and updated `baton-process-make-regex-status-function`
were written before context was cleared). Verify the file state before continuing — do
NOT re-apply those two functions. The watcher call site and `baton.el` / test changes
still need to be made.

### Commit 3 — baton: `:state` metadata field + hook integration
**Files**: `baton-process.el`, `baton-monet.el`, `baton.el`, `test/baton-monet-tests.el`

Key changes:
- `baton-process-spawn`: add `:state nil` to metadata init list
- **`baton-monet--hook-status-fn(session)`**: reads `:state` from metadata, returns
  `(cons status reason)` or nil
- **`baton-monet--set-state(session status &optional reason)`**: writes
  `(:status sym :reason str :at float-time)` into `:state` metadata AND calls
  `baton-session-set-status`
- **`baton-monet--session-env-function(session-name _dir)`**: returns
  `(list "MONET_CTX_baton_session=<name>")`
- **`baton-monet--claude-hook-handler(event-name _data ctx)`**: looks up session from
  `baton_session` in ctx; dispatches on event:
  - `"UserPromptSubmit"` → `set-state running`
  - `"Stop"` → `set-state idle`
  - `"Notification"` → `set-state waiting (or message "input prompt")`
  - skips if `:pending-diff` is set
- **`baton-monet--saved-claude-status-fn`** + **`baton-monet--saved-claude-trigger`**: defvars
  for saving/restoring claude-code's original status-fn and trigger
- **`baton-monet-setup`** additions: register env-function, hook handler, switch
  `claude-code` to `:on-event` + `baton-monet--hook-status-fn`
- **`baton-monet--teardown`**: deregister handler, restore saved status-fn + trigger
- **`baton.el`**: `declare-function baton-monet--teardown`; call in `baton-mode` disable branch
- Tests: add tests for set-state, hook handler events, no-session no-op, pending-diff
  preservation, setup/teardown (trigger + status-fn); update existing `baton-define-agent`
  calls to add `:status-function-trigger :periodic`

### Commit 4 — baton: watcher refactor + simplified unread + notification via :state
**Files**: `baton-process.el`, `baton-notify.el`, `baton-session.el`, `baton.el`,
all test files

Key changes:
- **`baton-process-spawn` metadata init**: remove `:current-hash`, `:last-seen-hash`;
  add `:unread nil`, `:notified-at nil` (`:state nil` already added in commit 3)
- **`baton-process--state-tick`** (replaces `baton-process--watcher-tick`):
  - Only started for `:periodic` sessions
  - Writes `:state (:status sym :reason str :at float-time)` on status change
  - No `force-mode-line-update`, no unread tracking
  - Handles `:pending-diff` (sets-state waiting "diff review" if not already)
- **`baton-session-unread-p`**: reads `:unread` boolean from metadata (not hash comparison)
- **`baton-notify-delay`**: new `defcustom` (replaces private `baton-notify--idle-delay` defconst = 5)
- **`baton-notify--on-status-changed-mark-unread(session _old _new)`**: sets `:unread t`
  when buffer not visible and not already unread; fires `baton-session-unread-changed-hook`
- **`baton-notify--maybe-notify(session)`**: replaces `baton-notify--pending-notify-callback`;
  same logic (notify if waiting, or non-running+unread)
- **`baton-notify--global-timer`** + **`baton-notify--global-tick`**: runs every 0.5s;
  clears `:unread` for visible sessions; fires notification after `baton-notify-delay` of
  stability (via `:state :at` vs `:notified-at`); calls `force-mode-line-update`
- Remove: `baton-notify--idle-delay`, `baton-notify--cancel-idle-timer`,
  `baton-notify--pending-notify-callback`, timer-scheduling in `baton-notify--on-status-changed`
- **`baton.el` hooks**: replace `baton-notify--on-status-changed` with
  `baton-notify--on-status-changed-mark-unread`; start/stop global timer in
  setup/teardown
- **Test updates**: all tests using `:current-hash`/`:last-seen-hash` → use `:unread`;
  watcher tick tests → call `baton-process--state-tick`, use new metadata layout;
  notify tests → rewrite timer-based tests for global tick approach;
  monet pending-diff test → update metadata layout

---

## Workflow Reminder
For each commit: implement → `code-reviewer` (background) → user reviews → `claude-context-architect` → commit → next