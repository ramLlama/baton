;;; birbal-session.el --- Session struct, registry, lifecycle, hooks  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Manages birbal agent sessions: creation, lifecycle, status tracking, and hooks.
;; Provides the core data model and registry for all birbal sessions.

;;; Code:
(require 'cl-lib)

;;; Data Structures

(cl-defstruct birbal--session
  "An AI agent session managed by birbal."
  name            ; unique string, also used as registry key ("claude-1", or user-provided)
  agent-type      ; symbol, key into birbal-agent-types
  command         ; string, the shell command that was run
  directory       ; string, working directory
  buffer          ; vterm buffer
  status          ; symbol: running | waiting | idle
  waiting-reason  ; string or nil ("permission prompt", "diff review")
  created-at      ; float-time timestamp
  updated-at      ; float-time timestamp
  metadata)       ; plist for agent-type-specific data

;;; Registries

(defvar birbal--sessions (make-hash-table :test 'equal)
  "Hash table mapping session ID strings to `birbal--session' structs.")

(defvar birbal--session-counters (make-hash-table :test 'eq)
  "Hash table mapping agent-type symbols to auto-increment counters.")

;;; Hooks

(defvar birbal-session-created-hook nil
  "Hook called when a session is created.
Each function is called with one argument: the new `birbal--session'.")

(defvar birbal-session-killed-hook nil
  "Hook called when a session is killed.
Each function is called with one argument: the killed `birbal--session'.")

(defvar birbal-session-status-changed-hook nil
  "Hook called when a session's status changes.
Each function is called with three arguments: SESSION, OLD-STATUS, NEW-STATUS.")

(defvar birbal-session-unread-changed-hook nil
  "Hook called when a session transitions from read to unread.
Each function is called with one argument: SESSION.")

;;; Internal Helpers

(defun birbal--agent-type-short-name (agent-type)
  "Return the display prefix for AGENT-TYPE symbol.
For `claude-code', returns \"claude\"; for `aider', returns \"aider\"."
  (car (split-string (symbol-name agent-type) "-")))

(defun birbal--next-session-name (agent-type)
  "Return the next auto-generated display name for AGENT-TYPE.
Increments the counter for AGENT-TYPE and returns \"<prefix>-<n>\"."
  (let ((count (1+ (or (gethash agent-type birbal--session-counters) 0))))
    (puthash agent-type count birbal--session-counters)
    (format "%s-%d" (birbal--agent-type-short-name agent-type) count)))

;;; Public API

(cl-defun birbal-session-create (&key agent-type command directory name)
  "Create and register a new birbal session.
AGENT-TYPE is a symbol key into `birbal-agent-types'.
COMMAND is the shell command string.
DIRECTORY is the working directory.
NAME is optional; auto-generated from AGENT-TYPE if omitted.
Returns the new `birbal--session'."
  (let* ((session-name (or name (birbal--next-session-name agent-type)))
         (now (float-time)))
    (when (gethash session-name birbal--sessions)
      (error "A birbal session named %S already exists" session-name))
    (let* ((session (make-birbal--session
                     :name session-name
                     :agent-type agent-type
                     :command command
                     :directory directory
                     :buffer nil
                     :status 'running
                     :waiting-reason nil
                     :created-at now
                     :updated-at now
                     :metadata nil)))
      (puthash session-name session birbal--sessions)
      (run-hook-with-args 'birbal-session-created-hook session)
      session)))

(defun birbal-session-get (name)
  "Return the session with NAME, or nil if not found."
  (gethash name birbal--sessions))

(defun birbal-session-list (&optional status)
  "Return a list of all sessions.
If STATUS is non-nil, return only sessions with that status symbol."
  (let ((all (hash-table-values birbal--sessions)))
    (if status
        (cl-remove-if-not (lambda (s) (eq (birbal--session-status s) status)) all)
      all)))

(defun birbal-session-set-status (session new-status &optional reason)
  "Set SESSION status to NEW-STATUS with optional waiting REASON.
Fires `birbal-session-status-changed-hook' with (SESSION OLD-STATUS NEW-STATUS)
only when the status or waiting-reason actually changes.
When NEW-STATUS is not `waiting', clears the waiting-reason."
  (let ((old-status (birbal--session-status session))
        (old-reason (birbal--session-waiting-reason session))
        (new-reason (when (eq new-status 'waiting) reason)))
    (unless (and (eq old-status new-status) (equal old-reason new-reason))
      (setf (birbal--session-status session) new-status)
      (setf (birbal--session-waiting-reason session) new-reason)
      (setf (birbal--session-updated-at session) (float-time))
      (run-hook-with-args 'birbal-session-status-changed-hook session old-status new-status))))

(defun birbal-session-find-by-directory (directory)
  "Return the first session whose directory matches DIRECTORY, or nil."
  (cl-find directory (hash-table-values birbal--sessions)
           :key #'birbal--session-directory
           :test #'equal))

(defun birbal-session-kill (session)
  "Kill SESSION: cancel its watcher, kill its buffer, remove from registry.
Fires `birbal-session-killed-hook'."
  ;; Cancel any watcher timer
  (when-let* ((timer (plist-get (birbal--session-metadata session) :watcher-timer)))
    (cancel-timer timer))
  ;; Kill the vterm buffer if alive
  (when-let* ((buf (birbal--session-buffer session)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (set-buffer-modified-p nil))
      (let ((kill-buffer-query-functions nil))
        (kill-buffer buf))))
  ;; Remove from registry and fire hook only when not already done.
  ;; `birbal-process--on-buffer-killed' runs inside kill-buffer above and
  ;; already cleans up registry + fires the hook when the buffer had a live
  ;; session.  Guard here handles the no-buffer case and prevents a second
  ;; hook invocation.
  (when (gethash (birbal--session-name session) birbal--sessions)
    (remhash (birbal--session-name session) birbal--sessions)
    (run-hook-with-args 'birbal-session-killed-hook session)))

(defun birbal-session-kill-all ()
  "Kill all registered sessions."
  (mapc #'birbal-session-kill (birbal-session-list)))

(defun birbal-session-unread-p (session)
  "Return t if SESSION has output the user has not yet seen.
A session is unread when its buffer is not currently visible and its
output hash has changed since the user last switched away from it."
  (let* ((buf (birbal--session-buffer session))
         (meta (birbal--session-metadata session))
         (current (plist-get meta :current-hash))
         (last-seen (plist-get meta :last-seen-hash)))
    (and buf
         (buffer-live-p buf)
         (not (get-buffer-window buf t))
         (not (equal current last-seen)))))

(provide 'birbal-session)
;;; birbal-session.el ends here
