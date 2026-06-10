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

19. **Env-functions must return the `(:env STRINGS :ports PORTS)` plist shape**, or nil. A bare list of `"VAR=VALUE"` strings (the old contract) is now a **hard error** in `baton-executor--agent-env` — fail-fast with no legacy tolerance. Both keys are optional within the plist, but the top-level value must be a plist (first element a keyword) or nil.

20. **`:env-functions` are evaluated exactly once per spawn**, inside `baton-executor--resolve`. Earlier code evaluated them twice; do not reintroduce a second evaluation in `baton-process-spawn`, which is now executor-agnostic and treats the resolved `(:directory :command :extra-env)` plist as opaque.

21. **Executor teardown is registered at load time, not by `baton-mode`.** `baton-executor--teardown-on-kill` is added to `baton-session-killed-hook` when `baton-executor.el` loads, so it survives `baton-mode` toggles and runs even when the mode is off. Consequently, `baton-executor--teardown` implementations **must be idempotent** — do not assume exactly-once invocation.

22. **`baton-sodagun--run` parses the LAST JSON line, not all stdout.** sodagun prints its result as a single-line JSON object, but setup scripts may emit progress lines above it. The wrapper searches backward for `^{` and parses only that line. Two corollaries: (a) it always passes `--output json --quiet` *before* the subcommand, so sodagun emits machine-readable single-line JSON; (b) a non-zero exit *or* the absence of any `{`-line is a hard error carrying the shell-quoted command and captured output. Do not switch sodagun to pretty/multi-line JSON output — it would break the trailing-line parse.

23. **Worktree creation blocks Emacs.** `baton-sodagun--add-worktree` (invoked from `baton-new` when `-w` is set) runs `sodagun git add-worktree` via synchronous `call-process`, so Emacs is blocked until the worktree is ready. It also fails fast on missing/relative paths (missing `sodagun.json`, non-absolute `rootdir`/`worktree_path`) rather than spawning a session in the wrong directory — downstream code anchors sessions to those paths verbatim.

24. **Sandbox sessions keep the worktree on kill — only the sandbox is removed.** The `sodagun` executor's teardown stops-and-removes the microVM sandbox but deliberately leaves the git worktree on disk, so the agent's work survives the session. (Worktree GC, if any, is the user's / sodagun's concern, not baton's.)

25. **Sandbox teardown uses `sodagun sandbox remove`, not `stop`.** Removal stops *and* deletes the sandbox in one shot so stopped sandboxes don't accumulate. It runs **asynchronously** with a `:noquery t` process, and a non-zero exit is reported via `message` only — the kill flow must never block or error on cleanup.

26. **Sandbox durable state lives in `baton-sodagun--workspaces`, not session metadata.** `baton-new` stashes `:sodagun-branch`/`:sodagun-base` in session metadata *before* spawn, but `baton-process-spawn`'s metadata init clobbers the whole metadata plist. So `resolve` reads the stash early, then records everything teardown needs (rootdir, sandbox-name, ports, forwarder procs) in the `baton-sodagun--workspaces` registry. Don't move sandbox cleanup state into session metadata — it won't survive spawn.

27. **Sandbox env travels via attach `--env`, never the host `process-environment`.** The `sodagun` resolve returns `:extra-env nil`; the agent's `:env` strings are baked into the `sodagun sandbox attach … --env K=V …` command instead, so they reach the *guest* process. Don't try to deliver sandbox env through `:extra-env` (that prepends to the host environment, which the in-guest agent never sees).

28. **The forwarder-vs-agent-connect race is accepted.** Each port's in-guest socat forwarder is started before the agent attaches, but socat's listen setup races the agent's first connect. In practice the agent boots much slower, so it's a non-issue; a lost race surfaces in-guest as connection-refused on `127.0.0.1:PORT`. No explicit readiness handshake is done.

29. **Monet-in-sandbox needs the IDE lockfile bind-mounted into the guest.** Claude discovers the MCP server through the lockfile `~/.claude/ide/<Pm>.lock` (auth token + workspaceFolders) written on the *host*. The sandbox's `sodagun.toml` must bind-mount the host `~/.claude/ide` read-only into the guest at the same home-relative path, or Claude-in-guest never finds the server. This is the user's sodagun.toml responsibility, **not** baton's — baton writes the host-side lockfile via monet but does not provision the guest mount.

30. **The lockfile records the HOST worktree path, which the guest doesn't have.** The lockfile's `workspaceFolders` records the host worktree path (`R`/`W`), but the guest sees that worktree at the sandbox `working_dir` (e.g. `/workspace`). If Claude validates the folder path, this mismatch may need a guest-side rewrite. **Unverified — flagged as a known risk.**

31. **The guest image must ship `socat` and `python3`.** The per-port forwarders run `socat` via `sodagun sandbox exec` inside the guest, and monet's Claude hook script is a stdlib-only `python3` script that runs in-guest. Both must be present in the user's sandbox image — provisioning them is the user's image responsibility, not baton's.

32. **Guest Claude credentials/config are user-provisioned.** Claude's in-guest config and credentials (`~/.claude*`, API keys) come from the user's `sodagun.toml` volumes/secrets — entirely out of baton scope. Baton injects only the four monet env vars via attach `--env`.

33. **`host.microsandbox.internal` reaches host `127.0.0.1`-bound servers (verified).** The forwarders bridge to `host.microsandbox.internal:PORT`; empirically verified (2026-06-10): an in-guest `curl http://host.microsandbox.internal:PORT` returned 200 from a host server bound to `127.0.0.1`, with the matching `allow@host:tcp:PORT` rule in place. monet's servers can stay loopback-bound.
