;;; birbal.el --- Manage multiple AI coding agents from Emacs  -*- lexical-binding: t -*-

;; Author: Ram Krishnaraj
;; Version: 0.1.0
;; Package-Requires: ((emacs "29.1") (vterm "0.0.2"))
;; Keywords: tools, ai
;; URL: https://github.com/ramkrishnaraj/birbal

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
;;   (birbal-bridge-setup) after loading monet.

;;; Code:
(require 'cl-lib)
(require 'birbal-session)
(require 'birbal-process)
(require 'birbal-notify)

(declare-function birbal-bridge-setup "birbal-bridge" ())

;;; Agent-Type Registry

(defvar birbal-agent-types (make-hash-table :test 'eq)
  "Hash table mapping agent-type symbols to their definition plists.
Each plist has keys: :command, :args, :waiting-patterns, :done-patterns.")

(cl-defun birbal-define-agent-type (&key name command (args nil)
                                         waiting-patterns done-patterns)
  "Define or redefine an agent type.
NAME is a symbol (e.g. `claude-code').
COMMAND is the shell command string.
ARGS is a list of default arguments (default: nil).
WAITING-PATTERNS is an alist of (REGEXP . REASON).
DONE-PATTERNS is a list of regexps signalling session completion."
  (puthash name
           (list :command command
                 :args args
                 :waiting-patterns waiting-patterns
                 :done-patterns done-patterns)
           birbal-agent-types))

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
   ("\\[Y/n\\]\\|\\[y/N\\]" . "confirmation"))
 :done-patterns '("Session ended" "Goodbye"))

(birbal-define-agent-type
 :name 'aider
 :command "aider"
 :args '()
 :waiting-patterns
 '(("^> " . "input prompt")
   ("Add these files" . "confirmation")
   ("\\[Y/n\\]" . "confirmation"))
 :done-patterns '("Goodbye" "^Aider v"))

(birbal-define-agent-type
 :name 'codex
 :command "codex"
 :args '()
 :waiting-patterns
 '(("^> " . "input prompt")
   ("\\[y/N\\]" . "confirmation"))
 :done-patterns '("Bye!" "Session complete"))

;;; User Commands

;;;###autoload
(defun birbal-new (agent-type-name directory)
  "Spawn a new agent session.
AGENT-TYPE-NAME is a string naming the agent type (e.g. \"claude-code\").
DIRECTORY is the working directory for the session."
  (interactive
   (list (completing-read "Agent type: "
                          (hash-table-keys birbal-agent-types)
                          nil t)
         (read-directory-name "Directory: " nil nil t)))
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
                     :directory (expand-file-name directory))))
      (birbal-process-spawn session)
      (when-let* ((buf (birbal--session-buffer session)))
        (pop-to-buffer buf))
      session)))

;;;###autoload
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

;;;###autoload
(defun birbal-kill-all ()
  "Kill all active sessions."
  (interactive)
  (birbal-session-kill-all)
  (message "birbal: all sessions killed"))

;;; Quick Input Actions

;;;###autoload
(defun birbal-send-return (session-name)
  "Send RET to the session named SESSION-NAME."
  (interactive
   (list (completing-read "Send RET to: "
                          (mapcar #'birbal--session-name (birbal-session-list))
                          nil t)))
  (when-let* ((session (cl-find session-name (birbal-session-list)
                                :key #'birbal--session-name
                                :test #'equal)))
    (birbal-process-send-input session "\n")))

;;;###autoload
(defun birbal-send-escape (session-name)
  "Send ESC to the session named SESSION-NAME."
  (interactive
   (list (completing-read "Send ESC to: "
                          (mapcar #'birbal--session-name (birbal-session-list))
                          nil t)))
  (when-let* ((session (cl-find session-name (birbal-session-list)
                                :key #'birbal--session-name
                                :test #'equal)))
    (birbal-process-send-key session "ESC")))

;;; Global Keymap

(defvar birbal-global-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "n") #'birbal-new)
    (define-key map (kbd "k") #'birbal-kill)
    (define-key map (kbd "K") #'birbal-kill-all)
    (define-key map (kbd "l") #'birbal-list)
    (define-key map (kbd "j") #'birbal-jump)
    (define-key map (kbd "w") #'birbal-jump-to-waiting)
    (define-key map (kbd "r") #'birbal-send-return)
    (define-key map (kbd "e") #'birbal-send-escape)
    map)
  "Keymap for birbal commands.
Bind this under a prefix key, e.g.:
  (global-set-key (kbd \"C-c b\") birbal-global-map)")

;;; Global Minor Mode

(defun birbal--setup-hooks ()
  "Add birbal notification hooks."
  (add-hook 'birbal-session-status-changed-hook #'birbal-notify--on-status-changed)
  (add-hook 'birbal-session-created-hook        #'birbal-notify--on-session-event)
  (add-hook 'birbal-session-killed-hook         #'birbal-notify--on-session-event))

(defun birbal--teardown-hooks ()
  "Remove birbal notification hooks."
  (remove-hook 'birbal-session-status-changed-hook #'birbal-notify--on-status-changed)
  (remove-hook 'birbal-session-created-hook        #'birbal-notify--on-session-event)
  (remove-hook 'birbal-session-killed-hook         #'birbal-notify--on-session-event))

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
        ;; Wire monet bridge if monet is already loaded
        (when (featurep 'monet)
          (require 'birbal-bridge)
          (birbal-bridge-setup))
        ;; Wire monet bridge when monet loads later
        (with-eval-after-load 'monet
          (require 'birbal-bridge)
          (birbal-bridge-setup)))
    (birbal--teardown-hooks)
    (birbal-modeline-mode -1)))

;;; Customization Group

(defgroup birbal nil
  "Manage multiple AI coding agents from Emacs."
  :group 'external
  :prefix "birbal-")

(provide 'birbal)
;;; birbal.el ends here
