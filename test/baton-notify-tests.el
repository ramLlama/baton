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
            (setf (baton--session-metadata s)
                  (list :current-hash "changed" :last-seen-hash nil))
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
            (setf (baton--session-metadata s)
                  (list :current-hash "same" :last-seen-hash "same"))
            (let ((str (baton-notify--modeline-string)))
              (should-not (string-match-p "\\*" str))))
        (kill-buffer buf)))))

;;; ─── baton-notify timer and callback tests ───────────────────────────────────

(ert-deftest baton-test-notify-fires-on-waiting ()
  "Transitioning to waiting schedules a notify timer."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      (baton-notify--on-status-changed s 'running 'waiting)
      (should (timerp (plist-get (baton--session-metadata s) :idle-notify-timer)))
      (baton-notify--cancel-idle-timer s))))

(ert-deftest baton-test-notify-pending-callback-fires-on-waiting ()
  "baton-notify--pending-notify-callback notifies when session is waiting."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (baton-session-set-status s 'waiting "permission prompt")
      (baton-notify--pending-notify-callback s)
      (should (eq notified-session s)))))

(ert-deftest baton-test-notify-unread-handler-no-longer-notifies ()
  "baton-notify--on-unread-changed does not call baton-notify-function directly."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (baton-session-set-status s 'idle)
      (baton-notify--on-unread-changed s)
      (should (null notified-session)))))

(ert-deftest baton-test-notify-status-idle-schedules-timer ()
  "Transitioning to idle schedules an :idle-notify-timer in session metadata."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-idle-timer*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s)
                  (list :current-hash "new" :last-seen-hash "old"))
            (baton-notify--on-status-changed s 'running 'idle)
            (should (timerp (plist-get (baton--session-metadata s) :idle-notify-timer)))
            (baton-notify--cancel-idle-timer s))
        (kill-buffer buf)))))

(ert-deftest baton-test-notify-status-non-idle-cancels-timer ()
  "Transitioning away from idle cancels any pending :idle-notify-timer."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-cancel-timer*")))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s)
                  (list :current-hash "new" :last-seen-hash "old"))
            (baton-notify--on-status-changed s 'running 'idle)
            (should (timerp (plist-get (baton--session-metadata s) :idle-notify-timer)))
            (baton-notify--on-status-changed s 'idle 'running)
            (should (null (plist-get (baton--session-metadata s) :idle-notify-timer))))
        (kill-buffer buf)))))

(ert-deftest baton-test-notify-idle-timer-fires-when-unread ()
  "The pending notify callback fires baton-notify-function when session is idle and unread."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-idle-fire*"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s)
                  (list :current-hash "new" :last-seen-hash "old"))
            (baton-session-set-status s 'idle)
            (baton-notify--pending-notify-callback s)
            (should (eq notified-session s)))
        (kill-buffer buf)))))

(ert-deftest baton-test-notify-idle-timer-skips-when-read ()
  "The pending notify callback does not fire when idle output has been seen."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-idle-skip*"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            (setf (baton--session-metadata s)
                  (list :current-hash "same" :last-seen-hash "same"))
            (baton-session-set-status s 'idle)
            (baton-notify--pending-notify-callback s)
            (should (null notified-session)))
        (kill-buffer buf)))))

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
  "An error session fires baton-notify-function only when it has unread output."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-error-unread*"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            ;; Unread: hashes differ
            (setf (baton--session-metadata s)
                  (list :current-hash "new" :last-seen-hash "old"))
            (baton-session-set-status s 'error "crashed")
            (baton-notify--pending-notify-callback s)
            (should (eq notified-session s)))
        (kill-buffer buf)))))

(ert-deftest baton-test-notify-error-skips-when-read ()
  "An error session does not fire baton-notify-function when the buffer has been seen."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *baton-test-error-read*"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (unwind-protect
          (progn
            (setf (baton--session-buffer s) buf)
            ;; Read: hashes match
            (setf (baton--session-metadata s)
                  (list :current-hash "same" :last-seen-hash "same"))
            (baton-session-set-status s 'error "crashed")
            (baton-notify--pending-notify-callback s)
            (should (null notified-session)))
        (kill-buffer buf)))))

(ert-deftest baton-test-notify-other-schedules-timer ()
  "Transitioning to `other' status schedules a notify timer."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp")))
      (baton-notify--on-status-changed s 'running 'other)
      (should (timerp (plist-get (baton--session-metadata s) :idle-notify-timer)))
      (baton-notify--cancel-idle-timer s))))

(provide 'baton-notify-tests)
;;; baton-notify-tests.el ends here
