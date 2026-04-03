;;; baton-alert-tests.el --- ERT tests for baton-alert  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; ERT tests for the alert backend registry and dispatch logic.

;;; Code:
(require 'ert)
(require 'baton-test-helpers)
(require 'baton-alert)

;;; ─── baton-alert tests ───────────────────────────────────────────────────────

(ert-deftest baton-test-alert-format-waiting ()
  "baton-alert--format returns correct title and body for a waiting session."
  (baton-alert-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude"
                                    :directory "/tmp")))
      (baton-session-set-status s 'waiting "permission prompt")
      (let ((info (baton-alert--format s)))
        (should (string-match-p "baton:" (plist-get info :title)))
        (should (string-match-p "permission prompt" (plist-get info :body)))))))

(ert-deftest baton-test-alert-format-unread ()
  "baton-alert--format uses \"unread output\" when waiting-reason is nil."
  (baton-alert-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude"
                                    :directory "/tmp")))
      (let ((info (baton-alert--format s)))
        (should (string-match-p "unread output" (plist-get info :body)))))))

(ert-deftest baton-test-alert-register-prepends ()
  "baton-alert--register-backend prepends, giving user backends higher priority."
  (baton-alert-test-with-clean-state
    (baton-alert--register-backend 'first-backend
      :predicate (lambda () nil)
      :handler (lambda (_t _b) nil))
    (baton-alert--register-backend 'second-backend
      :predicate (lambda () nil)
      :handler (lambda (_t _b) nil))
    ;; second-backend was registered last and prepended, so it should be first
    (should (eq 'second-backend (car (baton-alert--backend-names))))))

(ert-deftest baton-test-alert-deregister-removes ()
  "baton-alert--deregister-backend removes the named backend from the registry."
  (baton-alert-test-with-clean-state
    (baton-alert--register-backend 'my-backend
      :predicate (lambda () nil)
      :handler (lambda (_t _b) nil))
    (should (memq 'my-backend (baton-alert--backend-names)))
    (baton-alert--deregister-backend 'my-backend)
    (should-not (memq 'my-backend (baton-alert--backend-names)))))

(ert-deftest baton-test-alert-dispatch-calls-first-available ()
  "baton-alert--dispatch calls the first backend whose predicate returns non-nil."
  (baton-alert-test-with-clean-state
    (let (called-backend)
      ;; Register via append so we control order explicitly
      (baton-alert--do-register 'never-matches
        `(:predicate ,(lambda () nil)
          :handler ,(lambda (_t _b) (setq called-backend 'never-matches)))
        t)
      (baton-alert--do-register 'always-matches
        `(:predicate ,(lambda () t)
          :handler ,(lambda (_t _b) (setq called-backend 'always-matches)))
        t)
      (let ((s (baton-session-create :agent 'claude-code :command "claude"
                                      :directory "/tmp")))
        (baton-alert--dispatch s)
        (should (eq called-backend 'always-matches))))))

(ert-deftest baton-test-alert-dispatch-stops-at-first ()
  "baton-alert--dispatch does not call a backend after the first matching one."
  (baton-alert-test-with-clean-state
    (let ((call-count 0))
      (baton-alert--do-register 'backend-a
        `(:predicate ,(lambda () t)
          :handler ,(lambda (_t _b) (cl-incf call-count)))
        t)
      (baton-alert--do-register 'backend-b
        `(:predicate ,(lambda () t)
          :handler ,(lambda (_t _b) (cl-incf call-count)))
        t)
      (let ((s (baton-session-create :agent 'claude-code :command "claude"
                                      :directory "/tmp")))
        (baton-alert--dispatch s)
        (should (= 1 call-count))))))

(ert-deftest baton-test-alert-dispatch-no-match-no-error ()
  "baton-alert--dispatch does nothing when no predicate returns non-nil."
  (baton-alert-test-with-clean-state
    (baton-alert--do-register 'never-fires
      `(:predicate ,(lambda () nil)
        :handler ,(lambda (_t _b) (error "Should not fire")))
      t)
    (let ((s (baton-session-create :agent 'claude-code :command "claude"
                                    :directory "/tmp")))
      ;; Should complete without error
      (baton-alert--dispatch s)
      (should t))))

(ert-deftest baton-test-alert-osc777-predicate-ssh ()
  "osc777 predicate returns non-nil when SSH_CLIENT is set in the environment."
  (let* ((entry (assq 'osc777 baton-alert--backends))
         (pred (plist-get (cdr entry) :predicate))
         (process-environment
          (cons "SSH_CLIENT=1.2.3.4 1234 5678"
                (cl-remove-if (lambda (s) (string-prefix-p "SSH_" s))
                              process-environment))))
    (should (funcall pred))))

(ert-deftest baton-test-alert-osc777-predicate-no-ssh ()
  "osc777 predicate returns nil when no SSH environment variables are set."
  (let* ((entry (assq 'osc777 baton-alert--backends))
         (pred (plist-get (cdr entry) :predicate))
         (process-environment
          (cl-remove-if (lambda (s) (string-prefix-p "SSH_" s))
                        process-environment)))
    (should-not (funcall pred))))

(ert-deftest baton-test-alert-osc777-handler-format ()
  "osc777 handler sends the correct OSC 777 escape sequence."
  (let* ((entry (assq 'osc777 baton-alert--backends))
         (handler (plist-get (cdr entry) :handler))
         captured)
    (cl-letf (((symbol-function 'send-string-to-terminal)
               (lambda (s) (setq captured s))))
      (funcall handler "My Title" "My Body"))
    (should (equal captured "\033]777;notify;My Title;My Body\a"))))

(ert-deftest baton-test-alert-setup-replaces-notify-function ()
  "baton-alert--setup replaces baton-notify-function with baton-alert--dispatch."
  (let ((baton-notify-function #'baton-notify--default))
    (baton-alert--setup)
    (should (eq baton-notify-function #'baton-alert--dispatch))))

(provide 'baton-alert-tests)
;;; baton-alert-tests.el ends here
