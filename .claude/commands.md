# User Commands & Transient Dispatch

Invoke via `M-x baton` or bind with `(global-set-key (kbd "C-c b") #'baton)`.

`baton` is a `transient-define-prefix` with these groups:

**Sessions** (infixes apply to the next `baton-new` only):

| Key  | Command / Infix          | Description                                      |
|------|--------------------------|--------------------------------------------------|
| `-a` | `baton--agent-infix`    | Agent for this spawn (ephemeral)                 |
| `-n` | `baton--name-infix`     | Session name for this spawn (ephemeral)          |
| `-w` | `baton--worktree-infix` | sodagun worktree branch to run the session in    |
| `-B` | `baton--base-infix`     | Base ref for the worktree branch (unset = sodagun default) |
| `n`  | `baton-new`             | Spawn a new agent session                        |
| `k`  | `baton-kill`            | Kill a session by name                           |
| `K`  | `baton-kill-all`        | Kill all sessions                                |

The `-w` and `-B` infixes appear only when sodagun is usable (`baton--sodagun-usable-p`: `baton-sodagun` loaded **and** the `sodagun` binary on `exec-path`). Setting `-w` makes the next `baton-new` create a sodagun worktree on that branch and run the session there (on the host); `-B` overrides the base ref the branch is cut from.

**Navigate**:

| Key  | Command                  | Description                                      |
|------|--------------------------|--------------------------------------------------|
| `l`  | `baton-list`            | Open `*Baton*` status buffer                    |
| `j`  | `baton-jump`            | Jump to any session (completing-read)            |
| `w`  | `baton-jump-to-waiting` | Jump to a waiting session                        |

**Diff Review** (only shown when monet is loaded; `r` is greyed out when no pending diff):

| Key  | Command                  | Description                                      |
|------|--------------------------|--------------------------------------------------|
| `r`  | `baton-review-diff`     | Open pending diff                                |

**Configure**:

| Key  | Infix                         | Description                                      |
|------|-------------------------------|--------------------------------------------------|
| `-d` | `baton--default-agent-infix` | Persistent default agent for `baton-new`         |

Status buffer keybindings (`baton-list-mode-map`): `d` flag delete, `x` execute, `RET` jump, `N` new, `g` refresh, `m`/`u`/`U` mark/unmark, `r` review pending diff.
