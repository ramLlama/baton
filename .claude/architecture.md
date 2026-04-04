# Architecture

## Output Watcher

The watcher is a repeating timer (0.5s interval) per session. On each tick:
1. Read last 250 lines of the vterm buffer; MD5-hash the text
2. Update `:current-hash` in metadata
3. If hash changed: update `:last-output-time`; derive status `running`
4. If hash stable ≥ 0.5s AND trigger is `:periodic`: call `:status-function` with the session struct; dispatch on plain symbol: `waiting` -> waiting, `running` -> running, `error` -> error, `other` -> other, nil/unknown -> idle. For `:on-event` sessions the watcher skips the status function call and falls through to idle.
5. `set-status` is guarded — only fires the hook when state or reason actually changes
6. If buffer is visible in any window: update `:last-seen-hash` (marks session read)
7. Fire `baton-session-unread-changed-hook` if session transitioned read→unread this tick
8. Call `force-mode-line-update t` to keep unread counts current

The `:status-function` takes `(SESSION)` (a `baton--session` struct), returns `(cons SYMBOL REASON)` where SYMBOL is a plain symbol (`waiting`, `running`, `error`, `other`, `idle`) -- not a keyword. Returns `nil` to mean idle. Use `baton-process-session-tail` inside a status function to get the last 250 lines of buffer text. `baton-process-make-regex-status-function` builds a pattern-based status function that calls `baton-process-session-tail` automatically. The watcher only invokes the status function for `:periodic` agents; `:on-event` agents are driven by external hooks (see Monet Integration below).

## Notification Surface

- **Modeline**: `baton-notify--modeline-string` returns `" B[Nw/Ni/Nr/Ne/No N*]"` — zero counts omitted, `N*` only when unread > 0, alert face (yellow) when waiting > 0 or error > 0, clickable
- **Status buffer**: `*Baton*` -- `tabulated-list-mode` derivative with ibuffer-style mark/kill/jump; idle sessions show `○` indicator, `○*` when unread
- **Desktop alerts**: `baton-alert--dispatch` (installed by `baton-alert--setup`) replaces `baton-notify-function` — called on `waiting` transitions, and on unread transitions for all statuses (including `error` and `other`). Tries backends in priority order; handler errors are caught by `condition-case-unless-debug` to avoid breaking the watcher timer.

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
3. **State management**: `baton-monet--set-state` writes a `:state` plist `(:status SYMBOL :reason STRING :at FLOAT-TIME)` into session metadata, then calls `baton-session-set-status` to propagate the change.
4. **Status function**: `baton-monet--hook-status-fn` reads `:state` from metadata and returns `(SYMBOL . REASON)` using plain symbols.

### Setup and Teardown

`baton-monet-setup` saves claude-code's original `:status-function` and `:status-function-trigger`, then switches claude-code to `:on-event` trigger with `baton-monet--hook-status-fn`. It also registers the env-function and hook handler.

`baton-monet--teardown` (called when `baton-mode` is disabled) reverses all of this: deregisters the hook handler, removes the review-bar hook, clears the "r" keybinding, and restores claude-code's original status-function and trigger.

`baton-mode` automatically calls `baton-monet-setup` when monet is loaded (via `with-eval-after-load`) and calls `baton-monet--teardown` on disable when `baton-monet` is loaded.
