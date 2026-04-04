# Critical Idiosyncrasies & Gotchas

1. **vterm buffers are NOT space-prefixed** (e.g., `"*baton:claude-1*"`). They appear in the buffer list. The space-prefix was deliberately removed: vterm's C module applies colors via the `font-lock-face` text property, which requires `font-lock-mode` to be active; `global-font-lock-mode` skips space-prefixed buffers entirely, causing all color rendering to silently fail.

2. **Pattern matching requires quiet period**. The watcher only checks patterns after 500ms of no output change. This debounce prevents false positives on streaming output.

3. **State is derived, not accumulated**. Every watcher tick re-derives the status from current observations. `set-status` is guarded to only fire the hook when status/reason actually changes — so `idle` sessions don't spam the hook every 0.5s.

4. **`baton-process--on-input` resets the quiet-period clock**. When the user types in any non-running session, `:last-output-time` is reset to now and the session is set to `running`, preventing the watcher from immediately re-deriving the prior state before the agent has had a chance to respond.

5. **Unread is a stored boolean flag** (`:unread` in session metadata), read by `baton-session-unread-p`. It is set to `t` by a `baton-session-status-changed-hook` handler when a non-running status arrives and the buffer is not visible, and cleared to `nil` by the global timer when the buffer becomes visible. `baton-session-unread-changed-hook` fires on both transitions.

6. **The test isolation macro `baton-test-with-clean-state`** lives in `test/baton-test-helpers.el`. It rebinds all global state (sessions, counters, agents, hooks including `baton-session-unread-changed-hook`) with `let`. Always use it in tests to avoid cross-contamination.

7. **The monet test requires monet** (`skip-unless (featurep 'monet)`). Set `MONET_DIR=../monet` in make invocations for full test coverage.

8. **`baton-monet.el` wraps monet callbacks** by passing a custom diff function to `monet-make-open-diff-handler` that intercepts accept/quit to reset baton session status.

9. **`baton-mode` is a global minor mode**. Enabling it wires hooks, enables `baton-modeline-mode`, installs `baton-alert--dispatch` as the notify function, and sets up the monet bridge. Disabling it tears down hooks, reverts `baton-notify-function`, and the modeline.

10. **No `:lighter` on `baton-mode`**. The modeline indicator comes from `baton-modeline-mode` which adds to `global-mode-string`, not from the mode lighter.

11. **Session auto-naming** uses the first segment of the agent symbol name (e.g., `claude-code` -> `"claude-1"`). The counter is per agent. `C-u baton-new` prompts for an explicit name.

12. **`baton-monet--find-session`** prefers `claude-code` sessions when multiple sessions share a directory. This is intentional -- monet integration is specific to Claude Code.

13. **Duplicate session names are rejected**. `baton-session-create` signals an error if a session with the given name already exists. There is no separate `id` field -- `name` is the unique identifier and registry key.

14. **Monet `ideName` format** in lockfiles is `"Emacs (<session-key> @ <port>)"`, not just `"Emacs (<session-key>)"`. The port disambiguates multiple Emacs instances.

15. **The `notifications` package is lazy-loaded** (`require 'notifications nil t`) inside the backend predicate to avoid load errors on macOS where D-Bus is unavailable. `declare-function notifications-notify` silences the byte-compiler.

16. **OSC 777 terminal injection prevention**. `baton-alert--sanitize-terminal` strips all control characters from title/body before embedding in the escape sequence. This guards against session names or waiting-reasons containing escape codes.

17. **Alert handler errors are caught** by `condition-case-unless-debug` in `baton-alert--dispatch`. A failing backend logs once to `*Messages*` but does not propagate into the watcher timer.

18. **All `baton-alert--` symbols are private** by double-dash convention. The API is architected for future promotion to public (single-dash) naming but is not yet stable.
