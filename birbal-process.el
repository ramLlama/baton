;;; birbal-process.el --- vterm spawning, output watching, input sending  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Handles spawning vterm processes for birbal sessions, watching their output
;; for status transitions (running -> waiting -> done), and sending input.
;;
;; Pattern matching functions are pure and have no vterm dependency,
;; making them fully unit-testable.  vterm-dependent functions skip gracefully
;; when vterm is not available.

;;; Code:
(require 'cl-lib)
(require 'birbal-session)

(defvar vterm-shell)
(defvar vterm-term-environment-variable)
(defvar vterm-buffer-name-string)
(defvar vterm--redraw-immididately)
(defvar birbal-term-name)

;;; Pattern Matching (pure, no vterm dependency)

(defun birbal-process--match-patterns (text waiting-patterns done-patterns)
  "Match TEXT against WAITING-PATTERNS and DONE-PATTERNS.
WAITING-PATTERNS is an alist of (REGEXP . REASON) strings.
DONE-PATTERNS is a list of regexp strings.

Returns:
  (cons :waiting REASON)  if a waiting pattern matched
  :done                   if a done pattern matched
  nil                     if no pattern matched"
  (let ((waiting-match
         (cl-find-if (lambda (entry) (string-match-p (car entry) text))
                     waiting-patterns)))
    (cond
     (waiting-match (cons :waiting (cdr waiting-match)))
     ((cl-find-if (lambda (p) (string-match-p p text)) done-patterns) :done)
     (t nil))))

;;; Buffer-local session reference

(defvar-local birbal--current-session nil
  "The `birbal--session' associated with this vterm buffer.")

;;; vterm Spawning

(defun birbal-process-spawn (session)
  "Spawn a vterm buffer for SESSION and start the output watcher.
Requires the `vterm' feature.  The session command is launched directly
as the vterm shell (no interactive shell prompt).  The vterm buffer is
named \"*birbal:<name>*\" and the session's buffer slot is updated."
  (unless (featurep 'vterm)
    (error "birbal-process-spawn requires vterm"))
  (require 'vterm)
  (let* ((dir (or (birbal--session-directory session) default-directory))
         (command (birbal--session-command session))
         (buf-name (format "*birbal:%s*" (birbal--session-name session)))
         (buf (get-buffer-create buf-name))
         ;; Dynamic bindings: vterm-mode reads these during initialization.
         ;; vterm-shell launches the agent command directly instead of $SHELL.
         (vterm-shell command)
         (vterm-term-environment-variable birbal-term-name))
    (with-current-buffer buf
      (let ((default-directory (file-name-as-directory dir)))
        ;; vterm-mode must run while the buffer is in a real window so the
        ;; PTY gets the correct terminal size (TIOCGWINSZ).  Deleting the
        ;; window afterwards resizes the PTY to 0; if the agent process
        ;; queries the terminal size before the window reappears it will
        ;; see degenerate dimensions and may disable its TUI/colors.
        ;; save-selected-window keeps the buffer in a visible window
        ;; without clobbering the user's selection; birbal-new's
        ;; pop-to-buffer then switches focus to the buffer.
        (save-selected-window
          (pop-to-buffer buf)
          (vterm-mode)))
      (setq-local birbal--current-session session)
      ;; Prevent vterm from overriding our buffer name with a process title.
      (setq-local vterm-buffer-name-string nil)
      ;; Let vterm manage the cursor entirely; without this Emacs renders its
      ;; own cursor at buffer position 0 while vterm's overlay cursor is
      ;; elsewhere, making it appear as if there is no cursor.
      (setq-local cursor-type nil)
      (setq-local cursor-in-non-selected-windows nil)
      ;; Batch redraws to reduce flicker (matches claude-code's approach).
      (setq-local vterm--redraw-immididately nil)
      ;; Reset to running when the user types
      (add-hook 'pre-command-hook #'birbal-process--on-input nil t)
      ;; Remove session from registry if the buffer is killed externally
      (add-hook 'kill-buffer-hook #'birbal-process--on-buffer-killed nil t))
    (setf (birbal--session-buffer session) buf)
    ;; Initialize watcher metadata
    (let ((now (float-time)))
      (setf (birbal--session-metadata session)
            (plist-put (birbal--session-metadata session) :last-output-time now))
      (setf (birbal--session-metadata session)
            (plist-put (birbal--session-metadata session) :last-output-hash "")))
    (birbal-process--start-watcher session)
    buf))

(defun birbal-process-send-input (session string)
  "Send STRING to SESSION's vterm buffer and reset status to running."
  (when-let* ((buf (birbal--session-buffer session)))
    (when (buffer-live-p buf)
      (birbal-process--reset-to-running session)
      (with-current-buffer buf
        (vterm-send-string string)))))

(defun birbal-process-send-key (session key)
  "Send KEY (a string like \"RET\") to SESSION's vterm buffer.
Resets session status to running."
  (when-let* ((buf (birbal--session-buffer session)))
    (when (buffer-live-p buf)
      (birbal-process--reset-to-running session)
      (with-current-buffer buf
        (vterm-send-key key)))))

;;; Input Detection

(defun birbal-process--on-buffer-killed ()
  "Handle external kill of a session's vterm buffer.
Called from `kill-buffer-hook' in the vterm buffer.  Cancels the watcher
timer and removes the session from the registry without trying to kill
the buffer again (it is already being killed)."
  (when birbal--current-session
    (let* ((session birbal--current-session)
           (id (birbal--session-id session)))
      ;; Cancel watcher timer
      (when-let* ((timer (plist-get (birbal--session-metadata session) :watcher-timer)))
        (cancel-timer timer))
      ;; Remove from registry and fire hook (buffer is already dying, skip kill-buffer)
      (remhash id birbal--sessions)
      (run-hook-with-args 'birbal-session-killed-hook session))))

(defun birbal-process--reset-to-running (session)
  "Reset SESSION to `running' status if it is currently `waiting'."
  (when (eq (birbal--session-status session) 'waiting)
    (birbal-session-set-status session 'running)))

(defconst birbal-process--input-commands
  '(vterm--self-insert vterm-send-key vterm-send-return vterm-send-string
    vterm-send-backspace vterm-send-tab vterm-send-up vterm-send-down
    vterm-send-left vterm-send-right vterm-send-ctrl-c vterm-send-ctrl-d
    vterm-send-ctrl-z vterm-send-escape vterm-send-meta-backspace)
  "vterm commands that count as user input for status-reset purposes.")

(defun birbal-process--on-input ()
  "Reset session to `running' when the user sends actual input to the vterm.
Guards against false positives from scrolling and other non-input commands."
  (when (and birbal--current-session
             (eq (birbal--session-status birbal--current-session) 'waiting)
             (memq this-command birbal-process--input-commands))
    (birbal-session-set-status birbal--current-session 'running)))

;;; Output Watcher

(defconst birbal-process--watcher-interval 0.5
  "Interval in seconds between output watcher ticks.")

(defconst birbal-process--scan-lines 250
  "Number of lines from end of buffer to scan for patterns.")

(defconst birbal-process--quiet-threshold 0.5
  "Seconds of output quiet required before transitioning to waiting status.")

(defun birbal-process--buffer-tail (buf)
  "Return the last `birbal-process--scan-lines' lines of BUF as a string."
  (with-current-buffer buf
    (save-excursion
      (goto-char (point-max))
      (forward-line (- birbal-process--scan-lines))
      (buffer-substring-no-properties (point) (point-max)))))

(defun birbal-process--start-watcher (session)
  "Start the output watcher timer for SESSION.
Stores the timer in SESSION's metadata under :watcher-timer."
  (let ((timer (run-with-timer birbal-process--watcher-interval
                               birbal-process--watcher-interval
                               #'birbal-process--watcher-tick
                               session)))
    (setf (birbal--session-metadata session)
          (plist-put (birbal--session-metadata session) :watcher-timer timer))))

(defun birbal-process--watcher-tick (session)
  "Check SESSION's output and update status if warranted.
Cancels the timer if the buffer is no longer live.
Only transitions `running' sessions; done sessions are left alone."
  (let ((buf (birbal--session-buffer session)))
    (if (not (and buf (buffer-live-p buf)))
        ;; Buffer gone — stop watching
        (when-let* ((timer (plist-get (birbal--session-metadata session) :watcher-timer)))
          (cancel-timer timer))
      ;; Buffer alive — only act on running sessions
      (when (eq (birbal--session-status session) 'running)
        (let* ((text (birbal-process--buffer-tail buf))
               (current-hash (md5 text))
               (meta (birbal--session-metadata session))
               (last-hash (or (plist-get meta :last-output-hash) ""))
               (last-time (or (plist-get meta :last-output-time) (float-time)))
               (now (float-time)))
          ;; Track when output last changed
          (unless (equal current-hash last-hash)
            (setf (birbal--session-metadata session)
                  (plist-put (birbal--session-metadata session)
                             :last-output-hash current-hash))
            (setf (birbal--session-metadata session)
                  (plist-put (birbal--session-metadata session)
                             :last-output-time now))
            (setq last-time now))
          ;; Only check patterns after output has been quiet for the threshold
          (when (>= (- now last-time) birbal-process--quiet-threshold)
            (let* ((agent-type-sym (birbal--session-agent-type session))
                   (agent-def (and (boundp 'birbal-agent-types)
                                   (gethash agent-type-sym birbal-agent-types)))
                   (waiting-patterns (and agent-def (plist-get agent-def :waiting-patterns)))
                   (done-patterns (and agent-def (plist-get agent-def :done-patterns)))
                   (result (birbal-process--match-patterns
                            text waiting-patterns done-patterns)))
              (cond
               ((and (consp result) (eq (car result) :waiting))
                (birbal-session-set-status session 'waiting (cdr result)))
               ((eq result :done)
                (birbal-session-set-status session 'done)
                (when-let* ((timer (plist-get (birbal--session-metadata session)
                                              :watcher-timer)))
                  (cancel-timer timer)))))))))))

(provide 'birbal-process)
;;; birbal-process.el ends here
