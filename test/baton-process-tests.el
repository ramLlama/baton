;;; baton-process-tests.el --- ERT tests for baton-process and agent registry  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; ERT tests for the agent registry, pattern matching utilities, env-functions,
;; and :status-function dispatch through the watcher tick.

;;; Code:
(require 'ert)
(require 'baton-test-helpers)
(require 'baton-process)
(require 'baton)

;;; ─── Agent registry tests ────────────────────────────────────────────────────

(ert-deftest baton-test-define-agent-stores ()
  "baton-define-agent stores the definition at the symbol key."
  (baton-test-with-clean-state
    (baton-define-agent :name 'my-agent :command "my-cmd")
    (should (gethash 'my-agent baton-agents))))

(ert-deftest baton-test-define-agent-retrieval ()
  "The :command is retrievable from the stored definition."
  (baton-test-with-clean-state
    (baton-define-agent :name 'my-agent :command "my-cmd")
    (should (equal "my-cmd"
                   (plist-get (gethash 'my-agent baton-agents) :command)))))

(ert-deftest baton-test-agent-status-function ()
  "A :status-function built from patterns matches and returns the right result."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'my-agent
     :command "cmd"
     :status-function (baton-process-make-regex-status-function
                       '(("^> "  . (:waiting . "input"))
                         ("Allow" . (:waiting . "permission"))
                         ("CRASH" . (:error   . "crashed")))))
    (let ((fn (plist-get (gethash 'my-agent baton-agents) :status-function)))
      (should (functionp fn))
      (should (equal (funcall fn "> ") '(:waiting . "input")))
      (should (equal (funcall fn "Allow this tool") '(:waiting . "permission")))
      (should (equal (funcall fn "CRASH detected") '(:error . "crashed")))
      (should (null (funcall fn "nothing matches"))))))

;;; ─── :status-function watcher dispatch tests ────────────────────────────────

(ert-deftest baton-test-process-status-function-waiting ()
  "A :status-function returning (:waiting . reason) sets session to waiting."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'fn-agent
     :command "cmd"
     :status-function (lambda (_text) '(:waiting . "fn-reason")))
    (let* ((s (baton-session-create :agent 'fn-agent :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-sf-waiting*")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "some output"))
            (setf (baton--session-buffer s) buf)
            (let ((hash (md5 "some output")))
              (setf (baton--session-metadata s)
                    (list :last-output-hash hash
                          :last-output-time (- (float-time) 10.0)
                          :current-hash hash
                          :last-seen-hash hash
                          :watcher-timer nil)))
            (baton-process--watcher-tick s)
            (should (eq (baton--session-status s) 'waiting))
            (should (equal (baton--session-waiting-reason s) "fn-reason")))
        (kill-buffer buf)))))

(ert-deftest baton-test-process-status-function-running ()
  "A :status-function returning (:running . nil) sets session to running."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'fn-agent-running
     :command "cmd"
     :status-function (lambda (_text) '(:running . nil)))
    (let* ((s (baton-session-create :agent 'fn-agent-running :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-sf-running*")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "busy"))
            (setf (baton--session-buffer s) buf)
            (let ((hash (md5 "busy")))
              (setf (baton--session-metadata s)
                    (list :last-output-hash hash
                          :last-output-time (- (float-time) 10.0)
                          :current-hash hash
                          :last-seen-hash hash
                          :watcher-timer nil)))
            (baton-process--watcher-tick s)
            (should (eq (baton--session-status s) 'running)))
        (kill-buffer buf)))))

(ert-deftest baton-test-process-status-function-nil-yields-idle ()
  "A :status-function returning nil sets session to idle."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'fn-agent-idle
     :command "cmd"
     :status-function (lambda (_text) nil))
    (let* ((s (baton-session-create :agent 'fn-agent-idle :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-sf-idle*")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "quiet"))
            (setf (baton--session-buffer s) buf)
            (let ((hash (md5 "quiet")))
              (setf (baton--session-metadata s)
                    (list :last-output-hash hash
                          :last-output-time (- (float-time) 10.0)
                          :current-hash hash
                          :last-seen-hash hash
                          :watcher-timer nil)))
            (baton-process--watcher-tick s)
            (should (eq (baton--session-status s) 'idle)))
        (kill-buffer buf)))))

;;; ─── baton-process env-functions tests ──────────────────────────────────────

(ert-deftest baton-test-env-functions-nil-by-default ()
  "baton-define-agent without :env-functions stores nil."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd")
    (should (null (plist-get (gethash 'test-agent baton-agents) :env-functions)))))

(ert-deftest baton-test-env-functions-add-appends ()
  "baton-add-env-function appends; calling twice gives two entries in order."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd")
    (let ((fn1 (lambda (_k _d) '("A=1")))
          (fn2 (lambda (_k _d) '("B=2"))))
      (baton-add-env-function 'test-agent fn1)
      (baton-add-env-function 'test-agent fn2)
      (let ((fns (plist-get (gethash 'test-agent baton-agents) :env-functions)))
        (should (= 2 (length fns)))
        (should (eq (nth 0 fns) fn1))
        (should (eq (nth 1 fns) fn2))))))

(ert-deftest baton-test-env-functions-add-idempotent ()
  "baton-add-env-function is idempotent: adding the same fn twice gives one entry."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd")
    (let ((fn (lambda (_k _d) '("A=1"))))
      (baton-add-env-function 'test-agent fn)
      (baton-add-env-function 'test-agent fn)
      (let ((fns (plist-get (gethash 'test-agent baton-agents) :env-functions)))
        (should (= 1 (length fns)))
        (should (eq (car fns) fn))))))

(ert-deftest baton-test-env-functions-multiple-combined ()
  "Multiple env-functions results are flattened via apply #'append."
  (baton-test-with-clean-state
    (let* ((fn1 (lambda (_k _d) '("A=1")))
           (fn2 (lambda (_k _d) '("B=2" "C=3")))
           (env-fns (list fn1 fn2))
           (extra-env (apply #'append
                             (mapcar (lambda (f) (funcall f "id" "/tmp")) env-fns))))
      (should (equal extra-env '("A=1" "B=2" "C=3"))))))

(ert-deftest baton-test-env-functions-nil-produces-no-extra-env ()
  "nil :env-functions does not produce extra env vars."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd")
    (let* ((def (gethash 'test-agent baton-agents))
           (env-fns (plist-get def :env-functions))
           (extra-env (when env-fns
                        (apply #'append
                               (mapcar (lambda (f) (funcall f "id" "/tmp")) env-fns)))))
      (should (null extra-env)))))

(provide 'baton-process-tests)
;;; baton-process-tests.el ends here
