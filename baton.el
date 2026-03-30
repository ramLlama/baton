;;; baton.el --- Manage multiple AI coding agents from Emacs  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Version: 0.1.0
;; Package-Requires: ((emacs "30.1") (vterm) (transient))
;; Keywords: tools, ai
;; URL: https://github.com/ramraghunathan/baton

;;; Commentary:
;; Baton is an Emacs package for managing multiple AI coding agents (Claude Code,
;; Aider, Codex CLI, Gemini CLI, etc.) from a unified interface.
;;
;; Agents run in vterm terminal buffers.  Baton monitors their output for
;; patterns that signal "needs attention" (prompts, permission requests, etc.)
;; and surfaces that status via a modeline badge, a status buffer, and
;; optional OS notifications.
;;
;; Quick start:
;;   (baton-mode 1)
;;   (global-set-key (kbd "C-c b") #'baton)
;;   M-x baton           — open the dispatch menu
;;
;; Monet integration (optional):
;;   (baton-monet-setup) after loading monet.

;;; Code:
(require 'cl-lib)
(require 'transient)
(require 'baton-session)
(require 'baton-process)
(require 'baton-notify)
(require 'baton-alert)

(declare-function baton-monet-setup "baton-monet" ())
(declare-function baton-review-diff "baton-monet" (session-name))

;;; Agent Registry

(defvar baton-agents (make-hash-table :test 'eq)
  "Hash table mapping agent symbols to their definition plists.
Each plist has keys: :command, :args, :waiting-patterns, :env-functions.")

(cl-defun baton-define-agent (&key name command (args nil) waiting-patterns (env-functions nil))
  "Define or redefine an agent.
NAME is a symbol (e.g. `claude-code').
COMMAND is the shell command string.
ARGS is a list of default arguments (default: nil).
WAITING-PATTERNS is an alist of (REGEXP . REASON).
ENV-FUNCTIONS is a list of functions (KEY DIRECTORY) -> list of
\"VAR=VALUE\" strings (default: nil)."
  (puthash name
           (list :command command
                 :args args
                 :waiting-patterns waiting-patterns
                 :env-functions env-functions)
           baton-agents))

(defun baton-add-env-function (agent fn)
  "Add FN to the env-functions list for AGENT if not already present.
Idempotent: calling with the same FN twice has the same effect as calling once.
FN must accept (KEY DIRECTORY) and return a list of \"VAR=VALUE\" strings.
AGENT is a symbol key in `baton-agents'."
  (when-let* ((def (gethash agent baton-agents)))
    (unless (member fn (plist-get def :env-functions))
      (puthash agent
               (plist-put def :env-functions
                          (append (plist-get def :env-functions) (list fn)))
               baton-agents))))

;;; Built-in Agents

(baton-define-agent
 :name 'claude-code
 :command "claude"
 :args '()
 :waiting-patterns
 ;; Patterns are matched against the last 250 lines — keep them specific.
 '(("╭─" . "input prompt")
   ("Allow.*tool\\|Allow.*command\\|Bash.*Allow" . "permission prompt")
   ("Do you want to\\|Would you like to" . "confirmation")
   ("\\[Y/n\\]\\|\\[y/N\\]" . "confirmation")))

(baton-define-agent
 :name 'aider
 :command "aider"
 :args '()
 :waiting-patterns
 '(("^> " . "input prompt")
   ("Add these files" . "confirmation")
   ("\\[Y/n\\]" . "confirmation")))

(baton-define-agent
 :name 'codex
 :command "codex"
 :args '()
 :waiting-patterns
 '(("^> " . "input prompt")
   ("\\[y/N\\]" . "confirmation")))

;;; Customization Group

(defgroup baton nil
  "Manage multiple AI coding agents from Emacs."
  :group 'external
  :prefix "baton-")

(defcustom baton-term-name "xterm-256color"
  "TERM environment variable set in baton vterm buffers.
\"xterm-256color\" is the safe default; agents detect 24-bit color
via COLORTERM=truecolor (inherited from Emacs).  \"xterm-direct\"
uses colon-separated RGB codes that libvterm does not render."
  :type 'string
  :group 'baton)

(defcustom baton-default-agent nil
  "Default agent used by `baton-new' when no prefix argument is given.
When non-nil, must be a symbol naming a registered agent (e.g. `claude-code').
With a prefix argument, `baton-new' always prompts for agent regardless of
this setting."
  :type '(choice (const :tag "Always prompt" nil)
                 (symbol :tag "Agent symbol"))
  :group 'baton)

;;; Internal Helpers

(defun baton--on-monet-mode ()
  "Activate baton monet integration when monet-mode is enabled."
  (when monet-mode
    (baton-monet-setup)))

(defun baton--setup-hooks ()
  "Add baton notification hooks."
  (add-hook 'baton-session-status-changed-hook  #'baton-notify--on-status-changed)
  (add-hook 'baton-session-created-hook         #'baton-notify--on-session-event)
  (add-hook 'baton-session-killed-hook          #'baton-notify--on-session-event)
  (add-hook 'baton-session-unread-changed-hook  #'baton-notify--on-unread-changed)
  (baton-alert--setup))

(defun baton--teardown-hooks ()
  "Remove baton notification hooks."
  (remove-hook 'baton-session-status-changed-hook  #'baton-notify--on-status-changed)
  (remove-hook 'baton-session-created-hook         #'baton-notify--on-session-event)
  (remove-hook 'baton-session-killed-hook          #'baton-notify--on-session-event)
  (remove-hook 'baton-session-unread-changed-hook  #'baton-notify--on-unread-changed)
  (setq baton-notify-function #'baton-notify--default))

;;; User Commands

(defun baton-kill (session-name)
  "Kill the session named SESSION-NAME."
  (interactive
   (list (completing-read "Kill session: "
                          (mapcar #'baton--session-name (baton-session-list))
                          nil t)))
  (let ((session (cl-find session-name (baton-session-list)
                           :key #'baton--session-name
                           :test #'equal)))
    (if session
        (baton-session-kill session)
      (message "baton: no session named %s" session-name))))

(defun baton-kill-all ()
  "Kill all active sessions."
  (interactive)
  (baton-session-kill-all)
  (message "baton: all sessions killed"))


;;;###autoload
(defun baton-new (agent-name directory &optional name)
  "Spawn a new agent session.
AGENT-NAME is a string naming the agent (e.g. \"claude-code\").
DIRECTORY is the working directory for the session.
NAME is an optional display name; prompted when called with \\[universal-argument].
When `baton-default-agent' is set, AGENT-NAME defaults to that agent and no
prompt is shown unless a prefix argument is given."
  (interactive
   (let* ((args (and (fboundp 'transient-args)
                     (transient-args 'baton)))
          (agent-from-args (and args (transient-arg-value "--agent=" args)))
          (name-from-args  (and args (transient-arg-value "--name="  args)))
          (agent-name (or agent-from-args
                          (and baton-default-agent
                               (not current-prefix-arg)
                               (symbol-name baton-default-agent))
                          (completing-read "Agent: "
                                           (mapcar #'symbol-name (hash-table-keys baton-agents))
                                           nil t)))
          (name (or name-from-args
                    (when current-prefix-arg
                      (let ((n (read-string "Session name (empty = auto): ")))
                        (unless (string-empty-p n) n))))))
     (list agent-name
           (read-directory-name "Directory: " nil nil t)
           name)))
  (let* ((agent (intern agent-name))
         (def (gethash agent baton-agents)))
    (unless def
      (error "Unknown agent: %s" agent-name))
    (let* ((args (plist-get def :args))
           (command (if args
                        (mapconcat #'identity
                                   (cons (plist-get def :command)
                                         (mapcar #'shell-quote-argument args))
                                   " ")
                      (plist-get def :command)))
           (session (baton-session-create
                     :agent agent
                     :command command
                     :directory (expand-file-name directory)
                     :name name)))
      (baton-process-spawn session)
      (when-let* ((buf (baton--session-buffer session)))
        (pop-to-buffer buf))
      session)))

;;;###autoload
(define-minor-mode baton-mode
  "Global minor mode for managing AI coding agents with baton."
  :global t
  :group 'baton
  :lighter nil
  (if baton-mode
      (progn
        (baton--setup-hooks)
        (baton-modeline-mode 1)
        ;; Wire monet integration.
        ;; baton-monet-setup must run after monet-register-core-tools (called
        ;; from monet-mode activation), not just after monet is loaded.  Hook
        ;; into monet-mode-hook so the registry is ready when we override it.
        ;; Also handle the case where monet-mode is already active.
        (with-eval-after-load 'monet
          (require 'baton-monet)
          (add-hook 'monet-mode-hook #'baton--on-monet-mode)
          (when (and (boundp 'monet-mode) monet-mode)
            (baton-monet-setup))))
    (baton--teardown-hooks)
    (baton-modeline-mode -1)))

;;; Transient Dispatch

(transient-define-infix baton--agent-infix ()
  "Agent to use for the next `baton-new' invocation (this dispatch only)."
  :argument "--agent="
  :class 'transient-option
  :key "-a"
  :description "Agent (this spawn)"
  :reader (lambda (prompt _initial-input _history)
            (completing-read prompt
                             (mapcar #'symbol-name (hash-table-keys baton-agents))
                             nil t)))

(transient-define-infix baton--name-infix ()
  "Session name to use for the next `baton-new' invocation (this dispatch only)."
  :argument "--name="
  :class 'transient-option
  :key "-n"
  :description "Name (this spawn)"
  :reader (lambda (prompt _initial-input _history)
            (read-string prompt)))

(transient-define-infix baton--default-agent-infix ()
  "Set the persistent default agent for `baton-new'."
  :class 'transient-lisp-variable
  :variable 'baton-default-agent
  :key "-d"
  :description "Default agent"
  :reader (lambda (prompt _initial-input _history)
            (let* ((agents (mapcar #'symbol-name (hash-table-keys baton-agents)))
                   (choice (completing-read prompt (cons "none" agents) nil t)))
              (unless (equal choice "none")
                (intern choice)))))

;;;###autoload
(transient-define-prefix baton ()
  "Dispatch a baton command."
  [["Sessions"
    ("-a" baton--agent-infix)
    ("-n" baton--name-infix)
    ("n" "New session"        baton-new)
    ("k" "Kill session"       baton-kill)
    ("K" "Kill all"           baton-kill-all)]
   ["Navigate"
    ("l" "List sessions"      baton-list)
    ("j" "Jump to session"    baton-jump)
    ("w" "Jump to waiting"    baton-jump-to-waiting)]]
  ["Diff Review"
   :if (lambda () (featurep 'monet))
   ("r" "Review pending diff" baton-review-diff
    :inapt-if-not (lambda ()
                    (cl-some (lambda (s)
                               (plist-get (baton--session-metadata s) :pending-diff))
                             (baton-session-list))))]
  ["Configure"
   ("-d" baton--default-agent-infix)])

(provide 'baton)
;;; baton.el ends here
