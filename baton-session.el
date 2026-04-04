;;; baton-session.el --- Session struct, registry, lifecycle, hooks  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Manages baton agent sessions: creation, lifecycle, status tracking, and hooks.
;; Provides the core data model and registry for all baton sessions.

;;; Code:
(require 'cl-lib)

;;; Data Structures

(cl-defstruct baton--session
  "An AI agent session managed by baton."
  name            ; unique string, also used as registry key ("claude-1", or user-provided)
  agent           ; symbol, key into baton-agents
  command         ; string, the shell command that was run
  directory       ; string, working directory
  buffer          ; vterm buffer
  status          ; symbol: running | waiting | idle | error | other
  waiting-reason  ; string or nil; holds reason for waiting, error, and other statuses
  created-at      ; float-time timestamp
  updated-at      ; float-time timestamp
  metadata)       ; plist for agent-specific data

;;; Registries

(defvar baton--sessions (make-hash-table :test 'equal)
  "Hash table mapping session ID strings to `baton--session' structs.")

(defvar baton--session-counters (make-hash-table :test 'eq)
  "Hash table mapping agent symbols to auto-increment counters.")

;;; Hooks

(defcustom baton-session-created-hook nil
  "Hook called when a session is created.
Each function is called with one argument: the new `baton--session'."
  :type 'hook
  :group 'baton)

(defcustom baton-session-killed-hook nil
  "Hook called when a session is killed.
Each function is called with one argument: the killed `baton--session'."
  :type 'hook
  :group 'baton)

(defcustom baton-session-status-changed-hook nil
  "Hook called when a session's status changes.
Each function is called with three arguments: SESSION, OLD-STATUS, NEW-STATUS."
  :type 'hook
  :group 'baton)

(defcustom baton-session-unread-changed-hook nil
  "Hook called when a session transitions from read to unread.
Each function is called with one argument: SESSION."
  :type 'hook
  :group 'baton)

;;; Internal Helpers

(defun baton--agent-short-name (agent)
  "Return the display prefix for AGENT symbol.
For `claude-code', returns \"claude\"; for `aider', returns \"aider\"."
  (car (split-string (symbol-name agent) "-")))

(defun baton--next-session-name (agent)
  "Return the next auto-generated display name for AGENT.
Increments the counter for AGENT and returns \"<prefix>-<n>\"."
  (let ((count (1+ (or (gethash agent baton--session-counters) 0))))
    (puthash agent count baton--session-counters)
    (format "%s-%d" (baton--agent-short-name agent) count)))

;;; Public API

(cl-defun baton-session-create (&key agent command directory name)
  "Create and register a new baton session.
AGENT is a symbol key into `baton-agents'.
COMMAND is the shell command string.
DIRECTORY is the working directory.
NAME is optional; auto-generated from AGENT if omitted.
Returns the new `baton--session'."
  (let* ((session-name (or name (baton--next-session-name agent)))
         (now (float-time)))
    (when (gethash session-name baton--sessions)
      (error "A baton session named %S already exists" session-name))
    (let* ((session (make-baton--session
                     :name session-name
                     :agent agent
                     :command command
                     :directory directory
                     :buffer nil
                     :status 'running
                     :waiting-reason nil
                     :created-at now
                     :updated-at now
                     :metadata nil)))
      (puthash session-name session baton--sessions)
      (run-hook-with-args 'baton-session-created-hook session)
      session)))

(defun baton-session-get (name)
  "Return the session with NAME, or nil if not found."
  (gethash name baton--sessions))

(defun baton-session-list (&optional status)
  "Return a list of all sessions.
If STATUS is non-nil, return only sessions with that status symbol."
  (let ((all (hash-table-values baton--sessions)))
    (if status
        (cl-remove-if-not (lambda (s) (eq (baton--session-status s) status)) all)
      all)))

(defun baton-session-set-status (session new-status &optional reason)
  "Set SESSION status to NEW-STATUS with optional REASON string.
Fires `baton-session-status-changed-hook' with (SESSION OLD-STATUS NEW-STATUS)
only when the status or waiting-reason actually changes.
REASON is preserved for `waiting', `error', and `other' statuses; cleared
for all others."
  (let ((old-status (baton--session-status session))
        (old-reason (baton--session-waiting-reason session))
        (new-reason (when (memq new-status '(waiting error other)) reason)))
    (unless (and (eq old-status new-status) (equal old-reason new-reason))
      (setf (baton--session-status session) new-status)
      (setf (baton--session-waiting-reason session) new-reason)
      (setf (baton--session-updated-at session) (float-time))
      (run-hook-with-args 'baton-session-status-changed-hook session old-status new-status))))

(defun baton-session-find-by-directory (directory)
  "Return the first session whose directory matches DIRECTORY, or nil."
  (cl-find directory (hash-table-values baton--sessions)
           :key #'baton--session-directory
           :test #'equal))

(defun baton-session-kill (session)
  "Kill SESSION: cancel its watcher, kill its buffer, remove from registry.
Fires `baton-session-killed-hook'."
  ;; Cancel any watcher timer
  (when-let* ((timer (plist-get (baton--session-metadata session) :watcher-timer)))
    (cancel-timer timer))
  ;; Kill the vterm buffer if alive
  (when-let* ((buf (baton--session-buffer session)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (set-buffer-modified-p nil))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf))))
  ;; Remove from registry and fire hook only when not already done.
  ;; `baton-process--on-buffer-killed' runs inside kill-buffer above and
  ;; already cleans up registry + fires the hook when the buffer had a live
  ;; session.  Guard here handles the no-buffer case and prevents a second
  ;; hook invocation.
  (when (gethash (baton--session-name session) baton--sessions)
    (remhash (baton--session-name session) baton--sessions)
    (run-hook-with-args 'baton-session-killed-hook session)))

(defun baton-session-kill-all ()
  "Kill all registered sessions."
  (mapc #'baton-session-kill (baton-session-list)))

(defun baton-session-unread-p (session)
  "Return t if SESSION has output the user has not yet seen."
  (plist-get (baton--session-metadata session) :unread))

(provide 'baton-session)
;;; baton-session.el ends here
