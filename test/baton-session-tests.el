;;; baton-session-tests.el --- ERT tests for baton-session  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; ERT tests for session lifecycle, registry, status management, and unread tracking.

;;; Code:
(require 'ert)
(require 'baton-test-helpers)
(require 'baton-session)

;;; ─── baton-session tests ────────────────────────────────────────────────────

(ert-deftest baton-test-session-create-returns-struct ()
  "baton-session-create returns a baton--session struct."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code
                                    :command "claude"
                                    :directory "/tmp")))
      (should (baton--session-p s)))))

(ert-deftest baton-test-session-create-adds-to-registry ()
  "Created session is findable via baton-session-get."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/tmp"))
           (found (baton-session-get (baton--session-name s))))
      (should (eq s found)))))

(ert-deftest baton-test-session-create-duplicate-name-errors ()
  "Creating a session with a name that already exists signals an error."
  (baton-test-with-clean-state
    (baton-session-create :agent 'claude-code :command "claude"
                           :directory "/tmp" :name "my-agent")
    (should-error (baton-session-create :agent 'claude-code :command "claude"
                                         :directory "/tmp" :name "my-agent")
                  :type 'error)))

(ert-deftest baton-test-session-create-auto-name ()
  "Auto-names use agent short prefix and incrementing counter."
  (baton-test-with-clean-state
    (let ((s1 (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/tmp"))
          (s2 (baton-session-create :agent 'claude-code
                                     :command "claude"
                                     :directory "/tmp")))
      (should (equal (baton--session-name s1) "claude-1"))
      (should (equal (baton--session-name s2) "claude-2")))))

(ert-deftest baton-test-session-create-explicit-name ()
  "baton-session-create respects an explicit :name argument."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code
                                    :command "claude"
                                    :directory "/tmp"
                                    :name "my-agent")))
      (should (equal (baton--session-name s) "my-agent")))))

(ert-deftest baton-test-session-create-fires-hook ()
  "baton-session-create fires baton-session-created-hook with the session."
  (baton-test-with-clean-state
    (let (hook-arg)
      (add-hook 'baton-session-created-hook (lambda (s) (setq hook-arg s)))
      (let ((s (baton-session-create :agent 'claude-code
                                      :command "claude"
                                      :directory "/tmp")))
        (should (eq hook-arg s))))))

(ert-deftest baton-test-session-list-all ()
  "baton-session-list returns all sessions."
  (baton-test-with-clean-state
    (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")
    (baton-session-create :agent 'aider       :command "aider"  :directory "/tmp")
    (should (= 2 (length (baton-session-list))))))

(ert-deftest baton-test-session-list-filter-by-status ()
  "baton-session-list with a status argument filters correctly."
  (baton-test-with-clean-state
    (let ((s1 (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
          (s2 (baton-session-create :agent 'aider       :command "aider"  :directory "/tmp")))
      (baton-session-set-status s1 'waiting "prompt")
      (should (= 1 (length (baton-session-list 'waiting))))
      (should (eq s1 (car (baton-session-list 'waiting))))
      (should (= 1 (length (baton-session-list 'running))))
      (should (eq s2 (car (baton-session-list 'running)))))))

(ert-deftest baton-test-session-set-status ()
  "baton-session-set-status changes status and fires hook with old/new values."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
          hook-session hook-old hook-new)
      (add-hook 'baton-session-status-changed-hook
                (lambda (sess old new)
                  (setq hook-session sess hook-old old hook-new new)))
      (baton-session-set-status s 'waiting "permission prompt")
      (should (eq (baton--session-status s) 'waiting))
      (should (equal (baton--session-waiting-reason s) "permission prompt"))
      (should (eq hook-session s))
      (should (eq hook-old 'running))
      (should (eq hook-new 'waiting)))))

(ert-deftest baton-test-session-set-status-clears-reason ()
  "Transitioning away from waiting clears the waiting-reason."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      (baton-session-set-status s 'waiting "something")
      (baton-session-set-status s 'running)
      (should (null (baton--session-waiting-reason s))))))

(ert-deftest baton-test-session-find-by-directory ()
  "baton-session-find-by-directory returns matching session."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code
                                    :command "claude"
                                    :directory "/my/project")))
      (should (eq s (baton-session-find-by-directory "/my/project")))
      (should (null (baton-session-find-by-directory "/other"))))))

(ert-deftest baton-test-session-kill-removes-from-registry ()
  "baton-session-kill removes the session from the registry."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      (baton-session-kill s)
      (should (null (baton-session-get (baton--session-name s))))
      (should (= 0 (length (baton-session-list)))))))

(ert-deftest baton-test-session-kill-fires-hook ()
  "baton-session-kill fires baton-session-killed-hook with the session."
  (baton-test-with-clean-state
    (let (hook-arg)
      (add-hook 'baton-session-killed-hook (lambda (s) (setq hook-arg s)))
      (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
        (baton-session-kill s)
        (should (eq hook-arg s))))))

;;; ─── baton-session unread tests ─────────────────────────────────────────────

(ert-deftest baton-test-session-unread-p-no-buffer ()
  "baton-session-unread-p returns nil when session has no live buffer."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      ;; No buffer set — buffer field is nil
      (should (null (baton-session-unread-p s))))))

(ert-deftest baton-test-session-unread-p-hashes-differ ()
  "baton-session-unread-p returns t when current-hash differs from last-seen-hash."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-unread*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s)
                  (list :current-hash "abc123" :last-seen-hash nil))
            ;; Buffer not in any window → unread
            (should (baton-session-unread-p s)))
        (kill-buffer buf)))))

(ert-deftest baton-test-session-unread-p-hashes-equal ()
  "baton-session-unread-p returns nil when current-hash equals last-seen-hash."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-read*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s)
                  (list :current-hash "abc123" :last-seen-hash "abc123"))
            (should (null (baton-session-unread-p s))))
        (kill-buffer buf)))))

(provide 'baton-session-tests)
;;; baton-session-tests.el ends here
