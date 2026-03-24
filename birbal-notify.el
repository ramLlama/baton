;;; birbal-notify.el --- Modeline indicator, status buffer, alerts  -*- lexical-binding: t -*-

;; Author: Ram Krishnaraj
;; Keywords: tools, ai

;;; Commentary:
;; Provides the user-facing notification surface for birbal:
;;   - A modeline segment showing running/waiting counts
;;   - A `*Birbal*' status buffer (ibuffer-style tabulated list)
;;   - `birbal-jump' and `birbal-jump-to-waiting' for completing-read navigation
;;   - A `birbal-notify-function' hook for alerting the user

;;; Code:
(require 'cl-lib)
(require 'birbal-session)

(declare-function birbal-new "birbal" (agent-type-name directory))

;;; Faces

(defface birbal-face-waiting
  '((t :inherit warning))
  "Face for sessions in `waiting' status."
  :group 'birbal)

(defface birbal-face-done
  '((t :inherit shadow))
  "Face for sessions in `done' status."
  :group 'birbal)

(defface birbal-face-running
  '((t :inherit success))
  "Face for sessions in `running' status."
  :group 'birbal)

;;; Notification Function

(defvar birbal-notify-function #'birbal-notify--default
  "Function called when a session transitions to `waiting' status.
Called with one argument: the `birbal--session'.")

(defun birbal-notify--default (session)
  "Default notification: display a message in the echo area for SESSION."
  (message "birbal: %s needs attention (%s)"
           (birbal--session-name session)
           (or (birbal--session-waiting-reason session) "waiting")))

;;; Modeline

(defun birbal-notify--modeline-string ()
  "Return a propertized modeline string showing agent counts.
Format: \" B[<running>/<waiting>]\" omitting \"/<waiting>\" when zero."
  (let* ((sessions (birbal-session-list))
         (running (length (cl-remove-if-not
                           (lambda (s) (memq (birbal--session-status s)
                                             '(running idle)))
                           sessions)))
         (waiting (length (cl-remove-if-not
                           (lambda (s) (eq (birbal--session-status s) 'waiting))
                           sessions))))
    (if (zerop (+ running waiting))
        ""
      (let* ((counts (if (zerop waiting)
                         (number-to-string running)
                       (format "%d/%d" running waiting)))
             (str (format " B[%s]" counts))
             (face (if (zerop waiting) 'mode-line 'birbal-face-waiting))
             (map (make-sparse-keymap)))
        (define-key map [mode-line mouse-1] #'birbal-list)
        (propertize str
                    'face face
                    'mouse-face 'mode-line-highlight
                    'help-echo "birbal: click to open status buffer"
                    'local-map map)))))

(defvar birbal--modeline-segment
  '(:eval (birbal-notify--modeline-string))
  "Modeline segment for birbal.")

;;;###autoload
(define-minor-mode birbal-modeline-mode
  "Show birbal agent counts in the modeline."
  :global t
  :group 'birbal
  (if birbal-modeline-mode
      (progn
        (add-to-list 'global-mode-string birbal--modeline-segment t)
        (force-mode-line-update t))
    (setq global-mode-string
          (delete birbal--modeline-segment global-mode-string))
    (force-mode-line-update t)))

(defun birbal-notify--update-modeline (&rest _)
  "Refresh the modeline."
  (force-mode-line-update t))

(defun birbal-notify--on-status-changed (session old-status new-status)
  "Handle SESSION status change from OLD-STATUS to NEW-STATUS."
  (force-mode-line-update t)
  (when (and (eq new-status 'waiting)
             (not (eq old-status 'waiting)))
    (funcall birbal-notify-function session))
  (birbal-notify--refresh-list-buffer))

(defun birbal-notify--on-session-event (&rest _)
  "Handle session creation or destruction."
  (force-mode-line-update t)
  (birbal-notify--refresh-list-buffer))

;;; Status Buffer (`*Birbal*')

(defvar-local birbal--list-marks nil
  "Alist of (SESSION-ID . OPERATION) for pending operations in the status buffer.")

(defun birbal-notify--session-indicator (session)
  "Return a status indicator string for SESSION."
  (pcase (birbal--session-status session)
    ('waiting (propertize "●" 'face 'birbal-face-waiting))
    ('running (propertize "▷" 'face 'birbal-face-running))
    ('done    (propertize "✓" 'face 'birbal-face-done))
    ('error   (propertize "✗" 'face 'error))
    (_        " ")))

(defun birbal-notify--session-face (session)
  "Return the display face for SESSION based on its status."
  (pcase (birbal--session-status session)
    ('waiting 'birbal-face-waiting)
    ('done    'birbal-face-done)
    (_        'default)))

(defun birbal-notify--format-entry (session marks)
  "Return a tabulated-list entry for SESSION given current MARKS alist."
  (let* ((id (birbal--session-id session))
         (mark-char (if (assoc id marks) "D" " "))
         (face (birbal-notify--session-face session))
         (name (propertize (birbal--session-name session) 'face face))
         (status (propertize (symbol-name (birbal--session-status session)) 'face face))
         (dir (propertize (abbreviate-file-name
                           (or (birbal--session-directory session) ""))
                          'face face))
         (reason (propertize (or (birbal--session-waiting-reason session) "")
                             'face face)))
    (list id
          (vector mark-char
                  (birbal-notify--session-indicator session)
                  name
                  status
                  dir
                  reason))))

(defun birbal-notify--list-entries ()
  "Return sorted tabulated-list entries for all sessions."
  (let* ((sessions (sort (birbal-session-list)
                         (lambda (a b)
                           (< (birbal--session-created-at a)
                              (birbal--session-created-at b)))))
         (marks (or birbal--list-marks nil)))
    (mapcar (lambda (s) (birbal-notify--format-entry s marks)) sessions)))

(defun birbal-list-refresh ()
  "Refresh the `*Birbal*' status buffer contents."
  (setq tabulated-list-entries (birbal-notify--list-entries))
  (tabulated-list-print t))

(defun birbal-notify--refresh-list-buffer (&rest _)
  "Refresh the status buffer if it is currently live."
  (when-let* ((buf (get-buffer "*Birbal*")))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (birbal-list-refresh)))))

;;; Status Buffer Mode

(defvar birbal-list-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "m")   #'birbal-list-mark)
    (define-key map (kbd "u")   #'birbal-list-unmark)
    (define-key map (kbd "U")   #'birbal-list-unmark-all)
    (define-key map (kbd "d")   #'birbal-list-flag-delete)
    (define-key map (kbd "x")   #'birbal-list-execute)
    (define-key map (kbd "RET") #'birbal-list-jump)
    (define-key map (kbd "n")   #'next-line)
    (define-key map (kbd "p")   #'previous-line)
    (define-key map (kbd "N")   #'birbal-new)
    (define-key map (kbd "g")   #'birbal-list-refresh)
    (define-key map (kbd "q")   #'quit-window)
    map)
  "Keymap for `birbal-list-mode'.")

(define-derived-mode birbal-list-mode tabulated-list-mode "Birbal"
  "Major mode for the Birbal agent status buffer."
  (setq tabulated-list-format
        [("M" 1 nil)
         ("" 2 nil)
         ("Name" 16 t)
         ("Status" 10 t)
         ("Directory" 30 t)
         ("Reason" 20 t)])
  (setq tabulated-list-padding 1)
  (tabulated-list-init-header)
  (setq-local birbal--list-marks nil))

;;;###autoload
(defun birbal-list ()
  "Open or refresh the `*Birbal*' agent status buffer."
  (interactive)
  (let ((buf (get-buffer-create "*Birbal*")))
    (with-current-buffer buf
      (unless (eq major-mode 'birbal-list-mode)
        (birbal-list-mode))
      (birbal-list-refresh))
    (pop-to-buffer buf)))

(defun birbal-list--current-session ()
  "Return the `birbal--session' for the current tabulated-list row, or nil."
  (when-let* ((id (tabulated-list-get-id)))
    (birbal-session-get id)))

(defun birbal-list-flag-delete ()
  "Flag the session at point for deletion (\"kill\")."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (setq birbal--list-marks
          (cons (cons id 'kill)
                (assoc-delete-all id birbal--list-marks)))
    (birbal-list-refresh)
    (forward-line 1)))

(defun birbal-list-mark ()
  "Mark the session at point."
  (interactive)
  (birbal-list-flag-delete))

(defun birbal-list-unmark ()
  "Remove mark from the session at point."
  (interactive)
  (when-let* ((id (tabulated-list-get-id)))
    (setq birbal--list-marks (assoc-delete-all id birbal--list-marks))
    (birbal-list-refresh)
    (forward-line 1)))

(defun birbal-list-unmark-all ()
  "Remove all marks."
  (interactive)
  (setq birbal--list-marks nil)
  (birbal-list-refresh))

(defun birbal-list-execute ()
  "Execute flagged operations (kill sessions marked for deletion)."
  (interactive)
  (dolist (entry birbal--list-marks)
    (let ((session (birbal-session-get (car entry))))
      (when session
        (pcase (cdr entry)
          ('kill (birbal-session-kill session))))))
  (setq birbal--list-marks nil)
  (birbal-list-refresh))

(defun birbal-list-jump ()
  "Jump to the vterm buffer of the session at point."
  (interactive)
  (when-let* ((session (birbal-list--current-session))
              (buf (birbal--session-buffer session)))
    (if (buffer-live-p buf)
        (pop-to-buffer buf)
      (message "birbal: session buffer no longer exists"))))

;;; birbal-jump (completing-read navigation)

(defun birbal--jump-annotation (name sessions)
  "Return an annotation string for session NAME from SESSIONS list."
  (when-let* ((session (cl-find name sessions
                                :key #'birbal--session-name
                                :test #'equal)))
    (let ((status (birbal--session-status session))
          (reason (birbal--session-waiting-reason session)))
      (format "  [%s%s]"
              status
              (if reason (format ": %s" reason) "")))))

(defun birbal-jump (&optional sessions)
  "Jump to an agent vterm buffer via completing-read.
SESSIONS defaults to all sessions."
  (interactive)
  (let* ((all (or sessions (birbal-session-list)))
         (names (mapcar #'birbal--session-name all))
         (completion-extra-properties
          (list :annotation-function
                (lambda (n) (birbal--jump-annotation n all))))
         (chosen (completing-read "Jump to agent: " names nil t)))
    (when-let* ((session (cl-find chosen all
                                  :key #'birbal--session-name
                                  :test #'equal))
                (buf (birbal--session-buffer session)))
      (if (buffer-live-p buf)
          (pop-to-buffer buf)
        (message "birbal: session buffer no longer exists")))))

(defun birbal-jump-to-waiting ()
  "Jump to a waiting agent via completing-read (pre-filtered to waiting sessions)."
  (interactive)
  (let ((waiting (birbal-session-list 'waiting)))
    (if waiting
        (birbal-jump waiting)
      (message "birbal: no sessions are waiting"))))

(provide 'birbal-notify)
;;; birbal-notify.el ends here
