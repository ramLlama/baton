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

(ert-deftest baton-test-monet-open-diff-defers ()
  "baton-monet--open-diff-handler stores :pending-diff and sets status to waiting."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           ;; Monet session whose key is the baton session name
           (monet-session (list :key (baton--session-name s)))
           thunk-called)
      (cl-letf (((symbol-function 'monet-session-key)
                 (lambda (ms) (plist-get ms :key)))
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

(ert-deftest baton-test-monet-open-diff-routes-by-key ()
  "baton-monet--open-diff-handler routes to the correct session by monet session key.
Two claude-code sessions share the same directory; only the one whose
name matches the monet session key should receive the pending diff."
  (baton-test-with-clean-state
    (let* ((s1 (baton-session-create :agent 'claude-code
                                      :command "claude"
                                      :directory "/proj"))
           (s2 (baton-session-create :agent 'claude-code
                                      :command "claude"
                                      :directory "/proj"))
           ;; Monet session whose key matches s2's name
           (monet-session (list :key (baton--session-name s2))))
      (cl-letf (((symbol-function 'monet-session-key)
                 (lambda (ms) (plist-get ms :key)))
                ((symbol-function 'monet-make-open-diff-handler)
                 (lambda (diff-fn) (lambda (_params _ms) (funcall diff-fn nil nil nil nil nil nil))))
                ((symbol-function 'monet-ediff-tool)
                 (lambda (_old _new _contents _accept _quit _sess) nil)))
        (baton-monet--open-diff-handler nil monet-session)
        ;; s2 gets the pending diff; s1 does not
        (should (plist-get (baton--session-metadata s2) :pending-diff))
        (should (null (plist-get (baton--session-metadata s1) :pending-diff)))
        (should (eq (baton--session-status s2) 'waiting))))))

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
                       '(("Do you want to" . (waiting . "confirmation")))))
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
                          :state nil
                          :unread nil
                          :notified-at nil
                          :watcher-timer nil)))
            (baton-process--state-tick s)
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

;;; ─── baton-monet--set-state tests ───────────────────────────────────────────

(ert-deftest baton-test-monet-set-state-writes-metadata ()
  "baton-monet--set-state writes :state plist into session metadata."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code
                                    :command "claude"
                                    :directory "/proj")))
      (baton-monet--set-state s 'waiting "input prompt")
      (let ((state (plist-get (baton--session-metadata s) :state)))
        (should state)
        (should (eq (plist-get state :status) 'waiting))
        (should (equal (plist-get state :reason) "input prompt"))
        (should (floatp (plist-get state :at)))))))

(ert-deftest baton-test-monet-set-state-applies-status ()
  "baton-monet--set-state updates the session's status field."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code
                                    :command "claude"
                                    :directory "/proj")))
      (baton-monet--set-state s 'idle)
      (should (eq (baton--session-status s) 'idle)))))

(ert-deftest baton-test-monet-hook-status-fn-reads-state ()
  "baton-monet--hook-status-fn returns (status . reason) from :state metadata."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code
                                    :command "claude"
                                    :directory "/proj")))
      (setf (baton--session-metadata s)
            (list :state '(:status waiting :reason "input prompt" :at 0.0)))
      (should (equal (baton-monet--hook-status-fn s) '(waiting . "input prompt"))))))

(ert-deftest baton-test-monet-hook-status-fn-nil-when-no-state ()
  "baton-monet--hook-status-fn returns nil when :state is nil."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code
                                    :command "claude"
                                    :directory "/proj")))
      (should (null (baton-monet--hook-status-fn s))))))

;;; ─── baton-monet--claude-hook-handler tests ─────────────────────────────────

(ert-deftest baton-test-monet-hook-handler-user-prompt-submit ()
  "UserPromptSubmit event sets session to running."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (ctx `((baton_session . ,(baton--session-name s)))))
      (baton-session-set-status s 'idle)
      (baton-monet--claude-hook-handler "UserPromptSubmit" nil ctx)
      (should (eq (baton--session-status s) 'running)))))

(ert-deftest baton-test-monet-hook-handler-stop ()
  "Stop event sets session to idle."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (ctx `((baton_session . ,(baton--session-name s)))))
      (baton-monet--claude-hook-handler "Stop" nil ctx)
      (should (eq (baton--session-status s) 'idle)))))

(ert-deftest baton-test-monet-hook-handler-notification-with-message ()
  "Notification event sets session to waiting with message as reason."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (ctx `((baton_session . ,(baton--session-name s))))
           (data '((message . "tool requires approval"))))
      (baton-monet--claude-hook-handler "Notification" data ctx)
      (should (eq (baton--session-status s) 'waiting))
      (should (equal (baton--session-waiting-reason s) "tool requires approval")))))

(ert-deftest baton-test-monet-hook-handler-notification-default-reason ()
  "Notification event with no message uses \"input prompt\" as reason."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (ctx `((baton_session . ,(baton--session-name s)))))
      (baton-monet--claude-hook-handler "Notification" nil ctx)
      (should (eq (baton--session-status s) 'waiting))
      (should (equal (baton--session-waiting-reason s) "input prompt")))))

(ert-deftest baton-test-monet-hook-handler-no-session-no-op ()
  "Missing baton_session in ctx causes handler to do nothing."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (initial-status (baton--session-status s)))
      ;; ctx has no baton_session key
      (baton-monet--claude-hook-handler "Stop" nil nil)
      (should (eq (baton--session-status s) initial-status)))))

(ert-deftest baton-test-monet-hook-handler-pending-diff-skipped ()
  "Handler skips dispatch when :pending-diff is set in session metadata."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (ctx `((baton_session . ,(baton--session-name s)))))
      (baton-session-set-status s 'waiting "diff review")
      (setf (baton--session-metadata s)
            (plist-put (baton--session-metadata s) :pending-diff (lambda () t)))
      ;; Stop event would normally set idle, but pending-diff protects it
      (baton-monet--claude-hook-handler "Stop" nil ctx)
      (should (eq (baton--session-status s) 'waiting))
      (should (equal (baton--session-waiting-reason s) "diff review")))))

;;; ─── baton-monet--session-env-function tests ────────────────────────────────

(ert-deftest baton-test-monet-session-env-function ()
  "baton-monet--session-env-function returns MONET_CTX_baton_session env var."
  (should (equal (baton-monet--session-env-function "claude-1" "/proj")
                 '("MONET_CTX_baton_session=claude-1"))))

;;; ─── baton-monet-setup / baton-monet--teardown tests ────────────────────────

(ert-deftest baton-test-monet-setup-switches-claude-to-on-event ()
  "baton-monet-setup switches claude-code from :periodic to :on-event trigger."
  (skip-unless (featurep 'monet))
  (baton-test-with-clean-state
    (let ((original-fn (lambda (_s) nil)))
      (baton-define-agent :name 'claude-code :command "claude"
                          :status-function-trigger :periodic
                          :status-function original-fn)
      (let ((monet--tool-registry nil)
            (monet--enabled-sets '(:core :simple-diff))
            (monet-open-diff-tool-schema nil)
            (monet--claude-hook-functions nil)
            (baton-monet--saved-claude-status-fn nil)
            (baton-monet--saved-claude-trigger nil))
        (baton-monet-setup)
        (let ((def (gethash 'claude-code baton-agents)))
          (should (eq (plist-get def :status-function-trigger) :on-event))
          (should (eq (plist-get def :status-function) #'baton-monet--hook-status-fn)))
        (should (eq baton-monet--saved-claude-trigger :periodic))
        (should (eq baton-monet--saved-claude-status-fn original-fn))))))

(ert-deftest baton-test-monet-teardown-restores-claude ()
  "baton-monet--teardown restores claude-code's original trigger and status-fn."
  (skip-unless (featurep 'monet))
  (baton-test-with-clean-state
    (let ((original-fn (lambda (_s) nil)))
      (baton-define-agent :name 'claude-code :command "claude"
                          :status-function-trigger :periodic
                          :status-function original-fn)
      (let ((monet--tool-registry nil)
            (monet--enabled-sets '(:core :simple-diff))
            (monet-open-diff-tool-schema nil)
            (monet--claude-hook-functions nil)
            (baton-monet--saved-claude-status-fn nil)
            (baton-monet--saved-claude-trigger nil))
        (baton-monet-setup)
        (baton-monet--teardown)
        (let ((def (gethash 'claude-code baton-agents)))
          (should (eq (plist-get def :status-function-trigger) :periodic))
          (should (eq (plist-get def :status-function) original-fn)))
        (should-not (memq #'baton-monet--claude-hook-handler monet--claude-hook-functions))))))

(provide 'baton-monet-tests)
;;; baton-monet-tests.el ends here
