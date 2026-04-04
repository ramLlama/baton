;;; baton-monet-tests.el --- ERT tests for baton-monet  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; ERT tests for the monet diff review workflow and watcher integration.

;;; Code:
(require 'ert)
(require 'baton-test-helpers)
(require 'baton-process)
(require 'baton)
(require 'baton-monet)

;;; ─── baton-monet tests ──────────────────────────────────────────────────────

(ert-deftest baton-test-monet-find-session-by-directory ()
  "baton-monet--find-session matches a session by directory."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code
                                    :command "claude"
                                    :directory "/my/project")))
      (should (eq s (baton-monet--find-session "/my/project")))
      (should (null (baton-monet--find-session "/other"))))))

(ert-deftest baton-test-monet-find-session-prefers-claude-code ()
  "baton-monet--find-session prefers claude-code when multiple sessions match."
  (baton-test-with-clean-state
    (let ((s-aider  (baton-session-create :agent 'aider
                                           :command "aider"
                                           :directory "/proj"))
          (s-claude (baton-session-create :agent 'claude-code
                                           :command "claude"
                                           :directory "/proj")))
      (should (eq s-claude (baton-monet--find-session "/proj"))))))

(ert-deftest baton-test-monet-open-diff-defers ()
  "baton-monet--open-diff-handler stores :pending-diff and sets status to waiting."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           ;; Stub monet functions
           (monet-session (list :directory "/proj"))
           thunk-called)
      (cl-letf (((symbol-function 'monet-session-directory)
                 (lambda (_ms) "/proj"))
                ((symbol-function 'monet-make-open-diff-handler)
                 (lambda (diff-fn) (lambda (_params _ms) (funcall diff-fn nil nil nil nil nil nil))))
                ((symbol-function 'monet-ediff-tool)
                 (lambda (_old _new _contents _accept _quit _sess)
                   (setq thunk-called t))))
        (baton-monet--open-diff-handler nil monet-session)
        ;; Status is set to waiting
        (should (eq (baton--session-status s) 'waiting))
        (should (equal (baton--session-waiting-reason s) "diff review"))
        ;; A thunk was stored but NOT yet called
        (should (plist-get (baton--session-metadata s) :pending-diff))
        (should-not thunk-called)))))

(ert-deftest baton-test-monet-review-diff-invokes-thunk ()
  "baton-review-diff calls the stored thunk and clears :pending-diff."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           thunk-called)
      (setf (baton--session-metadata s)
            (plist-put (baton--session-metadata s)
                       :pending-diff (lambda () (setq thunk-called t))))
      (baton-review-diff (baton--session-name s))
      (should thunk-called)
      (should (null (plist-get (baton--session-metadata s) :pending-diff))))))

(ert-deftest baton-test-monet-pending-diff-preserves-reason ()
  "Watcher preserves \"diff review\" reason when :pending-diff is set in metadata.
Even when the terminal output matches a different waiting pattern (e.g.
\"confirmation\"), the status must stay \"diff review\" until the diff is reviewed."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'claude-code
     :command "claude"
     :status-function-trigger :periodic
     :status-function (baton-process-make-regex-status-function
                       '(("Do you want to" . (:waiting . "confirmation")))))
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (content "Do you want to make this edit? [Y/n]")
           (buf (get-buffer-create " *baton-test-pending-diff*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-status s) 'waiting)
            (setf (baton--session-waiting-reason s) "diff review")
            (with-current-buffer buf
              (insert content))
            ;; Set up metadata: pending-diff present; output quiet for 10s
            (let ((hash (with-current-buffer buf
                          (md5 (buffer-substring-no-properties (point-min) (point-max))))))
              (setf (baton--session-metadata s)
                    (list :pending-diff (lambda () t)
                          :last-output-hash hash
                          :last-output-time (- (float-time) 10.0)
                          :current-hash hash
                          :last-seen-hash hash
                          :watcher-timer nil)))
            (baton-process--watcher-tick s)
            (should (eq (baton--session-status s) 'waiting))
            (should (equal (baton--session-waiting-reason s) "diff review")))
        (kill-buffer buf)))))

(ert-deftest baton-test-monet-review-bar-activates-on-diff-review ()
  "baton-monet--update-review-bar activates mode-line bar and review mode."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (buf (get-buffer-create " *baton-test-review-bar*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-status s) 'waiting)
            (setf (baton--session-waiting-reason s) "diff review")
            ;; Simulate status-changed hook call
            (baton-monet--update-review-bar s 'running 'waiting)
            (with-current-buffer buf
              (should (local-variable-p 'mode-line-format))
              (should baton--session-review-mode))
            ;; Transition to idle: bar should clear
            (baton-session-set-status s 'idle)
            (baton-monet--update-review-bar s 'waiting 'idle)
            (with-current-buffer buf
              (should-not (local-variable-p 'mode-line-format))
              (should-not baton--session-review-mode)))
        (kill-buffer buf)))))

(ert-deftest baton-test-monet-setup-enables-baton-set ()
  "baton-monet-setup registers openDiff in :baton set and enables it."
  (skip-unless (featurep 'monet))
  (baton-test-with-clean-state
    (baton-define-agent :name 'claude-code :command "claude"
                        :status-function-trigger :periodic)
    (let ((monet--tool-registry nil)
          (monet--enabled-sets '(:core :simple-diff))
          (monet-open-diff-tool-schema nil))
      (baton-monet-setup)
      (should (assoc (cons :baton "openDiff") monet--tool-registry))
      (should (memq :baton monet--enabled-sets)))))

(provide 'baton-monet-tests)
;;; baton-monet-tests.el ends here
