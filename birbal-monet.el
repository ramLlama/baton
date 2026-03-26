;;; birbal-monet.el --- Monet integration for birbal-aware diff handling  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Integrates birbal with monet by registering a birbal-aware openDiff handler
;; and injecting the monet MCP server env vars into new Claude Code sessions.
;;
;; When a Claude Code session requests a diff, the corresponding birbal session
;; is set to `waiting' (reason: "diff review").  When the user accepts or
;; rejects the diff, the session is reset to `running'.
;;
;; This module is optional.  It only activates when `monet' is loaded.
;; Call `birbal-monet-setup' after both monet and birbal are loaded,
;; or let `birbal-mode' call it automatically.

;;; Code:
(require 'cl-lib)
(require 'birbal-session)

;; Silence byte-compiler warnings for forward/optional references.
(defvar birbal-global-map)
(defvar birbal-list-mode-map)
(defvar birbal--current-session)
(declare-function birbal-add-env-function "birbal" (agent-type fn))
(declare-function birbal-list--current-session "birbal-notify" ())
(declare-function monet-session-directory "monet" (session))
(declare-function monet-make-open-diff-handler "monet" (diff-fn))
(declare-function monet-make-tool "monet" (&rest plist))
(declare-function monet-enable-tool-set "monet" (&rest sets))
(declare-function monet-ediff-tool "monet"
                  (old-file new-file new-contents on-accept on-quit &optional session))
(declare-function monet-start-server-function "monet" (key directory))
(defvar monet-open-diff-tool-schema nil
  "MCP inputSchema for the openDiff tool (provided by monet).")

;;; Session Lookup

(defun birbal-monet--find-session (directory)
  "Find the birbal session best matching DIRECTORY.
Prefers agent-type `claude-code' when multiple sessions match.
Returns nil if no match is found."
  (let ((matches (cl-remove-if-not
                  (lambda (s)
                    (and (birbal--session-directory s)
                         (equal (birbal--session-directory s) directory)))
                  (birbal-session-list))))
    (or (cl-find 'claude-code matches :key #'birbal--session-agent-type)
        (car matches))))

;;; Diff Handler

(defun birbal-monet--open-diff-handler (params monet-session)
  "Birbal-aware openDiff handler.
Finds the birbal session for MONET-SESSION's directory, sets it to
`waiting' with reason \"diff review\", and stores a thunk under
`:pending-diff' in the session's metadata.  The diff is not opened
immediately; call `birbal-review-diff' when ready to review it.
The birbal session is reset to `running' when the user accepts or
rejects the diff.
PARAMS and MONET-SESSION are the standard MCP handler arguments.
Returns a deferred response indicator so Claude Code waits for the
user to accept or reject the diff before continuing."
  (let* ((dir (monet-session-directory monet-session))
         (birbal-session (birbal-monet--find-session dir))
         (reset (lambda (&rest _)
                  (when birbal-session
                    (setf (birbal--session-metadata birbal-session)
                          (plist-put (birbal--session-metadata birbal-session)
                                     :pending-diff nil))
                    (birbal-session-set-status birbal-session 'running))))
         (diff-fn
          (lambda (old new contents on-accept on-quit sess)
            (monet-ediff-tool
             old new contents
             (lambda (&rest args) (apply on-accept args) (funcall reset))
             (lambda () (funcall on-quit) (funcall reset))
             sess)))
         (handler (monet-make-open-diff-handler diff-fn)))
    (if birbal-session
        (progn
          (setf (birbal--session-metadata birbal-session)
                (plist-put (birbal--session-metadata birbal-session)
                           :pending-diff (lambda () (funcall handler params monet-session))))
          (birbal-session-set-status birbal-session 'waiting "diff review")
          `((deferred . t) (unique-key . ,(alist-get 'tab_name params))))
      ;; No matching birbal session — open the diff immediately.
      (funcall handler params monet-session))))

;;; User Commands

(defun birbal-review-diff (session-name)
  "Open the pending diff for the session named SESSION-NAME."
  (interactive
   (list (completing-read "Review diff for session: "
                          (mapcar #'birbal--session-name
                                  (cl-remove-if-not
                                   (lambda (s)
                                     (plist-get (birbal--session-metadata s) :pending-diff))
                                   (birbal-session-list)))
                          nil t)))
  (let ((session (birbal-session-get session-name)))
    (if-let* ((thunk (plist-get (birbal--session-metadata session) :pending-diff)))
        (progn
          (setf (birbal--session-metadata session)
                (plist-put (birbal--session-metadata session) :pending-diff nil))
          (funcall thunk))
      (message "birbal: no pending diff for session %s" session-name))))

(defun birbal-list-review-diff ()
  "Open the pending diff for the session at point in *Birbal*."
  (interactive)
  (when-let* ((session (birbal-list--current-session)))
    (birbal-review-diff (birbal--session-name session))))

(defun birbal-clear-pending-diff (session-name)
  "Clear any pending diff for the session named SESSION-NAME.
Use this to recover when diff state gets out of sync.  The session
status is reset to `idle' and the watcher will re-derive it on the
next tick."
  (interactive
   (list (completing-read "Clear pending diff for session: "
                          (mapcar #'birbal--session-name
                                  (cl-remove-if-not
                                   (lambda (s)
                                     (plist-get (birbal--session-metadata s) :pending-diff))
                                   (birbal-session-list)))
                          nil t)))
  (let ((session (birbal-session-get session-name)))
    (setf (birbal--session-metadata session)
          (plist-put (birbal--session-metadata session) :pending-diff nil))
    (birbal-session-set-status session 'idle)
    (message "birbal: cleared pending diff for %s" session-name)))

(defun birbal-list-clear-pending-diff ()
  "Clear the pending diff for the session at point in *Birbal*."
  (interactive)
  (when-let* ((session (birbal-list--current-session)))
    (birbal-clear-pending-diff (birbal--session-name session))))

;;; Session Review Bar

(defface birbal-monet-review-bar
  '((t :inherit warning :weight bold))
  "Face for the diff review pending bar in birbal session buffers."
  :group 'birbal)

(defvar birbal--session-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'birbal-review-diff-current)
    map)
  "Keymap active in session buffers pending diff review.")

(define-minor-mode birbal--session-review-mode
  "Minor mode active in session buffers pending diff review.
Binds `r' to `birbal-review-diff-current' so the user can open the
pending diff without leaving the buffer."
  :keymap birbal--session-review-mode-map)

(defun birbal-review-diff-current ()
  "Open the pending diff for this buffer's birbal session."
  (interactive)
  (when-let* ((session birbal--current-session))
    (birbal-review-diff (birbal--session-name session))))

(defun birbal-monet--update-review-bar (session _old-status _new-status)
  "Update the diff review callout bar in SESSION's buffer.
Shows a prominent mode-line bar and activates `birbal--session-review-mode'
when SESSION is waiting for diff review.  Clears both otherwise."
  (when-let* ((buf (birbal--session-buffer session)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if (and (eq (birbal--session-status session) 'waiting)
                 (equal (birbal--session-waiting-reason session) "diff review"))
            (progn
              (setq-local mode-line-format
                          (list (propertize
                                 "  ⏺ DIFF REVIEW PENDING  —  press [r] to open  "
                                 'face 'birbal-monet-review-bar)))
              (birbal--session-review-mode 1))
          (kill-local-variable 'mode-line-format)
          (birbal--session-review-mode -1))))))

;;; Setup

;;;###autoload
(defun birbal-monet-setup ()
  "Register birbal's openDiff handler in monet and wire env injection.
Adds an openDiff tool to the :birbal set and enables it, which
supersedes the default :simple-diff openDiff.  Also registers
`monet-start-server-function' as an env-function for claude-code
sessions so each new session gets its own MCP server.
Safe to call even if monet is not loaded — does nothing in that case."
  (when (featurep 'monet)
    (monet-make-tool
     :name "openDiff"
     :description "Open a diff view (birbal-aware)"
     :schema monet-open-diff-tool-schema
     :handler #'birbal-monet--open-diff-handler
     :set :birbal)
    (monet-enable-tool-set :birbal)
    (birbal-add-env-function 'claude-code #'monet-start-server-function)
    (define-key birbal-global-map (kbd "r") #'birbal-review-diff)
    (define-key birbal-list-mode-map (kbd "r") #'birbal-list-review-diff)
    (add-hook 'birbal-session-status-changed-hook #'birbal-monet--update-review-bar)))

(provide 'birbal-monet)
;;; birbal-monet.el ends here
