# baton progress

## Plan reference

Full three-plan spec: `~/.claude/plans/i-want-to-integrate-rustling-flame.md`

baton is **Plan 3** of a three-plan integration sequence:
- **Plan 1 (sodagun)** — ✅ complete & merged (PR #9), plus follow-up `ram/sandbox-git-access` branch
- **Plan 2 (monet)** — ✅ complete & merged (PR #3), plus follow-up `ram/sandbox-portability` branch
- **Plan 3 (baton)** — ✅ complete, this repo

---

## Plan 3 status: complete, verified end-to-end 2026-06-11

**Branches / PRs (stacked)**:
- `ram/sandboxing` → `main`: the full sandboxing integration (executor abstraction through the monet path-mappings bridge)
- `ram/baton-logging` → `ram/sandboxing`: the standalone debug-logging module (`baton-logging.el`), stacked so it can merge or drop independently

**Companion branches in sibling repos** (the composed flow needs all three):
- monet `ram/sandbox-portability` — pid-1 lockfile, `ENABLE_IDE_INTEGRATION=true`, portable hooks installer, protocol path mappings
- sodagun `ram/sandbox-git-access` — `git_access` config, JSON error messages, orphan-tolerant remove, startup fd-limit raise

### What was implemented (commit order on `ram/sandboxing`)

1. **Executor abstraction** (`baton-executor.el`): agent × executor axes; `baton-executor--resolve`/`--teardown` generics; strict `(:env … :ports …)` env-function contract; reference `exec` executor.
2. **Worktree-only path**: `baton-sodagun.el` CLI wrapper + `-w`/`-B` transient flags (executor stays `exec`).
3. **Sandbox executor**: `-s` flag, `sodagun` executor (worktree → env-once → net rules → sandbox start → attach command), workspace registry, idempotent teardown (sandbox **removed**, worktree kept).
4. **Monet-in-sandbox**: env-function wiring order pinned; composed-flow docs.
5. **Fixes from live testing**: `/bin/sh -c` wrapping in eat/ghostel (multi-word commands), absolute sodagun path in attach strings, `-c` sandbox-config flag, `baton-sodagun-worktree-created-hook` (direnv trust propagation lives in user config, `~/.emacs.d/extras/dev.el`).
6. **Single-connection redesign**: port forwarders ride the attach connection as in-guest backgrounded socats (microsandbox allows ONE concurrent connection per sandbox).
7. **Path-mappings bridge**: `baton-executor-guest-path-mappings` bound by the sodagun resolve; baton-monet forwards it to monet; monet session stopped on baton session kill (leak fix).

### Verified end-to-end (2026-06-11)

`M-x baton` → `-w <branch> -s` → sandboxed claude with: `/ide` connected (diff review via translated paths), hook-driven status flips, in-guest git commits (via sodagun `git_access = "data"`), `baton-kill` removes the sandbox and keeps the worktree.

### Remaining / tabled

- Worktree reuse on existing branch (`sodagun git find-worktree` + baton reuse prompt) — tabled
- microsandbox single-connection limitation — worked around here; real fix is upstream SDK work
- process-compose is the agreed escape hatch if in-guest orchestration outgrows the `sh -c 'socat & … exec agent'` wrapper
