<p align="center">
  <img src="logo.png" alt="Baton" width="400">
</p>

# Baton

Baton is an Emacs package for managing multiple AI coding agents from a unified interface. Run [Claude Code](https://claude.ai/code), [Aider](https://aider.chat), [Codex CLI](https://github.com/openai/codex), [Gemini CLI](https://github.com/google-gemini/gemini-cli), and others side-by-side in vterm buffers. Baton monitors their output for status transitions — running, waiting, idle — and surfaces that status via a modeline badge, a tabulated-list status buffer, and optional notifications.

> **Note:** Only Claude Code has been tested extensively. Other agents (Aider, Codex, Gemini CLI) have built-in definitions but may need tuning — PRs welcome.

Key ideas:

- **One interface, many agents.** Spawn and switch between agents without leaving Emacs.
- **Automatic status detection.** Pattern-matching on terminal output tells you when an agent needs your attention (permission prompts, confirmations, input prompts).
- **Unread tracking.** Know at a glance which agents have new output you haven't seen.
- **Extensible.** Define your own agent types with custom commands and waiting patterns.

## Requirements

- Emacs 30.1+
- [vterm](https://github.com/akermu/emacs-libvterm)
- [transient](https://github.com/magit/transient)

## Installation

```elisp
(use-package baton
  :vc (:url "https://github.com/ramLlama/baton" :rev :newest)
  :bind ("C-c b" . baton)  ; open the baton dispatch menu
  :config
  (baton-mode 1))
```

## Usage

All commands are available through the transient dispatch menu:

```
M-x baton    (or C-c b with the binding above)
```

### Sessions

| Key  | Command       | Description                          |
|------|---------------|--------------------------------------|
| `n`  | `baton-new`   | Spawn a new agent session            |
| `k`  | `baton-kill`  | Kill a session by name               |
| `K`  | `baton-kill-all` | Kill all sessions                 |

Use `-a` to pick an agent and `-n` to name the session before pressing `n`.
With `C-u n`, you'll be prompted for a session name regardless.

### Navigation

| Key  | Command              | Description                      |
|------|----------------------|----------------------------------|
| `l`  | `baton-list`         | Open the `*Baton*` status buffer |
| `j`  | `baton-jump`         | Jump to any session              |
| `w`  | `baton-jump-to-waiting` | Jump to a waiting session     |

### Status Buffer

The `*Baton*` buffer (`baton-list`) shows all active sessions with their status. Keybindings:

| Key   | Action             |
|-------|--------------------|
| `RET` | Jump to session    |
| `d`   | Flag for deletion  |
| `x`   | Execute deletions  |
| `N`   | New session        |
| `g`   | Refresh            |

## Configuration

### Default Agent

Skip the agent prompt on every spawn by setting a default:

```elisp
(setq baton-default-agent 'claude-code)
```

Or set it interactively via `-d` in the transient menu. With a prefix argument (`C-u n`), you'll still be prompted.

### Defining Custom Agents

Register any CLI tool as a baton agent:

```elisp
(baton-define-agent
 :name 'gemini
 :command "gemini"
 :args '()
 :waiting-patterns
 '(("^> " . "input prompt")
   ("\\[Y/n\\]" . "confirmation")))
```

`:waiting-patterns` is an alist of `(REGEXP . REASON)` — when the agent's output is stable and matches a pattern, baton marks the session as **waiting** with the given reason.

### Notification Function

Customize how you're notified when an agent needs attention:

```elisp
(setq baton-notify-function #'my-custom-notify-fn)
```

The function receives the session and the event type.

### Modeline

When `baton-mode` is active, the modeline shows a badge like `B[1w/2i/1r 1*]`:

- `1w` — 1 session waiting
- `2i` — 2 sessions idle
- `1r` — 1 session running
- `1*` — 1 session with unread output

Zero counts are omitted. The badge turns yellow when any session is waiting.

## Monet Integration

Users of my [Monet](https://github.com/ramLlama/monet) package (forked from Steve Molitor's [excellent work](https://github.com/stevemolitor/monet)) get automatic diff-review awareness. When Claude Code requests a diff review, baton marks the session as waiting with reason "diff review" and resets it when you accept or quit. No configuration needed — `baton-mode` sets this up automatically when monet is loaded.

## License

MIT
