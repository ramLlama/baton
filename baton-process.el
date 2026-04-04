;;; baton-process.el --- vterm spawning, output watching, input sending  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Handles spawning vterm processes for baton sessions, watching their output
;; for status transitions (running -> waiting -> idle), and sending input.
;;
;; Pattern matching functions are pure and have no vterm dependency,
;; making them fully unit-testable.  vterm-dependent functions skip gracefully
;; when vterm is not available.

;;; Code:
(require 'cl-lib)
(require 'baton-session)

(defvar vterm-shell)
(defvar vterm-term-environment-variable)
(defvar vterm-buffer-name-string)
(defvar vterm--redraw-immediately)
(defvar baton-term-name)
(defvar baton-agents)

(declare-function vterm-mode          "vterm" ())
(declare-function vterm-send-string   "vterm" (string &optional paste-p))
(declare-function vterm-send-key      "vterm" (key &optional shift meta ctrl))

;;; Status Function Utilities (pure, no vterm dependency)

(defun baton-process-session-tail (session)
  "Return the last `baton-process--scan-lines' lines of SESSION's buffer, or \"\"."
  (let ((buf (baton--session-buffer session)))
    (if (and buf (buffer-live-p buf))
        (baton-process--buffer-tail buf)
      "")))

(defun baton-process-make-regex-status-function (patterns)
  "Return a status function built from PATTERNS.
PATTERNS is an alist of (REGEXP . (SYMBOL . REASON)) pairs.
SYMBOL may be waiting, error, other, running, or idle.
The returned function takes SESSION and returns (SYMBOL . REASON) for
the first matching REGEXP, or nil if none match."
  (lambda (session)
    (let ((text (baton-process-session-tail session)))
      (when-let* ((match (cl-find-if
                          (lambda (entry) (string-match-p (car entry) text))
                          patterns)))
        (cdr match)))))

;;; Buffer-local session reference

(defvar-local baton--current-session nil
  "The `baton--session' associated with this vterm buffer.")

;;; vterm Spawning

(defun baton-process-spawn (session)
  "Spawn a vterm buffer for SESSION and start the output watcher.
Requires the `vterm' feature.  The session command is launched directly
as the vterm shell (no interactive shell prompt).  The vterm buffer is
named \"*baton:<name>*\" and the session's buffer slot is updated."
  (unless (featurep 'vterm)
    (error "baton-process-spawn requires vterm"))
  (require 'vterm)
  (let* ((dir (or (baton--session-directory session) default-directory))
         (command (baton--session-command session))
         (buf-name (format "*baton:%s*" (baton--session-name session)))
         (buf (get-buffer-create buf-name))
         ;; Dynamic bindings: vterm-mode reads these during initialization.
         ;; vterm-shell launches the agent command directly instead of $SHELL.
         (vterm-shell command)
         (vterm-term-environment-variable baton-term-name))
    (with-current-buffer buf
      (let ((default-directory (file-name-as-directory dir)))
        ;; vterm-mode must run while the buffer is in a real window so the
        ;; PTY gets the correct terminal size (TIOCGWINSZ).  Deleting the
        ;; window afterwards resizes the PTY to 0; if the agent process
        ;; queries the terminal size before the window reappears it will
        ;; see degenerate dimensions and may disable its TUI/colors.
        ;; save-selected-window keeps the buffer in a visible window
        ;; without clobbering the user's selection; baton-new's
        ;; pop-to-buffer then switches focus to the buffer.
        (save-selected-window
          (pop-to-buffer buf)
          (let* ((agent-def (gethash (baton--session-agent session)
                                     baton-agents))
                 (env-fns   (and agent-def (plist-get agent-def :env-functions)))
                 (extra-env (when env-fns
                              (apply #'append
                                     (mapcar (lambda (fn)
                                               (funcall fn (baton--session-name session) dir))
                                             env-fns))))
                 (process-environment (if extra-env
                                          (append extra-env process-environment)
                                        process-environment)))
            (vterm-mode))))
      (setq-local baton--current-session session)
      ;; Anchor dired (C-x d) and other directory-sensitive commands to the
      ;; session's working directory, not Emacs's global default-directory.
      (setq-local default-directory (file-name-as-directory dir))
      ;; Prevent vterm from overriding our buffer name with a process title.
      (setq-local vterm-buffer-name-string nil)
      ;; Let vterm manage the cursor entirely; without this Emacs renders its
      ;; own cursor at buffer position 0 while vterm's overlay cursor is
      ;; elsewhere, making it appear as if there is no cursor.
      (setq-local cursor-type nil)
      (setq-local cursor-in-non-selected-windows nil)
      ;; Batch redraws to reduce flicker (matches claude-code's approach).
      (setq-local vterm--redraw-immediately nil)
      ;; Reset to running when the user types
      (add-hook 'pre-command-hook #'baton-process--on-input nil t)
      ;; Remove session from registry if the buffer is killed externally
      (add-hook 'kill-buffer-hook #'baton-process--on-buffer-killed nil t))
    (setf (baton--session-buffer session) buf)
    ;; Initialize watcher metadata
    (let ((now (float-time)))
      (setf (baton--session-metadata session)
            (list :last-output-time now
                  :last-output-hash ""
                  :state nil
                  :unread nil
                  :notified-at nil)))
    (baton-process--start-watcher session)
    buf))

(defun baton-process-send-input (session string)
  "Send STRING to SESSION's vterm buffer and reset status to running."
  (when-let* ((buf (baton--session-buffer session)))
    (when (buffer-live-p buf)
      (baton-process--reset-to-running session)
      (with-current-buffer buf
        (vterm-send-string string)))))

(defun baton-process-send-key (session key)
  "Send KEY (a string like \"RET\") to SESSION's vterm buffer.
Resets session status to running."
  (when-let* ((buf (baton--session-buffer session)))
    (when (buffer-live-p buf)
      (baton-process--reset-to-running session)
      (with-current-buffer buf
        (vterm-send-key key)))))

;;; Input Detection

(defun baton-process--on-buffer-killed ()
  "Handle external kill of a session's vterm buffer.
Called from `kill-buffer-hook' in the vterm buffer.  Cancels the watcher
timer and removes the session from the registry without trying to kill
the buffer again (it is already being killed)."
  (when baton--current-session
    (let* ((session baton--current-session)
           (id (baton--session-name session)))
      ;; Cancel watcher timer
      (when-let* ((timer (plist-get (baton--session-metadata session) :watcher-timer)))
        (cancel-timer timer))
      ;; Remove from registry and fire hook (buffer is already dying, skip kill-buffer)
      (remhash id baton--sessions)
      (run-hook-with-args 'baton-session-killed-hook session))))

(defun baton-process--reset-to-running (session)
  "Reset SESSION to `running' status if it is not already running."
  (unless (eq (baton--session-status session) 'running)
    (baton-session-set-status session 'running)))

(defconst baton-process--input-commands
  '(vterm--self-insert vterm-send-key vterm-send-return vterm-send-string
    vterm-send-backspace vterm-send-tab vterm-send-up vterm-send-down
    vterm-send-left vterm-send-right vterm-send-ctrl-c vterm-send-ctrl-d
    vterm-send-ctrl-z vterm-send-escape vterm-send-meta-backspace)
  "vterm commands that count as user input for status-reset purposes.")

(defun baton-process--on-input ()
  "Reset session to `running' when the user sends input to the vterm.
Handles any non-running session.  Also resets the quiet-period clock so the
watcher does not immediately re-derive the prior state."
  (when (and baton--current-session
             (not (eq (baton--session-status baton--current-session) 'running))
             (memq this-command baton-process--input-commands))
    (baton-session-set-status baton--current-session 'running)
    (setf (baton--session-metadata baton--current-session)
          (plist-put (baton--session-metadata baton--current-session)
                     :last-output-time (float-time)))))

;;; Output Watcher

(defconst baton-process--watcher-interval 0.5
  "Interval in seconds between output watcher ticks.")

(defconst baton-process--scan-lines 250
  "Number of lines from end of buffer to scan for patterns.")

(defconst baton-process--quiet-threshold 0.5
  "Seconds of output quiet required before transitioning to waiting or idle status.")

(defun baton-process--buffer-tail (buf)
  "Return the last `baton-process--scan-lines' lines of BUF as a string."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-max))
      (forward-line (- baton-process--scan-lines))
      (buffer-substring-no-properties (point) (point-max)))))

(defun baton-process--start-watcher (session)
  "Start the output watcher timer for SESSION if its agent uses :periodic trigger.
Stores the timer in SESSION's metadata under :watcher-timer."
  (let* ((agent-sym (baton--session-agent session))
         (agent-def (and (boundp 'baton-agents) (gethash agent-sym baton-agents)))
         (trigger (and agent-def (plist-get agent-def :status-function-trigger))))
    (when (eq trigger :periodic)
      (let ((timer (run-with-timer baton-process--watcher-interval
                                   baton-process--watcher-interval
                                   #'baton-process--state-tick
                                   session)))
        (setf (baton--session-metadata session)
              (plist-put (baton--session-metadata session) :watcher-timer timer))))))

(defun baton-process--tick-set-status (session status reason)
  "Set SESSION status to STATUS with REASON, writing :state metadata if changed."
  (let ((pre-updated-at (baton--session-updated-at session)))
    (baton-session-set-status session status reason)
    (when (> (baton--session-updated-at session) pre-updated-at)
      (setf (baton--session-metadata session)
            (plist-put (baton--session-metadata session)
                       :state (list :status status :reason reason :at (float-time)))))))

(defun baton-process--state-tick (session)
  "Observe SESSION's output and derive its current status.
Cancels the timer if the buffer is no longer live.  State is computed
fresh each tick: `running' if output changed, `waiting' if quiet and a
waiting pattern matches, `idle' otherwise.  Only started for :periodic
sessions; does not call the status function for :on-event sessions."
  (let ((buf (baton--session-buffer session)))
    (if (not (and buf (buffer-live-p buf)))
        ;; Buffer gone — stop watching
        (when-let* ((timer (plist-get (baton--session-metadata session) :watcher-timer)))
          (cancel-timer timer))
      ;; Buffer alive — derive state from observation
      (let* ((text (baton-process--buffer-tail buf))
             (current-hash (md5 text))
             (meta (baton--session-metadata session))
             (last-hash (or (plist-get meta :last-output-hash) ""))
             (last-time (or (plist-get meta :last-output-time) (float-time)))
             (now (float-time))
             (hash-changed (not (equal current-hash last-hash))))
        ;; Track when output last changed
        (when hash-changed
          (setf (baton--session-metadata session)
                (plist-put (baton--session-metadata session) :last-output-hash current-hash))
          (setf (baton--session-metadata session)
                (plist-put (baton--session-metadata session) :last-output-time now))
          (setq last-time now))
        ;; Derive status; baton-session-set-status is a no-op when nothing changed.
        (cond
         (hash-changed
          (baton-process--tick-set-status session 'running nil))
         ((>= (- now last-time) baton-process--quiet-threshold)
          (let* ((agent-sym (baton--session-agent session))
                 (agent-def (and (boundp 'baton-agents)
                                 (gethash agent-sym baton-agents)))
                 (status-fn  (and agent-def (plist-get agent-def :status-function)))
                 (trigger    (and agent-def (plist-get agent-def :status-function-trigger)))
                 (raw-result (when (and status-fn (eq trigger :periodic))
                               (funcall status-fn session)))
                 ;; Preserve "diff review" while a pending diff awaits the user,
                 ;; regardless of what the status function returns.
                 (result (if (plist-get meta :pending-diff)
                             '(waiting . "diff review")
                           raw-result)))
            (pcase (and (consp result) (car result))
              ('waiting (baton-process--tick-set-status session 'waiting (cdr result)))
              ('running (baton-process--tick-set-status session 'running nil))
              ('error   (baton-process--tick-set-status session 'error   (cdr result)))
              ('other   (baton-process--tick-set-status session 'other   (cdr result)))
              (_        (baton-process--tick-set-status session 'idle    nil))))))))))

(provide 'baton-process)
;;; baton-process.el ends here
