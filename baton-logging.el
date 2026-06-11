;;; baton-logging.el --- Advice-based debug logging for baton  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Temporary debug tooling, deliberately kept out of the main implementation
;; files so it can be dropped wholesale.  Call `baton-toggle-logging' to
;; trace the spawn/executor/sodagun call paths into the *baton-log* buffer
;; via :around advice (the same enable/disable approach as
;; `monet-enable-logging').
;;
;; Usage:
;;   (require 'baton-logging)
;;   (baton-toggle-logging)      ; toggle
;;   (baton-toggle-logging t)    ; force on
;;   (baton-toggle-logging nil)  ; force off

;;; Code:
(require 'cl-lib)

(defvar baton-logging--enabled nil
  "Non-nil when baton debug logging advice is installed.")

(defconst baton-logging--buffer-name "*baton-log*"
  "Name of the buffer baton debug logs are appended to.")

(defconst baton-logging--max-entry-length 1000
  "Maximum printed length of logged argument/result values.")

(defconst baton-logging--traced-functions
  '(baton-new
    baton-session-create
    baton-session-kill
    baton-process-spawn
    baton-process--on-buffer-killed
    baton-executor--resolve
    baton-executor--teardown
    baton-executor--agent-env
    baton-term-spawn-in-buffer
    baton-term--activate
    baton-sodagun--run
    baton-sodagun--add-worktree
    baton-sodagun--sandbox-start
    baton-sodagun--remove-sandbox
    baton-sodagun--attach-command)
  "Functions traced by `baton-toggle-logging'.
Symbols that are not `fboundp' at enable time (e.g. baton-sodagun when the
CLI is absent) are skipped silently.")

(defun baton-logging--log (format-string &rest args)
  "Append a timestamped FORMAT-STRING/ARGS line to the log buffer."
  (let ((log-buffer (get-buffer-create baton-logging--buffer-name)))
    (with-current-buffer log-buffer
      (goto-char (point-max))
      (insert (format-time-string "[%H:%M:%S.%3N] ")
              (apply #'format format-string args)
              "\n")
      ;; Auto-scroll if the log buffer is visible in any window.
      (when-let* ((window (get-buffer-window log-buffer)))
        (with-selected-window window
          (goto-char (point-max)))))))

(defun baton-logging--print (value)
  "Return VALUE printed and truncated to `baton-logging--max-entry-length'."
  (let ((printed (format "%S" value)))
    (if (> (length printed) baton-logging--max-entry-length)
        (concat (substring printed 0 baton-logging--max-entry-length) "…")
      printed)))

(defun baton-logging--describe-current-buffer ()
  "Return a one-line description of the current buffer and its process.
Used when a session buffer is killed: the buffer tail usually contains
the reason the terminal process died (e.g. a shell error)."
  (let ((proc (get-buffer-process (current-buffer))))
    (format "buffer=%s proc=%s status=%S exit=%S tail=%s"
            (buffer-name)
            (and proc (process-name proc))
            (and proc (process-status proc))
            (and proc (process-exit-status proc))
            (baton-logging--print
             (buffer-substring-no-properties
              (max (point-min) (- (point-max) 2000))
              (point-max))))))

(defun baton-logging--around (fn-name orig &rest args)
  "Log entry, exit, and errors of ORIG (named FN-NAME) applied to ARGS."
  ;; The buffer-killed handler takes no args — the evidence is the buffer.
  (when (eq fn-name 'baton-process--on-buffer-killed)
    (baton-logging--log "  %s" (baton-logging--describe-current-buffer)))
  (baton-logging--log "→ %s %s" fn-name (baton-logging--print args))
  (condition-case err
      (let ((result (apply orig args)))
        (baton-logging--log "← %s ⇒ %s" fn-name (baton-logging--print result))
        result)
    (error
     (baton-logging--log "✗ %s signaled %S" fn-name err)
     (signal (car err) (cdr err)))))

(defun baton-logging--enable ()
  "Install logging advice on all traced functions."
  (dolist (fn baton-logging--traced-functions)
    (when (fboundp fn)
      (advice-add fn :around
                  (lambda (orig &rest args)
                    (apply #'baton-logging--around fn orig args))
                  `((name . ,(intern (format "baton-logging--%s" fn)))))))
  (setq baton-logging--enabled t)
  (baton-logging--log "=== baton logging enabled ===")
  (message "baton: logging enabled — see %s" baton-logging--buffer-name))

(defun baton-logging--disable ()
  "Remove logging advice from all traced functions."
  (dolist (fn baton-logging--traced-functions)
    (advice-remove fn (intern (format "baton-logging--%s" fn))))
  (setq baton-logging--enabled nil)
  (message "baton: logging disabled"))

;;;###autoload
(defun baton-toggle-logging (&rest force)
  "Toggle copious baton debug logging into the *baton-log* buffer.
Called with no argument, toggles.  FORCE, when given, forces logging on
\(non-nil) or off (nil): (baton-toggle-logging t) / (baton-toggle-logging
nil).  Logging works by adding :around advice to the functions in
`baton-logging--traced-functions'."
  (interactive)
  (let ((enable (if force (car force) (not baton-logging--enabled))))
    (if enable
        (baton-logging--enable)
      (baton-logging--disable))))

(provide 'baton-logging)
;;; baton-logging.el ends here
