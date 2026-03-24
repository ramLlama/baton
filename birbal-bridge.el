;;; birbal-bridge.el --- Monet tool overrides for birbal-aware diff handling  -*- lexical-binding: t -*-

;; Author: Ram Krishnaraj
;; Keywords: tools, ai

;;; Commentary:
;; Integrates birbal with monet by overriding the openDiff tool with a
;; birbal-aware handler.  When a Claude Code session requests a diff,
;; the corresponding birbal session is set to `waiting' (reason: "diff review").
;; When the user accepts or rejects the diff, the session is reset to `running'.
;;
;; This module is optional.  It only activates when `monet' is loaded.
;; Call `birbal-bridge-setup' after both monet and birbal are loaded,
;; or let `birbal-mode' call it automatically.
;;
;; No hooks are required in monet.el.

;;; Code:
(require 'cl-lib)
(require 'birbal-session)

;; Silence byte-compiler warnings for optional monet dependency.
(declare-function monet-make-tool "monet" (&rest plist))
(declare-function monet--tool-open-diff-handler "monet" (params session))
(declare-function monet--session-directory "monet" (session))
(declare-function monet-simple-diff-tool "monet"
                  (old-file new-file new-contents on-accept on-quit session))
(defvar monet-open-diff-tool-schema)

;;; Session Lookup

(defun birbal-bridge--find-session (directory)
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

(defun birbal-bridge--wrap-callback (session callback)
  "Return a function that calls CALLBACK then resets SESSION to `running'."
  (lambda (&rest args)
    (apply callback args)
    (when session
      (birbal-session-set-status session 'running))))

(defun birbal-bridge--open-diff-handler (params monet-session)
  "Birbal-aware openDiff handler.
Finds the birbal session for MONET-SESSION's directory, sets it to
`waiting' with reason \"diff review\", then delegates to monet's original
simple-diff handler with wrapped accept/quit callbacks.
PARAMS and MONET-SESSION are passed through to the underlying handler."
  (unless (featurep 'monet)
    (error "birbal-bridge requires monet"))
  ;; Find matching birbal session
  (let* ((dir (monet--session-directory monet-session))
         (birbal-session (birbal-bridge--find-session dir)))
    ;; Signal waiting
    (when birbal-session
      (birbal-session-set-status birbal-session 'waiting "diff review"))
    ;; Delegate to monet's original simple-diff handler
    ;; We advise the on-accept/on-quit inside monet--make-open-diff-handler
    ;; by wrapping at the birbal level through a temp override.
    (if birbal-session
        (birbal-bridge--call-with-wrapped-callbacks
         params monet-session birbal-session)
      ;; No birbal session — fall through to default handler
      (monet--tool-open-diff-handler params monet-session))))

(defun birbal-bridge--call-with-wrapped-callbacks (params monet-session birbal-session)
  "Call monet diff handler, resetting BIRBAL-SESSION to running after accept/quit.
PARAMS and MONET-SESSION are forwarded to the underlying handler."
  ;; We temporarily advise monet-simple-diff-tool so that the on-accept and
  ;; on-quit lambdas it receives each reset the birbal session.
  (let (orig-fn)
    (setq orig-fn
          (symbol-function 'monet-simple-diff-tool))
    (cl-letf (((symbol-function 'monet-simple-diff-tool)
               (lambda (old-file new-file new-contents on-accept on-quit session)
                 (funcall orig-fn
                          old-file new-file new-contents
                          (birbal-bridge--wrap-callback birbal-session on-accept)
                          (birbal-bridge--wrap-callback birbal-session on-quit)
                          session))))
      (monet--tool-open-diff-handler params monet-session))))

;;; Setup

;;;###autoload
(defun birbal-bridge-setup ()
  "Override monet's openDiff tool with a birbal-aware handler.
Safe to call even if monet is not loaded — does nothing in that case."
  (when (featurep 'monet)
    (monet-make-tool
     :name "openDiff"
     :description "Open a diff view (birbal-aware)"
     :schema monet-open-diff-tool-schema
     :handler #'birbal-bridge--open-diff-handler
     :set :birbal)))

(provide 'birbal-bridge)
;;; birbal-bridge.el ends here
