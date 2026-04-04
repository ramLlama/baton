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
    (baton-define-agent :name 'my-agent :command "my-cmd"
                        :status-function-trigger :periodic)
    (should (gethash 'my-agent baton-agents))))

(ert-deftest baton-test-define-agent-retrieval ()
  "The :command is retrievable from the stored definition."
  (baton-test-with-clean-state
    (baton-define-agent :name 'my-agent :command "my-cmd"
                        :status-function-trigger :periodic)
    (should (equal "my-cmd"
                   (plist-get (gethash 'my-agent baton-agents) :command)))))

(ert-deftest baton-test-agent-status-function ()
  "A :status-function built from patterns matches against session buffer contents."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'my-agent
     :command "cmd"
     :status-function-trigger :periodic
     :status-function (baton-process-make-regex-status-function
                       '(("^> "  . (waiting . "input"))
                         ("Allow" . (waiting . "permission"))
                         ("CRASH" . (error   . "crashed")))))
    (let* ((fn (plist-get (gethash 'my-agent baton-agents) :status-function))
           (s (baton-session-create :agent 'my-agent :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-sf*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (should (functionp fn))
            (with-current-buffer buf (erase-buffer) (insert "> "))
            (should (equal (funcall fn s) '(waiting . "input")))
            (with-current-buffer buf (erase-buffer) (insert "Allow this tool"))
            (should (equal (funcall fn s) '(waiting . "permission")))
            (with-current-buffer buf (erase-buffer) (insert "CRASH detected"))
            (should (equal (funcall fn s) '(error . "crashed")))
            (with-current-buffer buf (erase-buffer) (insert "nothing matches"))
            (should (null (funcall fn s))))
        (kill-buffer buf)))))

;;; ─── :status-function watcher dispatch tests ────────────────────────────────

(defun baton-test--quiet-metadata (buf-content)
  "Return metadata plist for a session with BUF-CONTENT that has been quiet 10s."
  (let ((hash (md5 buf-content)))
    (list :last-output-hash hash
          :last-output-time (- (float-time) 10.0)
          :state nil
          :unread nil
          :notified-at nil
          :watcher-timer nil)))

(ert-deftest baton-test-process-status-function-waiting ()
  "A :status-function returning (waiting . reason) sets session to waiting."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'fn-agent
     :command "cmd"
     :status-function-trigger :periodic
     :status-function (lambda (_session) '(waiting . "fn-reason")))
    (let* ((s (baton-session-create :agent 'fn-agent :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-sf-waiting*")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "some output"))
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (baton-test--quiet-metadata "some output"))
            (baton-process--state-tick s)
            (should (eq (baton--session-status s) 'waiting))
            (should (equal (baton--session-waiting-reason s) "fn-reason")))
        (kill-buffer buf)))))

(ert-deftest baton-test-process-status-function-running ()
  "A :status-function returning (running . nil) sets session to running."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'fn-agent-running
     :command "cmd"
     :status-function-trigger :periodic
     :status-function (lambda (_session) '(running . nil)))
    (let* ((s (baton-session-create :agent 'fn-agent-running :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-sf-running*")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "busy"))
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (baton-test--quiet-metadata "busy"))
            (baton-process--state-tick s)
            (should (eq (baton--session-status s) 'running)))
        (kill-buffer buf)))))

(ert-deftest baton-test-process-status-function-nil-yields-idle ()
  "A :status-function returning nil sets session to idle."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'fn-agent-idle
     :command "cmd"
     :status-function-trigger :periodic
     :status-function (lambda (_session) nil))
    (let* ((s (baton-session-create :agent 'fn-agent-idle :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-sf-idle*")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "quiet"))
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (baton-test--quiet-metadata "quiet"))
            (baton-process--state-tick s)
            (should (eq (baton--session-status s) 'idle)))
        (kill-buffer buf)))))

(ert-deftest baton-test-process-state-tick-writes-state ()
  "baton-process--state-tick writes :state metadata when status changes."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'state-agent
     :command "cmd"
     :status-function-trigger :periodic
     :status-function (lambda (_session) '(waiting . "prompt")))
    (let* ((s (baton-session-create :agent 'state-agent :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-state-tick*")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "output"))
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (baton-test--quiet-metadata "output"))
            (baton-process--state-tick s)
            (let ((state (plist-get (baton--session-metadata s) :state)))
              (should state)
              (should (eq (plist-get state :status) 'waiting))
              (should (equal (plist-get state :reason) "prompt"))
              (should (floatp (plist-get state :at)))))
        (kill-buffer buf)))))

;;; ─── baton-process env-functions tests ──────────────────────────────────────

(ert-deftest baton-test-env-functions-nil-by-default ()
  "baton-define-agent without :env-functions stores nil."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd"
                        :status-function-trigger :periodic)
    (should (null (plist-get (gethash 'test-agent baton-agents) :env-functions)))))

(ert-deftest baton-test-env-functions-add-appends ()
  "baton-add-env-function appends; calling twice gives two entries in order."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd"
                        :status-function-trigger :periodic)
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
    (baton-define-agent :name 'test-agent :command "cmd"
                        :status-function-trigger :periodic)
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
    (baton-define-agent :name 'test-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let* ((def (gethash 'test-agent baton-agents))
           (env-fns (plist-get def :env-functions))
           (extra-env (when env-fns
                        (apply #'append
                               (mapcar (lambda (f) (funcall f "id" "/tmp")) env-fns)))))
      (should (null extra-env)))))

;;; ─── baton-process-session-tail tests ──────────────────────────────────────

(ert-deftest baton-test-session-tail-live-buffer ()
  "baton-process-session-tail returns buffer text when buffer is live."
  (baton-test-with-clean-state
    (baton-define-agent :name 'tail-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let* ((s (baton-session-create :agent 'tail-agent :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-tail-live*")))
      (unwind-protect
          (progn
            (with-current-buffer buf (insert "hello world"))
            (setf (baton--session-buffer s) buf)
            (should (string-match-p "hello world" (baton-process-session-tail s))))
        (kill-buffer buf)))))

(ert-deftest baton-test-session-tail-dead-buffer ()
  "baton-process-session-tail returns empty string when buffer is dead."
  (baton-test-with-clean-state
    (baton-define-agent :name 'tail-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let* ((s (baton-session-create :agent 'tail-agent :command "cmd" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-tail-dead*")))
      (with-current-buffer buf (insert "content"))
      (setf (baton--session-buffer s) buf)
      (kill-buffer buf)
      (should (equal "" (baton-process-session-tail s))))))

(ert-deftest baton-test-on-event-trigger-skips-status-fn ()
  "baton-process--state-tick does not call :status-function for :on-event sessions."
  (baton-test-with-clean-state
    (let ((called nil))
      (baton-define-agent
       :name 'event-agent
       :command "cmd"
       :status-function-trigger :on-event
       :status-function (lambda (_session) (setq called t) '(waiting . "fn-called")))
      (let* ((s (baton-session-create :agent 'event-agent :command "cmd" :directory "/tmp"))
             (buf (get-buffer-create " *baton-test-on-event*")))
        (unwind-protect
            (progn
              (with-current-buffer buf (insert "some output"))
              (setf (baton--session-buffer s) buf)
              (setf (baton--session-metadata s) (baton-test--quiet-metadata "some output"))
              (baton-process--state-tick s)
              (should-not called)
              (should (eq (baton--session-status s) 'idle)))
          (kill-buffer buf))))))

(provide 'baton-process-tests)
;;; baton-process-tests.el ends here
