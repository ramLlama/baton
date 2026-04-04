;;; baton-monet.el --- Monet integration for baton-aware diff handling  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Integrates baton with monet by registering a baton-aware openDiff handler
;; and injecting the monet MCP server env vars into new Claude Code sessions.
;;
;; When a Claude Code session requests a diff, the corresponding baton session
;; is set to `waiting' (reason: "diff review").  When the user accepts or
;; rejects the diff, the session is reset to `running'.
;;
;; This module is optional.  It only activates when `monet' is loaded.
;; Call `baton-monet-setup' after both monet and baton are loaded,
;; or let `baton-mode' call it automatically.

;;; Code:
(require 'cl-lib)
(require 'baton-session)

;; Silence byte-compiler warnings for forward/optional references.
(defvar baton-list-mode-map)
(defvar baton--current-session)
(declare-function baton-add-env-function "baton" (agent fn))
(declare-function baton-list--current-session "baton-notify" ())
(declare-function monet-session-directory "monet" (session))
(declare-function monet-make-open-diff-handler "monet" (diff-fn))
(declare-function monet-make-tool "monet" (&rest plist))
(declare-function monet-enable-tool-set "monet" (&rest sets))
(declare-function monet-ediff-tool "monet"
                  (old-file new-file new-contents on-accept on-quit &optional session))
(declare-function monet-start-server-function "monet" (key directory))
(declare-function monet-add-claude-hook-handler "monet" (handler))
(declare-function monet-remove-claude-hook-handler "monet" (handler))
(defvar monet-open-diff-tool-schema nil
  "MCP inputSchema for the openDiff tool (provided by monet).")

;;; Session Lookup

(defun baton-monet--find-session (directory)
  "Find the baton session best matching DIRECTORY.
Both DIRECTORY and stored session directories are normalized via
`expand-file-name' and `file-name-as-directory' before comparison,
so trailing slashes and relative components do not cause mismatches.
Prefers agent `claude-code' when multiple sessions match.
Returns nil if no match is found."
  (let* ((dir (file-name-as-directory (expand-file-name directory)))
         (matches (cl-remove-if-not
                   (lambda (s)
                     (and (baton--session-directory s)
                          (equal (file-name-as-directory
                                  (expand-file-name (baton--session-directory s)))
                                 dir)))
                   (baton-session-list))))
    (or (cl-find 'claude-code matches :key #'baton--session-agent)
        (car matches))))

;;; Hook Integration State

(defvar baton-monet--saved-claude-status-fn nil
  "Saved :status-function for claude-code, restored by `baton-monet--teardown'.")

(defvar baton-monet--saved-claude-trigger nil
  "Saved :status-function-trigger for claude-code.
Restored by `baton-monet--teardown'.")

;;; Hook Status Function

(defun baton-monet--hook-status-fn (session)
  "Return the hook-derived status for SESSION from its :state metadata.
Returns (STATUS . REASON) when :state is set, or nil."
  (when-let* ((state (plist-get (baton--session-metadata session) :state)))
    (cons (plist-get state :status) (plist-get state :reason))))

;;; Hook State Writer

(defun baton-monet--set-state (session status &optional reason)
  "Write STATUS and REASON into SESSION's :state metadata with a timestamp.
Also calls `baton-session-set-status' so the change is applied immediately."
  (setf (baton--session-metadata session)
        (plist-put (baton--session-metadata session)
                   :state `(:status ,status :reason ,reason :at ,(float-time))))
  (baton-session-set-status session status reason))

;;; Session Env Function

(defun baton-monet--session-env-function (session-name _directory)
  "Return env vars injecting SESSION-NAME into the Claude Code process environment.
Injects MONET_CTX_baton_session so hook handlers can look up the session."
  (list (format "MONET_CTX_baton_session=%s" session-name)))

;;; Hook Handler

(defun baton-monet--claude-hook-handler (event-name data ctx)
  "Dispatch a Claude Code lifecycle event to the matching baton session.
Looks up the session from baton_session in CTX.  Skips if the session
has a :pending-diff (diff review is in progress).
EVENT-NAME is the hook_event_name string, DATA is the payload alist,
CTX is the monet_context alist."
  (when-let* ((session-name (cdr (assq 'baton_session ctx)))
              (session (baton-session-get session-name)))
    (unless (plist-get (baton--session-metadata session) :pending-diff)
      (pcase event-name
        ("UserPromptSubmit" (baton-monet--set-state session 'running))
        ("Stop"             (baton-monet--set-state session 'idle))
        ("Notification"
         (baton-monet--set-state session 'waiting
                                 (or (cdr (assq 'message data)) "input prompt")))))))

;;; Teardown

(defun baton-monet--teardown ()
  "Deregister baton's hook handler and restore claude-code's original status fn.
Safe to call even if monet is not loaded."
  (when (featurep 'monet)
    (monet-remove-claude-hook-handler #'baton-monet--claude-hook-handler))
  (remove-hook 'baton-session-status-changed-hook #'baton-monet--update-review-bar)
  (when (boundp 'baton-list-mode-map)
    (define-key baton-list-mode-map (kbd "r") nil))
  (when (boundp 'baton-agents)
    (when-let* ((def (gethash 'claude-code baton-agents)))
      (puthash 'claude-code
               (plist-put (plist-put def
                                     :status-function-trigger baton-monet--saved-claude-trigger)
                           :status-function baton-monet--saved-claude-status-fn)
               baton-agents))))

;;; Diff Handler

(defun baton-monet--open-diff-handler (params monet-session)
  "Baton-aware openDiff handler.
Finds the baton session for MONET-SESSION's directory, sets it to
`waiting' with reason \"diff review\", and stores a thunk under
`:pending-diff' in the session's metadata.  The diff is not opened
immediately; call `baton-review-diff' when ready to review it.
The baton session is reset to `running' when the user accepts or
rejects the diff.
PARAMS and MONET-SESSION are the standard MCP handler arguments.
Returns a deferred response indicator so Claude Code waits for the
user to accept or reject the diff before continuing."
  (let* ((dir (monet-session-directory monet-session))
         (baton-session (baton-monet--find-session dir))
         (reset (lambda (&rest _)
                  (when baton-session
                    (setf (baton--session-metadata baton-session)
                          (plist-put (baton--session-metadata baton-session)
                                     :pending-diff nil))
                    (baton-monet--set-state baton-session 'running))))
         (diff-fn
          (lambda (old new contents on-accept on-quit sess)
            (monet-ediff-tool
             old new contents
             (lambda (&rest args) (apply on-accept args) (funcall reset))
             (lambda () (funcall on-quit) (funcall reset))
             sess)))
         (handler (monet-make-open-diff-handler diff-fn)))
    (if baton-session
        (progn
          (setf (baton--session-metadata baton-session)
                (plist-put (baton--session-metadata baton-session)
                           :pending-diff (lambda () (funcall handler params monet-session))))
          (baton-monet--set-state baton-session 'waiting "diff review")
          `((deferred . t) (unique-key . ,(alist-get 'tab_name params))))
      ;; No matching baton session — open the diff immediately.
      (funcall handler params monet-session))))

;;; User Commands

(defun baton-review-diff (session-name)
  "Open the pending diff for the session named SESSION-NAME."
  (interactive
   (list (completing-read "Review diff for session: "
                          (mapcar #'baton--session-name
                                  (cl-remove-if-not
                                   (lambda (s)
                                     (plist-get (baton--session-metadata s) :pending-diff))
                                   (baton-session-list)))
                          nil t)))
  (let ((session (baton-session-get session-name)))
    (if-let* ((thunk (plist-get (baton--session-metadata session) :pending-diff)))
        (progn
          (setf (baton--session-metadata session)
                (plist-put (baton--session-metadata session) :pending-diff nil))
          (funcall thunk))
      (message "baton: no pending diff for session %s" session-name))))

(defun baton-list-review-diff ()
  "Open the pending diff for the session at point in *Baton*."
  (interactive)
  (when-let* ((session (baton-list--current-session)))
    (baton-review-diff (baton--session-name session))))

(defun baton-clear-pending-diff (session-name)
  "Clear any pending diff for the session named SESSION-NAME.
Use this to recover when diff state gets out of sync.  The session
status is reset to `idle' and the watcher will re-derive it on the
next tick."
  (interactive
   (list (completing-read "Clear pending diff for session: "
                          (mapcar #'baton--session-name
                                  (cl-remove-if-not
                                   (lambda (s)
                                     (plist-get (baton--session-metadata s) :pending-diff))
                                   (baton-session-list)))
                          nil t)))
  (let ((session (baton-session-get session-name)))
    (setf (baton--session-metadata session)
          (plist-put (baton--session-metadata session) :pending-diff nil))
    (baton-session-set-status session 'idle)
    (message "baton: cleared pending diff for %s" session-name)))

(defun baton-list-clear-pending-diff ()
  "Clear the pending diff for the session at point in *Baton*."
  (interactive)
  (when-let* ((session (baton-list--current-session)))
    (baton-clear-pending-diff (baton--session-name session))))

;;; Session Review Bar

(defface baton-monet-review-bar
  '((t :inherit warning :weight bold))
  "Face for the diff review pending bar in baton session buffers."
  :group 'baton)

(defvar baton--session-review-mode-map
  (let ((map (make-sparse-keymap)))
    (define-key map (kbd "r") #'baton-review-diff-current)
    map)
  "Keymap active in session buffers pending diff review.")

(define-minor-mode baton--session-review-mode
  "Minor mode active in session buffers pending diff review.
Binds `r' to `baton-review-diff-current' so the user can open the
pending diff without leaving the buffer."
  :keymap baton--session-review-mode-map)

(defun baton-review-diff-current ()
  "Open the pending diff for this buffer's baton session."
  (interactive)
  (when-let* ((session baton--current-session))
    (baton-review-diff (baton--session-name session))))

(defun baton-monet--update-review-bar (session _old-status _new-status)
  "Update the diff review callout bar in SESSION's buffer.
Shows a prominent mode-line bar and activates `baton--session-review-mode'
when SESSION is waiting for diff review.  Clears both otherwise."
  (when-let* ((buf (baton--session-buffer session)))
    (when (buffer-live-p buf)
      (with-current-buffer buf
        (if (and (eq (baton--session-status session) 'waiting)
                 (equal (baton--session-waiting-reason session) "diff review"))
            (progn
              (setq-local mode-line-format
                          (list (propertize
                                 "  ⏺ DIFF REVIEW PENDING  —  press [r] to open  "
                                 'face 'baton-monet-review-bar)))
              (baton--session-review-mode 1))
          (kill-local-variable 'mode-line-format)
          (baton--session-review-mode -1))))))

;;; Setup

;;;###autoload
(defun baton-monet-setup ()
  "Register baton's openDiff handler in monet and wire env injection.
Adds an openDiff tool to the :baton set and enables it, which
supersedes the default :simple-diff openDiff.  Also registers
`monet-start-server-function' as an env-function for claude-code
sessions so each new session gets its own MCP server.
Safe to call even if monet is not loaded — does nothing in that case."
  (when (featurep 'monet)
    (monet-make-tool
     :name "openDiff"
     :description "Open a diff view (baton-aware)"
     :schema monet-open-diff-tool-schema
     :handler #'baton-monet--open-diff-handler
     :set :baton)
    (monet-enable-tool-set :baton)
    (baton-add-env-function 'claude-code #'monet-start-server-function)
    (baton-add-env-function 'claude-code #'baton-monet--session-env-function)
    (monet-add-claude-hook-handler #'baton-monet--claude-hook-handler)
    ;; Switch claude-code to event-driven status detection.
    (when (boundp 'baton-agents)
      (when-let* ((def (gethash 'claude-code baton-agents)))
        (setq baton-monet--saved-claude-status-fn  (plist-get def :status-function))
        (setq baton-monet--saved-claude-trigger     (plist-get def :status-function-trigger))
        (puthash 'claude-code
                 (plist-put (plist-put def
                                       :status-function-trigger :on-event)
                             :status-function #'baton-monet--hook-status-fn)
                 baton-agents)))
    (define-key baton-list-mode-map (kbd "r") #'baton-list-review-diff)
    (add-hook 'baton-session-status-changed-hook #'baton-monet--update-review-bar)
    (message "baton-monet: hook integration active")))

(provide 'baton-monet)
;;; baton-monet.el ends here
