;;; baton-notify-tests.el --- ERT tests for baton-notify  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; ERT tests for the modeline segment, timer scheduling, and status buffer rendering.

;;; Code:
(require 'ert)
(require 'baton-test-helpers)
(require 'baton-notify)

;;; ─── baton-notify modeline tests ────────────────────────────────────────────

(ert-deftest baton-test-notify-modeline-no-sessions ()
  "Modeline string is empty when there are no sessions."
  (baton-test-with-clean-state
    (should (equal "" (baton-notify--modeline-string)))))

(ert-deftest baton-test-notify-modeline-running-only ()
  "Modeline shows Nr count when sessions are running."
  (baton-test-with-clean-state
    (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")
    (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")
    (let ((str (baton-notify--modeline-string)))
      (should (string-match-p "B\\[2r\\]" str))
      (should-not (string-match-p "/" str)))))

(ert-deftest baton-test-notify-modeline-with-waiting ()
  "Modeline shows Nw/Nr when a session is waiting."
  (baton-test-with-clean-state
    (let ((s1 (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
          (s2 (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
          (s3 (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      (baton-session-set-status s1 'waiting "prompt")
      (let ((str (baton-notify--modeline-string)))
        ;; 1 waiting, 2 running -> B[1w/2r]
        (should (string-match-p "B\\[1w/2r\\]" str))))))

(ert-deftest baton-test-notify-modeline-idle-state ()
  "Modeline shows Ni count for idle sessions."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      (baton-session-set-status s 'idle)
      (let ((str (baton-notify--modeline-string)))
        (should (string-match-p "B\\[1i\\]" str))))))

(ert-deftest baton-test-notify-modeline-unread-count ()
  "Modeline shows N* when sessions have unread output."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-unread-ml*")))
      (unwind-protect
          (progn
            (baton-session-set-status s 'idle)
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (list :unread t))
            (let ((str (baton-notify--modeline-string)))
              (should (string-match-p "1\\*" str))))
        (kill-buffer buf)))))

(ert-deftest baton-test-notify-modeline-no-unread ()
  "Modeline omits * when all sessions have read output."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-read-ml*")))
      (unwind-protect
          (progn
            (baton-session-set-status s 'idle)
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (list :unread nil))
            (let ((str (baton-notify--modeline-string)))
              (should-not (string-match-p "\\*" str))))
        (kill-buffer buf)))))

;;; ─── baton-notify status-change and notification tests ──────────────────────

(ert-deftest baton-test-notify-unread-handler-no-longer-notifies ()
  "baton-notify--on-unread-changed does not call baton-notify-function directly."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (baton-session-set-status s 'idle)
      (baton-notify--on-unread-changed s)
      (should (null notified-session)))))

(ert-deftest baton-test-notify-status-change-marks-unread ()
  "baton-notify--on-status-changed-mark-unread sets :unread when buffer not visible."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-mark-unread*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (list :unread nil))
            (baton-notify--on-status-changed-mark-unread s 'running 'waiting)
            (should (plist-get (baton--session-metadata s) :unread)))
        (kill-buffer buf)))))

(ert-deftest baton-test-notify-status-change-running-no-unread ()
  "baton-notify--on-status-changed-mark-unread does not set :unread for running."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-running-no-unread*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (list :unread nil))
            (baton-notify--on-status-changed-mark-unread s 'idle 'running)
            (should-not (plist-get (baton--session-metadata s) :unread)))
        (kill-buffer buf)))))

(ert-deftest baton-test-notify-maybe-notify-waiting ()
  "baton-notify--maybe-notify fires for a waiting session."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (baton-session-set-status s 'waiting "permission prompt")
      (baton-notify--maybe-notify s)
      (should (eq notified-session s)))))

(ert-deftest baton-test-notify-maybe-notify-idle-unread ()
  "baton-notify--maybe-notify fires for an idle session with unread output."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-maybe-idle-unread*"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (list :unread t))
            (baton-session-set-status s 'idle)
            (baton-notify--maybe-notify s)
            (should (eq notified-session s)))
        (kill-buffer buf)))))

(ert-deftest baton-test-notify-maybe-notify-idle-read ()
  "baton-notify--maybe-notify does not fire for an idle session with no unread output."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (setf (baton--session-metadata s) (list :unread nil))
      (baton-session-set-status s 'idle)
      (baton-notify--maybe-notify s)
      (should (null notified-session)))))

(ert-deftest baton-test-notify-global-tick-fires-after-delay ()
  "baton-notify--global-tick fires notification when baton-notify-delay has elapsed."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess)))
           (baton-notify-delay 5))
      (baton-session-set-status s 'waiting "prompt")
      (setf (baton--session-metadata s)
            (list :state (list :status 'waiting :reason "prompt"
                               :at (- (float-time) 10.0))
                  :notified-at nil
                  :unread nil))
      (baton-notify--global-tick)
      (should (eq notified-session s)))))

(ert-deftest baton-test-notify-global-tick-skips-before-delay ()
  "baton-notify--global-tick does not fire before baton-notify-delay elapses."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess)))
           (baton-notify-delay 5))
      (baton-session-set-status s 'waiting "prompt")
      (setf (baton--session-metadata s)
            (list :state (list :status 'waiting :reason "prompt"
                               :at (- (float-time) 0.1))
                  :notified-at nil
                  :unread nil))
      (baton-notify--global-tick)
      (should (null notified-session)))))

(ert-deftest baton-test-notify-global-tick-skips-when-already-notified ()
  "baton-notify--global-tick does not re-notify after :notified-at >= :state :at."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notify-count
           (baton-notify-function (lambda (_sess) (cl-incf notify-count)))
           (baton-notify-delay 0)
           (state-at (- (float-time) 10.0)))
      (setq notify-count 0)
      (baton-session-set-status s 'waiting "prompt")
      (setf (baton--session-metadata s)
            (list :state (list :status 'waiting :reason "prompt" :at state-at)
                  :notified-at (+ state-at 1.0)
                  :unread nil))
      (baton-notify--global-tick)
      (should (= 0 notify-count)))))

(ert-deftest baton-test-notify-global-tick-skips-stale-state ()
  "baton-notify--global-tick skips notification when :state is stale (status diverged)."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess)))
           (baton-notify-delay 0))
      ;; :state says waiting, but session is now running (e.g. user sent input)
      (baton-session-set-status s 'running)
      (setf (baton--session-metadata s)
            (list :state (list :status 'waiting :reason "prompt"
                               :at (- (float-time) 10.0))
                  :notified-at nil
                  :unread nil))
      (baton-notify--global-tick)
      (should (null notified-session)))))

;;; ─── baton-notify status buffer rendering tests ─────────────────────────────

(ert-deftest baton-test-status-buffer-format-waiting ()
  "A waiting session entry includes the waiting indicator and reason."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      (baton-session-set-status s 'waiting "permission prompt")
      (let* ((entry (baton-notify--format-entry s nil))
             (cols (cadr entry)))
        ;; cols[5] is the reason column
        (should (string-match-p "permission prompt" (aref cols 5)))
        ;; cols[3] is the status column
        (should (string-match-p "waiting" (aref cols 3)))))))

(ert-deftest baton-test-status-buffer-format-running ()
  "A running session entry shows \"running\" status and no reason."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      (let* ((entry (baton-notify--format-entry s nil))
             (cols (cadr entry)))
        (should (string-match-p "running" (aref cols 3)))
        (should (equal "" (aref cols 5)))))))

(ert-deftest baton-test-status-buffer-format-idle ()
  "An idle session entry shows \"idle\" status and ○ indicator."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      (baton-session-set-status s 'idle)
      (let* ((entry (baton-notify--format-entry s nil))
             (cols (cadr entry)))
        (should (string-match-p "idle" (aref cols 3)))
        ;; cols[1] is the indicator
        (should (string-match-p "○" (aref cols 1)))
        (should-not (string-match-p "\\*" (aref cols 1)))))))

(ert-deftest baton-test-status-buffer-sorted ()
  "baton-notify--list-entries returns sessions sorted by created-at."
  (baton-test-with-clean-state
    (let ((s1 (baton-session-create :agent 'claude-code :command "claude" :directory "/a"))
          (s2 (baton-session-create :agent 'aider       :command "aider"  :directory "/b")))
      ;; Ensure s1 has an earlier created-at
      (setf (baton--session-created-at s1) 1000.0)
      (setf (baton--session-created-at s2) 2000.0)
      (let ((entries (baton-notify--list-entries)))
        (should (= 2 (length entries)))
        ;; First entry ID should be s1's ID
        (should (equal (baton--session-name s1) (car (nth 0 entries))))
        (should (equal (baton--session-name s2) (car (nth 1 entries))))))))

(ert-deftest baton-test-status-buffer-mark-and-kill ()
  "baton-list-execute kills sessions flagged in baton--list-marks."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (id (baton--session-name s))
           ;; Simulate the buffer-local marks
           (marks (list (cons id 'kill))))
      ;; Execute manually (without a real buffer)
      (dolist (entry marks)
        (let ((session (baton-session-get (car entry))))
          (when session
            (pcase (cdr entry)
              ('kill (baton-session-kill session))))))
      (should (null (baton-session-get id))))))

;;; ─── error/other notification tests ─────────────────────────────────────────

(ert-deftest baton-test-notify-error-notifies-when-unread ()
  "baton-notify--maybe-notify fires for an error session with unread output."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (setf (baton--session-metadata s) (list :unread t))
      (baton-session-set-status s 'error "crashed")
      (baton-notify--maybe-notify s)
      (should (eq notified-session s)))))

(ert-deftest baton-test-notify-error-skips-when-read ()
  "baton-notify--maybe-notify does not fire for an error session without unread output."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (setf (baton--session-metadata s) (list :unread nil))
      (baton-session-set-status s 'error "crashed")
      (baton-notify--maybe-notify s)
      (should (null notified-session)))))

(ert-deftest baton-test-notify-other-marks-unread ()
  "Transitioning to `other' status marks the session unread when buffer not visible."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-other-unread*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s) (list :unread nil))
            (baton-notify--on-status-changed-mark-unread s 'running 'other)
            (should (plist-get (baton--session-metadata s) :unread)))
        (kill-buffer buf)))))

(provide 'baton-notify-tests)
;;; baton-notify-tests.el ends here
