# Architecture

## Output Watcher

The watcher is a repeating timer (0.5s interval) started **only for `:periodic` sessions** (`baton-process--start-watcher` checks `:status-function-trigger` in `baton-agents`). Sessions with `:on-event` trigger do not get a watcher timer at all — their status is driven entirely by external hooks.

The tick function is `baton-process--state-tick`. On each tick:
1. Read last 250 lines of the vterm buffer; MD5-hash the text
2. If hash changed: update `:last-output-hash` and `:last-output-time`; derive status `running`
3. If hash stable ≥ 0.5s AND trigger is `:periodic`: call `:status-function` with the session struct; dispatch on plain symbol: `waiting` -> waiting, `running` -> running, `error` -> error, `other` -> other, nil/unknown -> idle
4. Status writes go through `baton-process--tick-set-status`, which calls `baton-session-set-status` and additionally writes a `:state` plist `(:status SYMBOL :reason STRING-OR-NIL :at FLOAT-TIME)` into session metadata — but only when status actually changed (detected by comparing `updated-at` before and after the `set-status` call). This `:state` metadata is consumed by the global notification timer.

The watcher does **not** handle unread tracking, modeline updates, or notification scheduling — those responsibilities moved to the global notification timer (see below).

The `:status-function` takes `(SESSION)` (a `baton--session` struct), returns `(cons SYMBOL REASON)` where SYMBOL is a plain symbol (`waiting`, `running`, `error`, `other`, `idle`) -- not a keyword. Returns `nil` to mean idle. Use `baton-process-session-tail` inside a status function to get the last 250 lines of buffer text. `baton-process-make-regex-status-function` builds a pattern-based status function that calls `baton-process-session-tail` automatically.

### Metadata Initialization

`baton-process-spawn` initializes session metadata to: `:last-output-time NOW :last-output-hash "" :state nil :unread nil :notified-at nil`.

## Notification Surface

- **Modeline**: `baton-notify--modeline-string` returns `" B[Nw/Ni/Nr/Ne/No N*]"` — zero counts omitted, `N*` only when unread > 0, alert face (yellow) when waiting > 0 or error > 0, clickable
- **Status buffer**: `*Baton*` -- `tabulated-list-mode` derivative with ibuffer-style mark/kill/jump; idle sessions show `○` indicator, `○*` when unread
- **Desktop alerts**: `baton-alert--dispatch` (installed by `baton-alert--setup`) replaces `baton-notify-function` — called on `waiting` transitions, and on unread transitions for `error`, `other`, and `idle` statuses. Tries backends in priority order; handler errors are caught by `condition-case-unless-debug`.

### Unread Tracking

Unread state is a boolean `:unread` flag in session metadata (read via `baton-session-unread-p`).

- **Marking unread**: `baton-notify--on-status-changed-mark-unread` runs on `baton-session-status-changed-hook`. When a session transitions to `waiting`/`idle`/`error`/`other` and its buffer is not visible, it sets `:unread t` and fires `baton-session-unread-changed-hook`.
- **Clearing unread**: The global timer (`baton-notify--global-tick`) clears `:unread` to nil for any session whose buffer is currently visible in a window, and fires `baton-session-unread-changed-hook`.

### Global Notification Timer

A single 0.5s repeating timer (`baton-notify--global-timer`) replaces the previous per-session idle timers. Started by `baton-notify--start-global-timer` (called from `baton--setup-hooks`), stopped by `baton-notify--stop-global-timer` (called from `baton--teardown-hooks`).

On each tick (`baton-notify--global-tick`):
1. For each session: clear `:unread` if its buffer is visible (see above)
2. Fire `baton-notify--maybe-notify` after `baton-notify-delay` seconds (defcustom, default 5) of `:state` stability — specifically when: `(- now state-at) >= delay` AND `state-at > notified-at` AND `:state :status` matches the session's current live status (guards against stale `:state` when user input resets to `running` before delay elapses)
3. On successful notification, stamp `:notified-at` in metadata to prevent re-firing
4. Call `force-mode-line-update t`

`baton-notify--maybe-notify` fires `baton-notify-function` when status is `waiting`, or status is `error`/`other`/`idle` with `:unread` set.

## Monet Integration (Optional)

`baton-monet.el` provides two integration paths with monet:

### openDiff Tool Override

Intercepts monet's `openDiff` tool via `monet-make-tool :set :baton`. When Claude Code requests a diff review:
1. Finds the baton session matching the monet session's directory
2. Sets it to `waiting` with reason `"diff review"`
3. Wraps monet's accept/quit callbacks to reset the baton session to `running`
4. Delegates to `monet-make-open-diff-handler` with a custom diff function that wraps the callbacks

### Event-Driven Status via Hook Handler

For `:on-event` agents (claude-code when monet is active), status is driven by monet hook events instead of the periodic watcher:

1. **Env propagation**: `baton-monet--session-env-function` is registered as an `:env-function` for claude-code. It injects `MONET_CTX_baton_session=<session-name>` into the agent's environment, allowing monet to include the session name in hook event context.
2. **Hook dispatch**: `baton-monet--claude-hook-handler` is registered with monet and receives `(EVENT-NAME DATA CTX)`. It looks up the baton session from the `baton_session` key in CTX, then dispatches:
   - `UserPromptSubmit` -> `running`
   - `Stop` -> `idle`
   - `Notification` -> `waiting` (with reason from data)
   - Skips dispatch if `:pending-diff` is set on the session metadata
3. **State management**: `baton-monet--set-state` writes a `:state` plist `(:status SYMBOL :reason STRING :at FLOAT-TIME)` into session metadata, then calls `baton-session-set-status` to propagate the change. (The same `:state` plist format is written by `baton-process--tick-set-status` for `:periodic` agents.)
4. **Status function**: `baton-monet--hook-status-fn` reads `:state` from metadata and returns `(SYMBOL . REASON)` using plain symbols.

### Setup and Teardown

`baton-monet-setup` saves claude-code's original `:status-function` and `:status-function-trigger`, then switches claude-code to `:on-event` trigger with `baton-monet--hook-status-fn`. It also registers the env-function and hook handler.

`baton-monet--teardown` (called when `baton-mode` is disabled) reverses all of this: deregisters the hook handler, removes the review-bar hook, clears the "r" keybinding, and restores claude-code's original status-function and trigger.

`baton-mode` automatically calls `baton-monet-setup` when monet is loaded (via `with-eval-after-load`) and calls `baton-monet--teardown` on disable when `baton-monet` is loaded.
