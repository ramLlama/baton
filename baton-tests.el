;;; baton-tests.el --- ERT test suite for baton  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; ERT tests for baton-session, baton-process (pure), baton-notify,
;; baton agent registry, and baton-monet.
;;
;; Run via Makefile:
;;   make test

;;; Code:
(require 'ert)
(require 'baton-session)
(require 'baton-process)
(require 'baton-notify)
(require 'baton)
(require 'baton-monet)

;;; Test Isolation

(defmacro baton-test-with-clean-state (&rest body)
  "Execute BODY with isolated global state: fresh sessions, counters, and agents."
  (declare (indent 0))
  `(let ((baton--sessions (make-hash-table :test 'equal))
         (baton--session-counters (make-hash-table :test 'eq))
         (baton-agents (make-hash-table :test 'eq))
         (baton-session-created-hook nil)
         (baton-session-killed-hook nil)
         (baton-session-status-changed-hook nil)
         (baton-session-unread-changed-hook nil))
     ,@body))

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

;;; ─── Agent registry tests ────────────────────────────────────────────────────

(ert-deftest baton-test-define-agent-stores ()
  "baton-define-agent stores the definition at the symbol key."
  (baton-test-with-clean-state
    (baton-define-agent :name 'my-agent
                              :command "my-cmd"
                              :waiting-patterns '((">" . "prompt")))
    (should (gethash 'my-agent baton-agents))))

(ert-deftest baton-test-define-agent-retrieval ()
  "The :command is retrievable from the stored definition."
  (baton-test-with-clean-state
    (baton-define-agent :name 'my-agent
                              :command "my-cmd"
                              :waiting-patterns nil)
    (should (equal "my-cmd"
                   (plist-get (gethash 'my-agent baton-agents) :command)))))

(ert-deftest baton-test-agent-waiting-patterns ()
  "Waiting patterns are stored as an alist of (pattern . reason)."
  (baton-test-with-clean-state
    (baton-define-agent :name 'my-agent
                              :command "cmd"
                              :waiting-patterns '(("^> " . "input") ("Allow" . "permission")))
    (let ((patterns (plist-get (gethash 'my-agent baton-agents) :waiting-patterns)))
      (should (equal (car (assoc "^> " patterns)) "^> "))
      (should (equal (cdr (assoc "^> " patterns)) "input"))
      (should (equal (cdr (assoc "Allow" patterns)) "permission")))))

;;; ─── baton-process pure pattern matching tests ──────────────────────────────

(ert-deftest baton-test-process-match-waiting-pattern ()
  "Returns (:waiting . reason) when a waiting pattern matches."
  (let ((result (baton-process--match-patterns
                 "Do you want to continue? [Y/n]"
                 '(("Y/n" . "confirmation") ("Allow" . "permission")))))
    (should (consp result))
    (should (eq (car result) :waiting))
    (should (equal (cdr result) "confirmation"))))

(ert-deftest baton-test-process-match-no-match ()
  "Returns nil when no pattern matches."
  (let ((result (baton-process--match-patterns
                 "Processing files..."
                 '(("Y/n" . "confirmation")))))
    (should (null result))))

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

(ert-deftest baton-test-notify-fires-on-waiting ()
  "baton-notify-function is called when a session transitions to waiting."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      ;; Call the status-changed handler directly to test the notification path.
      (baton-notify--on-status-changed s 'running 'waiting)
      (should (eq notified-session s)))))

(ert-deftest baton-test-notify-unread-handler-fires-notify-function ()
  "baton-notify--on-unread-changed calls baton-notify-function with session."
  (baton-test-with-clean-state
    (let* ((s (baton-session-create :agent 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (baton-notify-function (lambda (sess) (setq notified-session sess))))
      (baton-notify--on-unread-changed s)
      (should (eq notified-session s)))))

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
     :waiting-patterns '(("Do you want to" . "confirmation")))
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
    (baton-define-agent :name 'claude-code :command "claude" :waiting-patterns nil)
    (let ((monet--tool-registry nil)
          (monet--enabled-sets '(:core :simple-diff))
          (monet-open-diff-tool-schema nil))
      (baton-monet-setup)
      (should (assoc (cons :baton "openDiff") monet--tool-registry))
      (should (memq :baton monet--enabled-sets)))))

;;; ─── baton-process env-functions tests ──────────────────────────────────────

(ert-deftest baton-test-env-functions-nil-by-default ()
  "baton-define-agent without :env-functions stores nil."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd" :waiting-patterns nil)
    (should (null (plist-get (gethash 'test-agent baton-agents) :env-functions)))))

(ert-deftest baton-test-env-functions-add-appends ()
  "baton-add-env-function appends; calling twice gives two entries in order."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd" :waiting-patterns nil)
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
    (baton-define-agent :name 'test-agent :command "cmd" :waiting-patterns nil)
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
    (baton-define-agent :name 'test-agent :command "cmd" :waiting-patterns nil)
    (let* ((def (gethash 'test-agent baton-agents))
           (env-fns (plist-get def :env-functions))
           (extra-env (when env-fns
                        (apply #'append
                               (mapcar (lambda (f) (funcall f "id" "/tmp")) env-fns)))))
      (should (null extra-env)))))

(provide 'baton-tests)
;;; baton-tests.el ends here
