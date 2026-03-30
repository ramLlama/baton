;;; baton-alert.el --- Desktop alert backend registry for baton  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Provides a registry of desktop alert backends for baton notifications.
;; Each backend declares when it is available (:predicate) and how to fire
;; a notification (:handler TITLE BODY).  `baton-alert--dispatch' tries
;; backends in registration order, stopping at the first whose predicate
;; returns non-nil.
;;
;; Built-in backends (highest to lowest priority):
;;   alerter       -- macOS `alerter' CLI, not active over SSH
;;   osc777        -- OSC 777 escape, active in SSH sessions
;;   notifications -- Emacs built-in D-Bus/Windows notifications, non-macOS
;;   echo          -- echo-area fallback, always available
;;
;; `baton-mode' calls `baton-alert--setup' automatically, replacing
;; `baton-notify-function' with `baton-alert--dispatch'.

;;; Code:
(require 'cl-lib)
(require 'baton-session)
(require 'baton-notify)

(declare-function notifications-notify "notifications" (&rest params))

;;; Variables

(defvar baton-alert--backends nil
  "Ordered list of registered alert backends.
Each element is (NAME :predicate PRED :handler HANDLER).
NAME is a symbol.  PRED is a zero-argument function returning non-nil
when the backend is usable.  HANDLER is a function accepting TITLE and
BODY strings.  Backends are tried front-to-back; the first available one fires.")

(defvar baton-alert--icon-path
  (let* ((this-file (or load-file-name buffer-file-name))
         (this-dir  (and this-file (file-name-directory this-file)))
         (icon      (and this-dir (expand-file-name "logo.png" this-dir))))
    (and icon (file-exists-p icon) icon))
  "Absolute path to the baton logo PNG used in desktop notifications.
Nil when the file cannot be located at load time.")

;;; Internal helpers

(defun baton-alert--do-register (name plist append-p)
  "Register backend NAME with PLIST, appending if APPEND-P, prepending otherwise.
Replaces any existing entry with the same NAME in place."
  (let ((existing (assq name baton-alert--backends)))
    (if existing
        (setcdr existing plist)
      (if append-p
          (setq baton-alert--backends
                (append baton-alert--backends (list (cons name plist))))
        (push (cons name plist) baton-alert--backends)))))

(defun baton-alert--register-builtin (name &rest plist)
  "Register built-in backend NAME with PLIST.
Built-in backends are appended, giving user-registered backends
higher priority."
  (baton-alert--do-register name plist t))

;;; Private API (architected for future promotion to public)

(defun baton-alert--register-backend (name &rest plist)
  "Register a user alert backend named NAME.
PLIST must contain :predicate and :handler.
:predicate is a zero-argument function returning non-nil when the backend
is available.
:handler is a function called with TITLE and BODY strings.
User backends are prepended, giving them priority over built-in backends.
If NAME is already registered, the existing entry is updated in place."
  (baton-alert--do-register name plist nil))

(defun baton-alert--deregister-backend (name)
  "Remove the backend named NAME from the registry.
No-op if NAME is not registered."
  (setq baton-alert--backends
        (cl-remove-if (lambda (e) (eq (car e) name))
                      baton-alert--backends)))

(defun baton-alert--backend-names ()
  "Return a list of registered backend name symbols in dispatch order."
  (mapcar #'car baton-alert--backends))

(defun baton-alert--format (session)
  "Return a plist (:title TITLE :body BODY :icon ICON) for SESSION."
  (list :title (format "baton: %s" (baton--session-name session))
        :body  (format "%s needs attention (%s)"
                       (baton--session-name session)
                       (or (baton--session-waiting-reason session) "unread output"))
        :icon  baton-alert--icon-path))

(defun baton-alert--sanitize-terminal (s)
  "Remove control characters from S for safe use in terminal escape sequences."
  (replace-regexp-in-string "[\x00-\x1f\x7f]" "" s))

(defun baton-alert--dispatch (session)
  "Notify the user about SESSION using the first available backend.
Iterates `baton-alert--backends' in order and calls the first backend
whose :predicate returns non-nil.  Does nothing when no backend matches.
Handler errors are caught and reported once to avoid breaking the watcher."
  (when-let* ((entry (cl-find-if
                      (lambda (e) (funcall (plist-get (cdr e) :predicate)))
                      baton-alert--backends))
              (handler (plist-get (cdr entry) :handler))
              (info (baton-alert--format session)))
    (condition-case-unless-debug err
        (funcall handler (plist-get info :title) (plist-get info :body))
      (error (message "baton-alert: backend %s failed: %s"
                      (car entry) (error-message-string err))))))

(defun baton-alert--setup ()
  "Replace `baton-notify-function' with `baton-alert--dispatch'.
Called automatically by `baton-mode'.  Safe to call multiple times."
  (setq baton-notify-function #'baton-alert--dispatch))

;;; Built-in backends
;; Registered in priority order (highest first).  Each call appends, so
;; the final list is: alerter → osc777 → notifications → echo.

;; 1. macOS alerter: requires `alerter' CLI, disabled over SSH
(baton-alert--register-builtin
 'alerter
 :predicate (lambda ()
              (and (eq system-type 'darwin)
                   (not (or (getenv "SSH_CLIENT") (getenv "SSH_TTY")))
                   (executable-find "alerter")))
 :handler (lambda (title body)
            (let ((args (list "--title" title "--message" body
                              "--sender" "org.gnu.Emacs")))
              (when baton-alert--icon-path
                (setq args (append args (list "--app-icon" baton-alert--icon-path))))
              (apply #'start-process "baton-alerter" nil "alerter" args))))

;; 2. OSC 777: terminal escape for SSH sessions
(baton-alert--register-builtin
 'osc777
 :predicate (lambda ()
              (or (getenv "SSH_CLIENT") (getenv "SSH_TTY")))
 :handler (lambda (title body)
            (send-string-to-terminal
             (format "\033]777;notify;%s;%s\a"
                     (baton-alert--sanitize-terminal title)
                     (baton-alert--sanitize-terminal body)))))

;; 3. Emacs built-in desktop notifications (Linux/Windows via D-Bus or toast)
(baton-alert--register-builtin
 'notifications
 :predicate (lambda ()
              (and (not (eq system-type 'darwin))
                   (not (or (getenv "SSH_CLIENT") (getenv "SSH_TTY")))
                   (require 'notifications nil t)
                   (fboundp 'notifications-notify)))
 :handler (lambda (title body)
            (let ((args (list :title title :body body)))
              (when baton-alert--icon-path
                (setq args (append args (list :app-icon baton-alert--icon-path))))
              (apply #'notifications-notify args))))

;; 4. Echo area: always available fallback
(baton-alert--register-builtin
 'echo
 :predicate (lambda () t)
 :handler (lambda (title body)
            (message "%s: %s" title body)))

(provide 'baton-alert)
;;; baton-alert.el ends here
