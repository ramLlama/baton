;;; birbal.el --- Manage multiple AI coding agents from Emacs  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vterm "0.0.2"))
;; Keywords: tools, ai
;; URL: https://github.com/ramraghunathan/birbal

;;; Commentary:
;; Birbal is an Emacs package for managing multiple AI coding agents (Claude Code,
;; Aider, Codex CLI, Gemini CLI, etc.) from a unified interface.
;;
;; Agents run in vterm terminal buffers.  Birbal monitors their output for
;; patterns that signal "needs attention" (prompts, permission requests, etc.)
;; and surfaces that status via a modeline badge, a status buffer, and
;; optional OS notifications.
;;
;; Quick start:
;;   (birbal-mode 1)
;;   M-x birbal-new       — spawn a new agent session
;;   M-x birbal-list      — open the status buffer
;;   M-x birbal-jump      — jump to any session via completing-read
;;   M-x birbal-kill      — kill a session
;;
;; Monet integration (optional):
;;   (birbal-monet-setup) after loading monet.

;;; Code:
(require 'cl-lib)
(require 'birbal-session)
(require 'birbal-process)
(require 'birbal-notify)

(declare-function birbal-monet-setup "birbal-monet" ())

;;; Agent-Type Registry

(defvar birbal-agent-types (make-hash-table :test 'eq)
  "Hash table mapping agent-type symbols to their definition plists.
Each plist has keys: :command, :args, :waiting-patterns, :env-functions.")

(cl-defun birbal-define-agent-type (&key name command (args nil) waiting-patterns (env-functions nil))
  "Define or redefine an agent type.
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
           birbal-agent-types))

(defun birbal-add-env-function (agent-type fn)
  "Append FN to the env-functions list for AGENT-TYPE.
FN must accept (KEY DIRECTORY) and return a list of \"VAR=VALUE\" strings.
AGENT-TYPE is a symbol key in `birbal-agent-types'."
  (when-let* ((def (gethash agent-type birbal-agent-types)))
    (puthash agent-type
             (plist-put def :env-functions
                        (append (plist-get def :env-functions) (list fn)))
             birbal-agent-types)))

;;; Built-in Agent Types

(birbal-define-agent-type
 :name 'claude-code
 :command "claude"
 :args '()
 :waiting-patterns
 ;; Patterns are matched against the last 250 lines — keep them specific.
 '(("╭─" . "input prompt")
   ("Allow.*tool\\|Allow.*command\\|Bash.*Allow" . "permission prompt")
   ("Do you want to\\|Would you like to" . "confirmation")
   ("\\[Y/n\\]\\|\\[y/N\\]" . "confirmation")))

(birbal-define-agent-type
 :name 'aider
 :command "aider"
 :args '()
 :waiting-patterns
 '(("^> " . "input prompt")
   ("Add these files" . "confirmation")
   ("\\[Y/n\\]" . "confirmation")))

(birbal-define-agent-type
 :name 'codex
 :command "codex"
 :args '()
 :waiting-patterns
 '(("^> " . "input prompt")
   ("\\[y/N\\]" . "confirmation")))

;;; Customization Group

(defgroup birbal nil
  "Manage multiple AI coding agents from Emacs."
  :group 'external
  :prefix "birbal-")

(defcustom birbal-term-name "xterm-256color"
  "TERM environment variable set in birbal vterm buffers.
\"xterm-256color\" is the safe default; agents detect 24-bit color
via COLORTERM=truecolor (inherited from Emacs).  \"xterm-direct\"
uses colon-separated RGB codes that libvterm does not render."
  :type 'string
  :group 'birbal)

;;; Internal Helpers

(defun birbal--setup-hooks ()
  "Add birbal notification hooks."
  (add-hook 'birbal-session-status-changed-hook  #'birbal-notify--on-status-changed)
  (add-hook 'birbal-session-created-hook         #'birbal-notify--on-session-event)
  (add-hook 'birbal-session-killed-hook          #'birbal-notify--on-session-event)
  (add-hook 'birbal-session-unread-changed-hook  #'birbal-notify--on-unread-changed))

(defun birbal--teardown-hooks ()
  "Remove birbal notification hooks."
  (remove-hook 'birbal-session-status-changed-hook  #'birbal-notify--on-status-changed)
  (remove-hook 'birbal-session-created-hook         #'birbal-notify--on-session-event)
  (remove-hook 'birbal-session-killed-hook          #'birbal-notify--on-session-event)
  (remove-hook 'birbal-session-unread-changed-hook  #'birbal-notify--on-unread-changed))

;;; User Commands

(defun birbal-kill (session-name)
  "Kill the session named SESSION-NAME."
  (interactive
   (list (completing-read "Kill session: "
                          (mapcar #'birbal--session-name (birbal-session-list))
                          nil t)))
  (let ((session (cl-find session-name (birbal-session-list)
                           :key #'birbal--session-name
                           :test #'equal)))
    (if session
        (birbal-session-kill session)
      (message "birbal: no session named %s" session-name))))

(defun birbal-kill-all ()
  "Kill all active sessions."
  (interactive)
  (birbal-session-kill-all)
  (message "birbal: all sessions killed"))


;;;###autoload
(defun birbal-new (agent-type-name directory &optional name)
  "Spawn a new agent session.
AGENT-TYPE-NAME is a string naming the agent type (e.g. \"claude-code\").
DIRECTORY is the working directory for the session.
NAME is an optional display name; prompted when called with \\[universal-argument]."
  (interactive
   (list (completing-read "Agent type: "
                          (mapcar #'symbol-name (hash-table-keys birbal-agent-types))
                          nil t)
         (read-directory-name "Directory: " nil nil t)
         (when current-prefix-arg
           (let ((n (read-string "Session name (empty = auto): ")))
             (unless (string-empty-p n) n)))))
  (let* ((agent-type (intern agent-type-name))
         (def (gethash agent-type birbal-agent-types)))
    (unless def
      (error "Unknown agent type: %s" agent-type-name))
    (let* ((args (plist-get def :args))
           (command (if args
                        (mapconcat #'identity
                                   (cons (plist-get def :command)
                                         (mapcar #'shell-quote-argument args))
                                   " ")
                      (plist-get def :command)))
           (session (birbal-session-create
                     :agent-type agent-type
                     :command command
                     :directory (expand-file-name directory)
                     :name name)))
      (birbal-process-spawn session)
      (when-let* ((buf (birbal--session-buffer session)))
        (pop-to-buffer buf))
      session)))

;;;###autoload
(define-minor-mode birbal-mode
  "Global minor mode for managing AI coding agents with birbal."
  :global t
  :group 'birbal
  :lighter nil
  (if birbal-mode
      (progn
        (birbal--setup-hooks)
        (birbal-modeline-mode 1)
        ;; Wire monet integration.
        ;; birbal-monet-setup must run after monet-register-core-tools (called
        ;; from monet-mode activation), not just after monet is loaded.  Hook
        ;; into monet-mode-hook so the registry is ready when we override it.
        ;; Also handle the case where monet-mode is already active.
        (with-eval-after-load 'monet
          (require 'birbal-monet)
          (add-hook 'monet-mode-hook
                    (lambda () (when monet-mode (birbal-monet-setup))))
          (when (and (boundp 'monet-mode) monet-mode)
            (birbal-monet-setup))))
    (birbal--teardown-hooks)
    (birbal-modeline-mode -1)))

;;;###autoload
(defvar birbal-global-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'birbal-new)
    (define-key map (kbd "k") #'birbal-kill)
    (define-key map (kbd "K") #'birbal-kill-all)
    (define-key map (kbd "l") #'birbal-list)
    (define-key map (kbd "j") #'birbal-jump)
    (define-key map (kbd "w") #'birbal-jump-to-waiting)

    map)
  "Keymap for birbal commands.
Bind this under a prefix key, e.g.:
  (global-set-key (kbd \"C-c b\") birbal-global-map)")

(provide 'birbal)
;;; birbal.el ends here
