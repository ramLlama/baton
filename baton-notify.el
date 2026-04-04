;;; baton-notify.el --- Modeline indicator, status buffer, alerts  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Provides the user-facing notification surface for baton:
;;   - A modeline segment showing waiting/idle/running counts and unread marker
;;   - A `*Baton*' status buffer (ibuffer-style tabulated list)
;;   - `baton-jump' and `baton-jump-to-waiting' for completing-read navigation
;;   - A `baton-notify-function' hook for alerting the user

;;; Code:
(require 'cl-lib)
(require 'baton-session)

(declare-function baton-new "baton" (agent-name directory &optional name))

;;; Faces

(defface baton-face-waiting
  '((t :inherit warning))
  "Face for sessions in `waiting' status."
  :group 'baton)

(defface baton-face-idle
  '((t :inherit shadow))
  "Face for sessions in `idle' status."
  :group 'baton)

(defface baton-face-running
  '((t :inherit success))
  "Face for sessions in `running' status."
  :group 'baton)

(defface baton-face-error
  '((t :inherit error))
  "Face for sessions in `error' status."
  :group 'baton)

(defface baton-face-other
  '((t :inherit shadow))
  "Face for sessions in `other' status."
  :group 'baton)

(defface baton-face-unread
  '((t :inherit font-lock-warning-face))
  "Face for the unread output indicator."
  :group 'baton)

(defface baton-face-modeline-alert
  '((t :background "yellow" :foreground "black" :inherit mode-line))
  "Face for the modeline segment when one or more sessions are waiting."
  :group 'baton)

;;; Notification Function

(defcustom baton-notify-function #'baton-notify--default
  "Function called when a session needs attention.
Called with one argument: the `baton--session'.  Invoked when a session
transitions to `waiting' status, and when output arrives in a session
buffer the user is not currently viewing (unread)."
  :type 'function
  :group 'baton)

(defun baton-notify--default (session)
  "Default notification: display a message in the echo area for SESSION."
  (message "baton: %s needs attention (%s)"
           (baton--session-name session)
           (or (baton--session-waiting-reason session) "unread output")))

;;; Modeline Markers

(defcustom baton-marker-waiting "w"
  "Modeline marker for waiting sessions.  Can be set to an emoji, e.g. \"⏳\"."
  :type 'string
  :group 'baton)

(defcustom baton-marker-idle "i"
  "Modeline marker for idle sessions.  Can be set to an emoji, e.g. \"💤\"."
  :type 'string
  :group 'baton)

(defcustom baton-marker-running "r"
  "Modeline marker for running sessions.  Can be set to an emoji, e.g. \"🏃\"."
  :type 'string
  :group 'baton)

(defcustom baton-marker-error "e"
  "Modeline marker for error sessions.  Can be set to an emoji, e.g. \"💥\"."
  :type 'string
  :group 'baton)

(defcustom baton-marker-other "o"
  "Modeline marker for sessions in `other' status."
  :type 'string
  :group 'baton)

(defcustom baton-marker-unread "*"
  "Modeline marker for unread sessions.  Can be set to an emoji, e.g. \"📬\"."
  :type 'string
  :group 'baton)

;;; Modeline

(defun baton-notify--modeline-string ()
  "Return a propertized modeline string showing agent counts.
Format: \" B[Nw/Ne/No/Ni/Nr N*]\" — segments omitted when zero; `*' count
omitted when no unread sessions.  The whole string is highlighted with
`baton-face-modeline-alert' (yellow background) when any session is
waiting or in error.  Markers are controlled by `baton-marker-waiting',
`baton-marker-error', `baton-marker-other', `baton-marker-idle',
`baton-marker-running', and `baton-marker-unread'."
  (let ((waiting 0) (error-count 0) (other 0) (idle 0) (running 0) (unread 0))
    (dolist (s (baton-session-list))
      (pcase (baton--session-status s)
        ('waiting (cl-incf waiting))
        ('error   (cl-incf error-count))
        ('other   (cl-incf other))
        ('idle    (cl-incf idle))
        ('running (cl-incf running)))
      (when (and (not (eq (baton--session-status s) 'running))
                 (baton-session-unread-p s))
        (cl-incf unread)))
    (if (zerop (+ waiting error-count other idle running))
        ""
      (let* ((parts (delq nil
                          (list (when (> waiting     0) (format "%d%s" waiting     baton-marker-waiting))
                                (when (> error-count 0) (format "%d%s" error-count baton-marker-error))
                                (when (> other       0) (format "%d%s" other       baton-marker-other))
                                (when (> idle        0) (format "%d%s" idle        baton-marker-idle))
                                (when (> running     0) (format "%d%s" running     baton-marker-running)))))
             (counts (mapconcat #'identity parts "/"))
             (unread-str (if (> unread 0) (format " %d%s" unread baton-marker-unread) ""))
             (str (format " B[%s%s]" counts unread-str))
             (face (if (zerop (+ waiting error-count)) 'mode-line 'baton-face-modeline-alert))
             (map (make-sparse-keymap)))
        (define-key map [mode-line mouse-1] #'baton-list)
        (propertize str
                    'face face
                    'mouse-face 'mode-line-highlight
                    'help-echo "baton: click to open status buffer"
                    'local-map map)))))

(defvar baton--modeline-segment
  '(:eval (baton-notify--modeline-string))
  "Modeline segment for baton.")

;;;###autoload
(define-minor-mode baton-modeline-mode
  "Show baton agent counts in the modeline."
  :global t
  :group 'baton
  (if baton-modeline-mode
      (progn
        (add-to-list 'global-mode-string baton--modeline-segment t)
        (force-mode-line-update t))
    (setq global-mode-string
          (delete baton--modeline-segment global-mode-string))
    (force-mode-line-update t)))

(defun baton-notify--update-modeline (&rest _)
  "Refresh the modeline."
  (force-mode-line-update t))

(defcustom baton-notify-delay 5
  "Seconds to wait after a session needs attention before sending a notification."
  :type 'number
  :group 'baton)

(defun baton-notify--maybe-notify (session)
  "Fire `baton-notify-function' for SESSION if it needs attention.
Notifies when status is `waiting', or non-running with unread output.
Returns non-nil if the notification was fired."
  (let ((status (baton--session-status session)))
    (when (or (eq status 'waiting)
              (and (memq status '(error other idle))
                   (baton-session-unread-p session)))
      (funcall baton-notify-function session)
      t)))

(defvar baton-notify--global-timer nil
  "Timer that drives global notification polling and unread clearing.")

(defun baton-notify--global-tick ()
  "Global timer tick: clear unread for visible sessions, fire pending notifications."
  (let ((now (float-time)))
    (dolist (session (baton-session-list))
      (let* ((buf (baton--session-buffer session))
             (meta (baton--session-metadata session))
             (state (plist-get meta :state))
             (state-at (and state (plist-get state :at)))
             (notified-at (plist-get meta :notified-at)))
        ;; Clear unread when the buffer is visible
        (when (and (plist-get meta :unread)
                   buf (buffer-live-p buf)
                   (get-buffer-window buf t))
          (setf (baton--session-metadata session)
                (plist-put (baton--session-metadata session) :unread nil))
          (run-hook-with-args 'baton-session-unread-changed-hook session))
        ;; Fire notification after baton-notify-delay seconds of stability.
        ;; Guard: skip if :state is stale (live status has diverged, e.g. reset
        ;; to running by user input before the delay elapsed).
        (when (and state-at
                   (eq (plist-get state :status) (baton--session-status session))
                   (>= (- now state-at) baton-notify-delay)
                   (or (null notified-at) (> state-at notified-at)))
          (when (baton-notify--maybe-notify session)
            (setf (baton--session-metadata session)
                  (plist-put (baton--session-metadata session) :notified-at now)))))))
  (force-mode-line-update t))

(defun baton-notify--start-global-timer ()
  "Start the global notification and unread tracking timer."
  (unless baton-notify--global-timer
    (setq baton-notify--global-timer
          (run-with-timer 0.5 0.5 #'baton-notify--global-tick))))

(defun baton-notify--stop-global-timer ()
  "Stop the global notification and unread tracking timer."
  (when baton-notify--global-timer
    (cancel-timer baton-notify--global-timer)
    (setq baton-notify--global-timer nil)))

(defun baton-notify--on-status-changed-mark-unread (session _old-status new-status)
  "Handle SESSION status change: mark unread if buffer not visible."
  (when (memq new-status '(waiting idle error other))
    (let* ((buf (baton--session-buffer session))
           (meta (baton--session-metadata session)))
      (when (and buf (buffer-live-p buf)
                 (not (get-buffer-window buf t))
                 (not (plist-get meta :unread)))
        (setf (baton--session-metadata session)
              (plist-put (baton--session-metadata session) :unread t))
        (run-hook-with-args 'baton-session-unread-changed-hook session))))
  (baton-notify--refresh-list-buffer))

(defun baton-notify--on-session-event (&rest _)
  "Handle session creation or destruction."
  (force-mode-line-update t)
  (baton-notify--refresh-list-buffer))

(defun baton-notify--on-unread-changed (_session)
  "Handle SESSION becoming unread."
  (force-mode-line-update t)
  (baton-notify--refresh-list-buffer))

;;; Status Buffer (`*Baton*')

(defvar-local baton--list-marks nil
  "Alist of (SESSION-ID . OPERATION) for pending operations in the status buffer.")

(defun baton-notify--session-indicator (session)
  "Return a status indicator string for SESSION."
  (pcase (baton--session-status session)
    ('waiting (propertize "●" 'face 'baton-face-waiting))
    ('running (propertize "▷" 'face 'baton-face-running))
    ('error   (propertize "✕" 'face 'baton-face-error))
    ('other   (propertize "?" 'face 'baton-face-other))
    ('idle
     (if (baton-session-unread-p session)
         (concat (propertize "○" 'face 'baton-face-idle)
                 (propertize "*" 'face 'baton-face-unread))
       (propertize "○" 'face 'baton-face-idle)))
    (_ " ")))

(defun baton-notify--session-face (session)
  "Return the display face for SESSION based on its status."
  (pcase (baton--session-status session)
    ('waiting 'baton-face-waiting)
    ('error   'baton-face-error)
    ('other   'baton-face-other)
    ('idle    'baton-face-idle)
    (_        'default)))

(defun baton-notify--format-entry (session marks)
  "Return a tabulated-list entry for SESSION given current MARKS alist."
  (let* ((id (baton--session-name session))
         (mark-char (if (assoc id marks) "D" " "))
         (face (baton-notify--session-face session))
         (name (propertize (baton--session-name session) 'face face))
         (status (propertize (symbol-name (baton--session-status session)) 'face face))
         (dir (propertize (abbreviate-file-name
                           (or (baton--session-directory session) ""))
                          'face face))
         (reason (propertize (or (baton--session-waiting-reason session) "")
                             'face face)))
    (list id
          (vector mark-char
                  (baton-notify--session-indicator session)
                  name
                  status
                  dir
                  reason))))

(defun baton-notify--list-entries ()
  "Return sorted tabulated-list entries for all sessions."
  (let* ((sessions (sort (baton-session-list)
                         (lambda (a b)
                           (< (baton--session-created-at a)
                              (baton--session-created-at b)))))
         (marks (or baton--list-marks nil)))
    (mapcar (lambda (s) (baton-notify--format-entry s marks)) sessions)))

(defun baton-list-refresh ()
  "Refresh the `*Baton*' status buffer contents."
  (setq tabulated-list-entries (baton-notify--list-entries))
  (tabulated-list-print t))

(defun baton-notify--refresh-list-buffer (&rest _)
  "Refresh the status buffer if it is currently live."
  (when-let* ((buf (get-buffer "*Baton*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (baton-list-refresh)))))

;;; Status Buffer Mode

(defvar baton-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "m")   #'baton-list-mark)
    (define-key map (kbd "u")   #'baton-list-unmark)
    (define-key map (kbd "U")   #'baton-list-unmark-all)
    (define-key map (kbd "d")   #'baton-list-flag-delete)
    (define-key map (kbd "x")   #'baton-list-execute)
    (define-key map (kbd "RET") #'baton-list-jump)
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    (define-key map (kbd "N")   #'baton-new)
    (define-key map (kbd "g")   #'baton-list-refresh)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `baton-list-mode'.")

(define-derived-mode baton-list-mode tabulated-list-mode "Baton"
  "Major mode for the Baton agent status buffer."
  (setq tabulated-list-format
        [("M" 1 nil)
         ("" 2 nil)
         ("Name" 16 t)
         ("Status" 10 t)
         ("Directory" 30 t)
         ("Reason" 20 t)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header)
  (setq-local baton--list-marks nil))

;;;###autoload
(defun baton-list ()
  "Open or refresh the `*Baton*' agent status buffer."
  (interactive)
  (let ((buf (get-buffer-create "*Baton*")))
    (with-current-buffer buf
      (unless (eq major-mode 'baton-list-mode)
        (baton-list-mode))
      (baton-list-refresh))
    (pop-to-buffer buf)))

(defun baton-list--current-session ()
  "Return the `baton--session' for the current tabulated-list row, or nil."
  (when-let* ((id (tabulated-list-get-id)))
    (baton-session-get id)))

(defun baton-list-flag-delete ()
  "Flag the session at point for deletion (\"kill\")."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (setq baton--list-marks
          (cons (cons id 'kill)
                (assoc-delete-all id baton--list-marks)))
    (baton-list-refresh)
    (forward-line 1)))

(defun baton-list-mark ()
  "Mark the session at point."
  (interactive)
  (baton-list-flag-delete))

(defun baton-list-unmark ()
  "Remove mark from the session at point."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (setq baton--list-marks (assoc-delete-all id baton--list-marks))
    (baton-list-refresh)
    (forward-line 1)))

(defun baton-list-unmark-all ()
  "Remove all marks."
  (interactive)
  (setq baton--list-marks nil)
  (baton-list-refresh))

(defun baton-list-execute ()
  "Execute flagged operations (kill sessions marked for deletion)."
  (interactive)
  (dolist (entry baton--list-marks)
    (let ((session (baton-session-get (car entry))))
      (when session
        (pcase (cdr entry)
          ('kill (baton-session-kill session))))))
  (setq baton--list-marks nil)
  (baton-list-refresh))

(defun baton-list-jump ()
  "Jump to the vterm buffer of the session at point."
  (interactive)
  (when-let* ((session (baton-list--current-session))
              (buf (baton--session-buffer session)))
    (if (buffer-live-p buf)
        (pop-to-buffer buf)
      (message "baton: session buffer no longer exists"))))

;;; baton-jump (completing-read navigation)

(defun baton--jump-annotation (name sessions)
  "Return an annotation string for session NAME from SESSIONS list."
  (when-let* ((session (cl-find name sessions
                                :key #'baton--session-name
                                :test #'equal)))
    (let ((status (baton--session-status session))
          (reason (baton--session-waiting-reason session)))
      (format "  [%s%s]"
              status
              (if reason (format ": %s" reason) "")))))

(defun baton-jump (&optional sessions)
  "Jump to an agent vterm buffer via completing-read.
SESSIONS defaults to all sessions."
  (interactive)
  (let* ((all (or sessions (baton-session-list)))
         (names (mapcar #'baton--session-name all))
         (completion-extra-properties
          (list :annotation-function
                (lambda (n) (baton--jump-annotation n all))))
         (chosen (completing-read "Jump to agent: " names nil t)))
    (when-let* ((session (cl-find chosen all
                                  :key #'baton--session-name
                                  :test #'equal))
                (buf (baton--session-buffer session)))
      (if (buffer-live-p buf)
          (pop-to-buffer buf)
        (message "baton: session buffer no longer exists")))))

(defun baton-jump-to-waiting ()
  "Jump to a waiting agent via completing-read (pre-filtered to waiting sessions)."
  (interactive)
  (let ((waiting (baton-session-list 'waiting)))
    (if waiting
        (baton-jump waiting)
      (message "baton: no sessions are waiting"))))

(provide 'baton-notify)
;;; baton-notify.el ends here
