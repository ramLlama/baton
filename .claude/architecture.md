# Architecture

## Output Watcher

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

## Notification Surface

- **Modeline**: `baton-notify--modeline-string` returns `" B[Nw/Ni/Nr/Ne/No N*]"` — zero counts omitted, `N*` only when unread > 0, alert face (yellow) when waiting > 0 or error > 0, clickable
- **Status buffer**: `*Baton*` -- `tabulated-list-mode` derivative with ibuffer-style mark/kill/jump; idle sessions show `○` indicator, `○*` when unread
- **Desktop alerts**: `baton-alert--dispatch` (installed by `baton-alert--setup`) replaces `baton-notify-function` — called on `waiting` transitions, and on unread transitions for all statuses (including `error` and `other`). Tries backends in priority order; handler errors are caught by `condition-case-unless-debug` to avoid breaking the watcher timer.

## Monet Integration (Optional)

`baton-monet.el` intercepts monet's `openDiff` tool via `monet-make-tool :set :baton`. When Claude Code requests a diff review:
1. Finds the baton session matching the monet session's directory
2. Sets it to `waiting` with reason `"diff review"`
3. Wraps monet's accept/quit callbacks to reset the baton session to `running`
4. Delegates to `monet-make-open-diff-handler` with a custom diff function that wraps the callbacks

`baton-mode` automatically calls `baton-monet-setup` when monet is loaded (via `with-eval-after-load`).
