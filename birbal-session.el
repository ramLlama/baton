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
  id              ; unique string (timestamp-based)
  name            ; display name ("claude-1", "aider-1", or user-provided)
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

(defun birbal--generate-id ()
  "Generate a unique session ID based on current time."
  (format "%.6f-%d" (float-time) (random 100000)))

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
         (id (birbal--generate-id))
         (now (float-time))
         (session (make-birbal--session
                   :id id
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
    (puthash id session birbal--sessions)
    (run-hook-with-args 'birbal-session-created-hook session)
    session))

(defun birbal-session-get (id)
  "Return the session with ID, or nil if not found."
  (gethash id birbal--sessions))

(defun birbal-session-list (&optional status)
  "Return a list of all sessions.
If STATUS is non-nil, return only sessions with that status symbol."
  (let ((all (hash-table-values birbal--sessions)))
    (if status
        (cl-remove-if-not (lambda (s) (eq (birbal--session-status s) status)) all)
      all)))

(defun birbal-session-set-status (session new-status &optional reason)
  "Set SESSION status to NEW-STATUS with optional waiting REASON.
Fires `birbal-session-status-changed-hook' with (SESSION OLD-STATUS NEW-STATUS).
When NEW-STATUS is not `waiting', clears the waiting-reason."
  (let ((old-status (birbal--session-status session)))
    (setf (birbal--session-status session) new-status)
    (setf (birbal--session-waiting-reason session)
          (when (eq new-status 'waiting) reason))
    (setf (birbal--session-updated-at session) (float-time))
    (run-hook-with-args 'birbal-session-status-changed-hook session old-status new-status)))

(defun birbal-session-find-by-directory (directory)
  "Return the first session whose directory matches DIRECTORY, or nil."
  (cl-find directory (hash-table-values birbal--sessions)
           :key #'birbal--session-directory
           :test #'equal))

(defun birbal-session-kill (session)
  "Kill SESSION: cancel its watcher, kill its buffer, remove from registry.
Fires `birbal-session-killed-hook'."
  (let ((id (birbal--session-id session)))
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
    ;; Remove from registry
    (remhash id birbal--sessions)
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
