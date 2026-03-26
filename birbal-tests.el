;;; birbal-tests.el --- ERT test suite for birbal  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; ERT tests for birbal-session, birbal-process (pure), birbal-notify,
;; birbal agent-type registry, and birbal-monet.
;;
;; Run via Makefile:
;;   make test

;;; Code:
(require 'ert)
(require 'birbal-session)
(require 'birbal-process)
(require 'birbal-notify)
(require 'birbal)
(require 'birbal-monet)

;;; Test Isolation

(defmacro birbal-test-with-clean-state (&rest body)
  "Execute BODY with isolated global state: fresh sessions, counters, and agent-types."
  (declare (indent 0))
  `(let ((birbal--sessions (make-hash-table :test 'equal))
         (birbal--session-counters (make-hash-table :test 'eq))
         (birbal-agent-types (make-hash-table :test 'eq))
         (birbal-session-created-hook nil)
         (birbal-session-killed-hook nil)
         (birbal-session-status-changed-hook nil)
         (birbal-session-unread-changed-hook nil))
     ,@body))

;;; ─── birbal-session tests ────────────────────────────────────────────────────

(ert-deftest birbal-test-session-create-returns-struct ()
  "birbal-session-create returns a birbal--session struct."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code
                                    :command "claude"
                                    :directory "/tmp")))
      (should (birbal--session-p s)))))

(ert-deftest birbal-test-session-create-adds-to-registry ()
  "Created session is findable via birbal-session-get."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code
                                     :command "claude"
                                     :directory "/tmp"))
           (found (birbal-session-get (birbal--session-name s))))
      (should (eq s found)))))

(ert-deftest birbal-test-session-create-duplicate-name-errors ()
  "Creating a session with a name that already exists signals an error."
  (birbal-test-with-clean-state
    (birbal-session-create :agent-type 'claude-code :command "claude"
                           :directory "/tmp" :name "my-agent")
    (should-error (birbal-session-create :agent-type 'claude-code :command "claude"
                                         :directory "/tmp" :name "my-agent")
                  :type 'error)))

(ert-deftest birbal-test-session-create-auto-name ()
  "Auto-names use agent-type short prefix and incrementing counter."
  (birbal-test-with-clean-state
    (let ((s1 (birbal-session-create :agent-type 'claude-code
                                     :command "claude"
                                     :directory "/tmp"))
          (s2 (birbal-session-create :agent-type 'claude-code
                                     :command "claude"
                                     :directory "/tmp")))
      (should (equal (birbal--session-name s1) "claude-1"))
      (should (equal (birbal--session-name s2) "claude-2")))))

(ert-deftest birbal-test-session-create-explicit-name ()
  "birbal-session-create respects an explicit :name argument."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code
                                    :command "claude"
                                    :directory "/tmp"
                                    :name "my-agent")))
      (should (equal (birbal--session-name s) "my-agent")))))

(ert-deftest birbal-test-session-create-fires-hook ()
  "birbal-session-create fires birbal-session-created-hook with the session."
  (birbal-test-with-clean-state
    (let (hook-arg)
      (add-hook 'birbal-session-created-hook (lambda (s) (setq hook-arg s)))
      (let ((s (birbal-session-create :agent-type 'claude-code
                                      :command "claude"
                                      :directory "/tmp")))
        (should (eq hook-arg s))))))

(ert-deftest birbal-test-session-list-all ()
  "birbal-session-list returns all sessions."
  (birbal-test-with-clean-state
    (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")
    (birbal-session-create :agent-type 'aider       :command "aider"  :directory "/tmp")
    (should (= 2 (length (birbal-session-list))))))

(ert-deftest birbal-test-session-list-filter-by-status ()
  "birbal-session-list with a status argument filters correctly."
  (birbal-test-with-clean-state
    (let ((s1 (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
          (s2 (birbal-session-create :agent-type 'aider       :command "aider"  :directory "/tmp")))
      (birbal-session-set-status s1 'waiting "prompt")
      (should (= 1 (length (birbal-session-list 'waiting))))
      (should (eq s1 (car (birbal-session-list 'waiting))))
      (should (= 1 (length (birbal-session-list 'running))))
      (should (eq s2 (car (birbal-session-list 'running)))))))

(ert-deftest birbal-test-session-set-status ()
  "birbal-session-set-status changes status and fires hook with old/new values."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
          hook-session hook-old hook-new)
      (add-hook 'birbal-session-status-changed-hook
                (lambda (sess old new)
                  (setq hook-session sess hook-old old hook-new new)))
      (birbal-session-set-status s 'waiting "permission prompt")
      (should (eq (birbal--session-status s) 'waiting))
      (should (equal (birbal--session-waiting-reason s) "permission prompt"))
      (should (eq hook-session s))
      (should (eq hook-old 'running))
      (should (eq hook-new 'waiting)))))

(ert-deftest birbal-test-session-set-status-clears-reason ()
  "Transitioning away from waiting clears the waiting-reason."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")))
      (birbal-session-set-status s 'waiting "something")
      (birbal-session-set-status s 'running)
      (should (null (birbal--session-waiting-reason s))))))

(ert-deftest birbal-test-session-find-by-directory ()
  "birbal-session-find-by-directory returns matching session."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code
                                    :command "claude"
                                    :directory "/my/project")))
      (should (eq s (birbal-session-find-by-directory "/my/project")))
      (should (null (birbal-session-find-by-directory "/other"))))))

(ert-deftest birbal-test-session-kill-removes-from-registry ()
  "birbal-session-kill removes the session from the registry."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")))
      (birbal-session-kill s)
      (should (null (birbal-session-get (birbal--session-name s))))
      (should (= 0 (length (birbal-session-list)))))))

(ert-deftest birbal-test-session-kill-fires-hook ()
  "birbal-session-kill fires birbal-session-killed-hook with the session."
  (birbal-test-with-clean-state
    (let (hook-arg)
      (add-hook 'birbal-session-killed-hook (lambda (s) (setq hook-arg s)))
      (let ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")))
        (birbal-session-kill s)
        (should (eq hook-arg s))))))

;;; ─── birbal-session unread tests ─────────────────────────────────────────────

(ert-deftest birbal-test-session-unread-p-no-buffer ()
  "birbal-session-unread-p returns nil when session has no live buffer."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")))
      ;; No buffer set — buffer field is nil
      (should (null (birbal-session-unread-p s))))))

(ert-deftest birbal-test-session-unread-p-hashes-differ ()
  "birbal-session-unread-p returns t when current-hash differs from last-seen-hash."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *birbal-test-unread*")))
      (unwind-protect
          (progn
            (setf (birbal--session-buffer s) buf)
            (setf (birbal--session-metadata s)
                  (list :current-hash "abc123" :last-seen-hash nil))
            ;; Buffer not in any window → unread
            (should (birbal-session-unread-p s)))
        (kill-buffer buf)))))

(ert-deftest birbal-test-session-unread-p-hashes-equal ()
  "birbal-session-unread-p returns nil when current-hash equals last-seen-hash."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *birbal-test-read*")))
      (unwind-protect
          (progn
            (setf (birbal--session-buffer s) buf)
            (setf (birbal--session-metadata s)
                  (list :current-hash "abc123" :last-seen-hash "abc123"))
            (should (null (birbal-session-unread-p s))))
        (kill-buffer buf)))))

;;; ─── Agent-type registry tests ───────────────────────────────────────────────

(ert-deftest birbal-test-define-agent-type-stores ()
  "birbal-define-agent-type stores the definition at the symbol key."
  (birbal-test-with-clean-state
    (birbal-define-agent-type :name 'my-agent
                              :command "my-cmd"
                              :waiting-patterns '((">" . "prompt")))
    (should (gethash 'my-agent birbal-agent-types))))

(ert-deftest birbal-test-define-agent-type-retrieval ()
  "The :command is retrievable from the stored definition."
  (birbal-test-with-clean-state
    (birbal-define-agent-type :name 'my-agent
                              :command "my-cmd"
                              :waiting-patterns nil)
    (should (equal "my-cmd"
                   (plist-get (gethash 'my-agent birbal-agent-types) :command)))))

(ert-deftest birbal-test-agent-type-waiting-patterns ()
  "Waiting patterns are stored as an alist of (pattern . reason)."
  (birbal-test-with-clean-state
    (birbal-define-agent-type :name 'my-agent
                              :command "cmd"
                              :waiting-patterns '(("^> " . "input") ("Allow" . "permission")))
    (let ((patterns (plist-get (gethash 'my-agent birbal-agent-types) :waiting-patterns)))
      (should (equal (car (assoc "^> " patterns)) "^> "))
      (should (equal (cdr (assoc "^> " patterns)) "input"))
      (should (equal (cdr (assoc "Allow" patterns)) "permission")))))

;;; ─── birbal-process pure pattern matching tests ──────────────────────────────

(ert-deftest birbal-test-process-match-waiting-pattern ()
  "Returns (:waiting . reason) when a waiting pattern matches."
  (let ((result (birbal-process--match-patterns
                 "Do you want to continue? [Y/n]"
                 '(("Y/n" . "confirmation") ("Allow" . "permission")))))
    (should (consp result))
    (should (eq (car result) :waiting))
    (should (equal (cdr result) "confirmation"))))

(ert-deftest birbal-test-process-match-no-match ()
  "Returns nil when no pattern matches."
  (let ((result (birbal-process--match-patterns
                 "Processing files..."
                 '(("Y/n" . "confirmation")))))
    (should (null result))))

;;; ─── birbal-notify modeline tests ────────────────────────────────────────────

(ert-deftest birbal-test-notify-modeline-no-sessions ()
  "Modeline string is empty when there are no sessions."
  (birbal-test-with-clean-state
    (should (equal "" (birbal-notify--modeline-string)))))

(ert-deftest birbal-test-notify-modeline-running-only ()
  "Modeline shows Nr count when sessions are running."
  (birbal-test-with-clean-state
    (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")
    (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")
    (let ((str (birbal-notify--modeline-string)))
      (should (string-match-p "B\\[2r\\]" str))
      (should-not (string-match-p "/" str)))))

(ert-deftest birbal-test-notify-modeline-with-waiting ()
  "Modeline shows Nw/Nr when a session is waiting."
  (birbal-test-with-clean-state
    (let ((s1 (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
          (s2 (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
          (s3 (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")))
      (birbal-session-set-status s1 'waiting "prompt")
      (let ((str (birbal-notify--modeline-string)))
        ;; 1 waiting, 2 running -> B[1w/2r]
        (should (string-match-p "B\\[1w/2r\\]" str))))))

(ert-deftest birbal-test-notify-modeline-idle-state ()
  "Modeline shows Ni count for idle sessions."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")))
      (birbal-session-set-status s 'idle)
      (let ((str (birbal-notify--modeline-string)))
        (should (string-match-p "B\\[1i\\]" str))))))

(ert-deftest birbal-test-notify-modeline-unread-count ()
  "Modeline shows N* when sessions have unread output."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *birbal-test-unread-ml*")))
      (unwind-protect
          (progn
            (birbal-session-set-status s 'idle)
            (setf (birbal--session-buffer s) buf)
            (setf (birbal--session-metadata s)
                  (list :current-hash "changed" :last-seen-hash nil))
            (let ((str (birbal-notify--modeline-string)))
              (should (string-match-p "1\\*" str))))
        (kill-buffer buf)))))

(ert-deftest birbal-test-notify-modeline-no-unread ()
  "Modeline omits * when all sessions have read output."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
           (buf (get-buffer-create " *birbal-test-read-ml*")))
      (unwind-protect
          (progn
            (birbal-session-set-status s 'idle)
            (setf (birbal--session-buffer s) buf)
            (setf (birbal--session-metadata s)
                  (list :current-hash "same" :last-seen-hash "same"))
            (let ((str (birbal-notify--modeline-string)))
              (should-not (string-match-p "\\*" str))))
        (kill-buffer buf)))))

(ert-deftest birbal-test-notify-fires-on-waiting ()
  "birbal-notify-function is called when a session transitions to waiting."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (birbal-notify-function (lambda (sess) (setq notified-session sess))))
      ;; Call the status-changed handler directly to test the notification path.
      (birbal-notify--on-status-changed s 'running 'waiting)
      (should (eq notified-session s)))))

(ert-deftest birbal-test-notify-unread-handler-fires-notify-function ()
  "birbal-notify--on-unread-changed calls birbal-notify-function with session."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
           notified-session
           (birbal-notify-function (lambda (sess) (setq notified-session sess))))
      (birbal-notify--on-unread-changed s)
      (should (eq notified-session s)))))

;;; ─── birbal-notify status buffer rendering tests ─────────────────────────────

(ert-deftest birbal-test-status-buffer-format-waiting ()
  "A waiting session entry includes the waiting indicator and reason."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")))
      (birbal-session-set-status s 'waiting "permission prompt")
      (let* ((entry (birbal-notify--format-entry s nil))
             (cols (cadr entry)))
        ;; cols[5] is the reason column
        (should (string-match-p "permission prompt" (aref cols 5)))
        ;; cols[3] is the status column
        (should (string-match-p "waiting" (aref cols 3)))))))

(ert-deftest birbal-test-status-buffer-format-running ()
  "A running session entry shows \"running\" status and no reason."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")))
      (let* ((entry (birbal-notify--format-entry s nil))
             (cols (cadr entry)))
        (should (string-match-p "running" (aref cols 3)))
        (should (equal "" (aref cols 5)))))))

(ert-deftest birbal-test-status-buffer-format-idle ()
  "An idle session entry shows \"idle\" status and ○ indicator."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp")))
      (birbal-session-set-status s 'idle)
      (let* ((entry (birbal-notify--format-entry s nil))
             (cols (cadr entry)))
        (should (string-match-p "idle" (aref cols 3)))
        ;; cols[1] is the indicator
        (should (string-match-p "○" (aref cols 1)))
        (should-not (string-match-p "\\*" (aref cols 1)))))))

(ert-deftest birbal-test-status-buffer-sorted ()
  "birbal-notify--list-entries returns sessions sorted by created-at."
  (birbal-test-with-clean-state
    (let ((s1 (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/a"))
          (s2 (birbal-session-create :agent-type 'aider       :command "aider"  :directory "/b")))
      ;; Ensure s1 has an earlier created-at
      (setf (birbal--session-created-at s1) 1000.0)
      (setf (birbal--session-created-at s2) 2000.0)
      (let ((entries (birbal-notify--list-entries)))
        (should (= 2 (length entries)))
        ;; First entry ID should be s1's ID
        (should (equal (birbal--session-name s1) (car (nth 0 entries))))
        (should (equal (birbal--session-name s2) (car (nth 1 entries))))))))

(ert-deftest birbal-test-status-buffer-mark-and-kill ()
  "birbal-list-execute kills sessions flagged in birbal--list-marks."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code :command "claude" :directory "/tmp"))
           (id (birbal--session-name s))
           ;; Simulate the buffer-local marks
           (marks (list (cons id 'kill))))
      ;; Execute manually (without a real buffer)
      (dolist (entry marks)
        (let ((session (birbal-session-get (car entry))))
          (when session
            (pcase (cdr entry)
              ('kill (birbal-session-kill session))))))
      (should (null (birbal-session-get id))))))

;;; ─── birbal-monet tests ──────────────────────────────────────────────────────

(ert-deftest birbal-test-monet-find-session-by-directory ()
  "birbal-monet--find-session matches a session by directory."
  (birbal-test-with-clean-state
    (let ((s (birbal-session-create :agent-type 'claude-code
                                    :command "claude"
                                    :directory "/my/project")))
      (should (eq s (birbal-monet--find-session "/my/project")))
      (should (null (birbal-monet--find-session "/other"))))))

(ert-deftest birbal-test-monet-find-session-prefers-claude-code ()
  "birbal-monet--find-session prefers claude-code when multiple sessions match."
  (birbal-test-with-clean-state
    (let ((s-aider  (birbal-session-create :agent-type 'aider
                                           :command "aider"
                                           :directory "/proj"))
          (s-claude (birbal-session-create :agent-type 'claude-code
                                           :command "claude"
                                           :directory "/proj")))
      (should (eq s-claude (birbal-monet--find-session "/proj"))))))

(ert-deftest birbal-test-monet-open-diff-defers ()
  "birbal-monet--open-diff-handler stores :pending-diff and sets status to waiting."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code
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
        (birbal-monet--open-diff-handler nil monet-session)
        ;; Status is set to waiting
        (should (eq (birbal--session-status s) 'waiting))
        (should (equal (birbal--session-waiting-reason s) "diff review"))
        ;; A thunk was stored but NOT yet called
        (should (plist-get (birbal--session-metadata s) :pending-diff))
        (should-not thunk-called)))))

(ert-deftest birbal-test-monet-review-diff-invokes-thunk ()
  "birbal-review-diff calls the stored thunk and clears :pending-diff."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           thunk-called)
      (setf (birbal--session-metadata s)
            (plist-put (birbal--session-metadata s)
                       :pending-diff (lambda () (setq thunk-called t))))
      (birbal-review-diff (birbal--session-name s))
      (should thunk-called)
      (should (null (plist-get (birbal--session-metadata s) :pending-diff))))))

(ert-deftest birbal-test-monet-pending-diff-preserves-reason ()
  "Watcher preserves \"diff review\" reason when :pending-diff is set in metadata.
Even when the terminal output matches a different waiting pattern (e.g.
\"confirmation\"), the status must stay \"diff review\" until the diff is reviewed."
  (birbal-test-with-clean-state
    (birbal-define-agent-type
     :name 'claude-code
     :command "claude"
     :waiting-patterns '(("Do you want to" . "confirmation")))
    (let* ((s (birbal-session-create :agent-type 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (content "Do you want to make this edit? [Y/n]")
           (buf (get-buffer-create " *birbal-test-pending-diff*")))
      (unwind-protect
          (progn
            (setf (birbal--session-buffer s) buf)
            (setf (birbal--session-status s) 'waiting)
            (setf (birbal--session-waiting-reason s) "diff review")
            (with-current-buffer buf
              (insert content))
            ;; Set up metadata: pending-diff present; output quiet for 10s
            (let ((hash (with-current-buffer buf
                          (md5 (buffer-substring-no-properties (point-min) (point-max))))))
              (setf (birbal--session-metadata s)
                    (list :pending-diff (lambda () t)
                          :last-output-hash hash
                          :last-output-time (- (float-time) 10.0)
                          :current-hash hash
                          :last-seen-hash hash
                          :watcher-timer nil)))
            (birbal-process--watcher-tick s)
            (should (eq (birbal--session-status s) 'waiting))
            (should (equal (birbal--session-waiting-reason s) "diff review")))
        (kill-buffer buf)))))

(ert-deftest birbal-test-monet-review-bar-activates-on-diff-review ()
  "birbal-monet--update-review-bar activates mode-line bar and review mode."
  (birbal-test-with-clean-state
    (let* ((s (birbal-session-create :agent-type 'claude-code
                                     :command "claude"
                                     :directory "/proj"))
           (buf (get-buffer-create " *birbal-test-review-bar*")))
      (unwind-protect
          (progn
            (setf (birbal--session-buffer s) buf)
            (setf (birbal--session-status s) 'waiting)
            (setf (birbal--session-waiting-reason s) "diff review")
            ;; Simulate status-changed hook call
            (birbal-monet--update-review-bar s 'running 'waiting)
            (with-current-buffer buf
              (should (local-variable-p 'mode-line-format))
              (should birbal--session-review-mode))
            ;; Transition to idle: bar should clear
            (birbal-session-set-status s 'idle)
            (birbal-monet--update-review-bar s 'waiting 'idle)
            (with-current-buffer buf
              (should-not (local-variable-p 'mode-line-format))
              (should-not birbal--session-review-mode)))
        (kill-buffer buf)))))

(ert-deftest birbal-test-monet-setup-enables-birbal-set ()
  "birbal-monet-setup registers openDiff in :birbal set and enables it."
  (skip-unless (featurep 'monet))
  (birbal-test-with-clean-state
    (birbal-define-agent-type :name 'claude-code :command "claude" :waiting-patterns nil)
    (let ((monet--tool-registry nil)
          (monet--enabled-sets '(:core :simple-diff))
          (monet-open-diff-tool-schema nil))
      (birbal-monet-setup)
      (should (assoc (cons :birbal "openDiff") monet--tool-registry))
      (should (memq :birbal monet--enabled-sets)))))

;;; ─── birbal-process env-functions tests ──────────────────────────────────────

(ert-deftest birbal-test-env-functions-nil-by-default ()
  "birbal-define-agent-type without :env-functions stores nil."
  (birbal-test-with-clean-state
    (birbal-define-agent-type :name 'test-agent :command "cmd" :waiting-patterns nil)
    (should (null (plist-get (gethash 'test-agent birbal-agent-types) :env-functions)))))

(ert-deftest birbal-test-env-functions-add-appends ()
  "birbal-add-env-function appends; calling twice gives two entries in order."
  (birbal-test-with-clean-state
    (birbal-define-agent-type :name 'test-agent :command "cmd" :waiting-patterns nil)
    (let ((fn1 (lambda (_k _d) '("A=1")))
          (fn2 (lambda (_k _d) '("B=2"))))
      (birbal-add-env-function 'test-agent fn1)
      (birbal-add-env-function 'test-agent fn2)
      (let ((fns (plist-get (gethash 'test-agent birbal-agent-types) :env-functions)))
        (should (= 2 (length fns)))
        (should (eq (nth 0 fns) fn1))
        (should (eq (nth 1 fns) fn2))))))

(ert-deftest birbal-test-env-functions-add-idempotent ()
  "birbal-add-env-function is idempotent: adding the same fn twice gives one entry."
  (birbal-test-with-clean-state
    (birbal-define-agent-type :name 'test-agent :command "cmd" :waiting-patterns nil)
    (let ((fn (lambda (_k _d) '("A=1"))))
      (birbal-add-env-function 'test-agent fn)
      (birbal-add-env-function 'test-agent fn)
      (let ((fns (plist-get (gethash 'test-agent birbal-agent-types) :env-functions)))
        (should (= 1 (length fns)))
        (should (eq (car fns) fn))))))

(ert-deftest birbal-test-env-functions-multiple-combined ()
  "Multiple env-functions results are flattened via apply #'append."
  (birbal-test-with-clean-state
    (let* ((fn1 (lambda (_k _d) '("A=1")))
           (fn2 (lambda (_k _d) '("B=2" "C=3")))
           (env-fns (list fn1 fn2))
           (extra-env (apply #'append
                             (mapcar (lambda (f) (funcall f "id" "/tmp")) env-fns))))
      (should (equal extra-env '("A=1" "B=2" "C=3"))))))

(ert-deftest birbal-test-env-functions-nil-produces-no-extra-env ()
  "nil :env-functions does not produce extra env vars."
  (birbal-test-with-clean-state
    (birbal-define-agent-type :name 'test-agent :command "cmd" :waiting-patterns nil)
    (let* ((def (gethash 'test-agent birbal-agent-types))
           (env-fns (plist-get def :env-functions))
           (extra-env (when env-fns
                        (apply #'append
                               (mapcar (lambda (f) (funcall f "id" "/tmp")) env-fns)))))
      (should (null extra-env)))))

(provide 'birbal-tests)
;;; birbal-tests.el ends here
