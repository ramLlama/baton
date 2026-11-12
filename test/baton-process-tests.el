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
  "`baton-define-agent' stores the definition at the symbol key."
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
  "`baton-process--state-tick' writes :state metadata when status changes."
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

;;; ─── user input resets status ──────────────────────────────────────────────

(ert-deftest baton-test-on-input-ghostel-non-printing-key-resets-running ()
  "RET, arrows and other non-printing keys in ghostel count as input.
Approving a permission prompt is a RET; it must clear `waiting'."
  (baton-test-with-clean-state
    (let ((s (baton-session-create :agent 'claude-code :command "claude"
                                   :directory "/tmp"))
          (baton-terminal-backend 'ghostel)
          (this-command 'ghostel--send-event))
      (baton-session-set-status s 'waiting "permission")
      (with-temp-buffer
        (setq-local baton--current-session s)
        (baton-process--on-input))
      (should (eq (baton--session-status s) 'running)))))

;;; ─── :output-ignore-regexp tests ────────────────────────────────────────────

(defun baton-test--settle (session)
  "Tick SESSION's watcher, then tick again as if its output has been quiet."
  (baton-process--state-tick session)
  (setf (baton--session-metadata session)
        (plist-put (baton--session-metadata session)
                   :last-output-time (- (float-time) 10.0)))
  (baton-process--state-tick session))

(defun baton-test--replace-buffer (buf text)
  "Replace BUF's contents with TEXT."
  (with-current-buffer buf (erase-buffer) (insert text)))

(defmacro baton-test--with-ignore-agent (session buf &rest body)
  "Run BODY with SESSION waiting on agent `blink-agent' showing BUF.
The agent ignores a leading \"* \" or \"  \" and always reports waiting."
  (declare (indent 2))
  `(baton-test-with-clean-state
     (baton-define-agent
      :name 'blink-agent :command "cmd" :status-function-trigger :periodic
      :output-ignore-regexp "^[* ] "
      :status-function (lambda (_s) '(waiting . "prompt")))
     (let ((,session (baton-session-create :agent 'blink-agent :command "cmd"
                                           :directory "/tmp"))
           (,buf (generate-new-buffer " *baton-test-ignore*")))
       (unwind-protect
           (progn
             (baton-test--replace-buffer ,buf "* Waiting on tool\nAllow?")
             (setf (baton--session-buffer ,session) ,buf)
             (baton-test--settle ,session)
             (should (eq (baton--session-status ,session) 'waiting))
             ,@body)
         (kill-buffer ,buf)))))

(ert-deftest baton-test-output-ignore-regexp-masks-cosmetic-change ()
  "Output changes confined to ignored text do not reset waiting to running."
  (baton-test--with-ignore-agent s buf
    (baton-test--replace-buffer buf "  Waiting on tool\nAllow?")
    (baton-process--state-tick s)
    (should (eq (baton--session-status s) 'waiting))))

(ert-deftest baton-test-output-ignore-regexp-keeps-real-change ()
  "Output changes outside ignored text still mark the session running."
  (baton-test--with-ignore-agent s buf
    (baton-test--replace-buffer buf "* Waiting on tool\nDone.")
    (baton-process--state-tick s)
    (should (eq (baton--session-status s) 'running))))

;;; ─── built-in claude-code status detection ─────────────────────────────────

(defconst baton-test--claude-idle-screen
  "● Here are the numbers.

✻ Worked for 18s · done 8:32 PM

────────────────────────────────────────
❯ \n────────────────────────────────────────
  ⏵⏵ auto mode on (shift+tab to cycle)
"
  "Claude Code (2.1.322, fullscreen) at its input prompt after a turn.")

(defconst baton-test--claude-permission-screen
  "● Waiting 8 seconds then writing hi to out.txt
────────────────────────────────────────
 Bash command
 sleep 8 && echo hi > out.txt
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to /tmp/proj from this project
   4. No
 Esc to cancel · Tab to amend
"
  "Claude Code (2.1.322, fullscreen) showing a Bash permission prompt.")

(defun baton-test--builtin-claude-code-settled-status (text &optional blink-text)
  "Return the built-in claude-code agent's settled status showing TEXT.
When BLINK-TEXT is non-nil, the buffer then changes to it for one more tick."
  (let ((def (gethash 'claude-code baton-agents)))
    (baton-test-with-clean-state
      (puthash 'claude-code def baton-agents)
      (let ((s (baton-session-create :agent 'claude-code :command "claude"
                                     :directory "/tmp"))
            (buf (generate-new-buffer " *baton-test-claude*")))
        (unwind-protect
            (progn
              (baton-test--replace-buffer buf text)
              (setf (baton--session-buffer s) buf)
              (baton-test--settle s)
              (when blink-text
                (baton-test--replace-buffer buf blink-text)
                (baton-process--state-tick s))
              (baton--session-status s))
          (kill-buffer buf))))))

(ert-deftest baton-test-claude-code-idle-at-prompt ()
  "Claude Code at its input prompt after a turn is idle, not waiting."
  (should (eq (baton-test--builtin-claude-code-settled-status
               baton-test--claude-idle-screen)
              'idle)))

(ert-deftest baton-test-claude-code-permission-prompt-waits ()
  "Claude Code showing a permission prompt is waiting."
  (should (eq (baton-test--builtin-claude-code-settled-status
               baton-test--claude-permission-screen)
              'waiting)))

(ert-deftest baton-test-claude-code-permission-prompt-ignores-blink ()
  "The blinking tool-status glyph does not flip a permission prompt to running."
  (should (eq (baton-test--builtin-claude-code-settled-status
               baton-test--claude-permission-screen
               (concat "  " (substring baton-test--claude-permission-screen 2)))
              'waiting)))

;;; ─── baton-new spawn failure ────────────────────────────────────────────────

(ert-deftest baton-test-new-spawn-failure-removes-session ()
  "A failing spawn propagates its error and leaves no registered session."
  (baton-test-with-clean-state
    (baton-define-agent :name 'fail-agent :command "cmd"
                        :status-function-trigger :periodic)
    (cl-letf (((symbol-function 'baton-process-spawn)
               (lambda (_s) (user-error "Spawn refused")))
              ((symbol-function 'pop-to-buffer) #'ignore))
      (should-error (baton-new "fail-agent" "/repo") :type 'user-error)
      (should (null (baton-session-list))))))

;; Exercises the real `baton-process-spawn' up to the terminal backend.
(ert-deftest baton-test-new-terminal-failure-kills-buffer ()
  "A terminal backend failure leaves neither a session nor its buffer."
  (baton-test-with-clean-state
    (baton-define-agent :name 'term-fail-agent :command "cmd"
                        :status-function-trigger :periodic)
    (cl-letf (((symbol-function 'baton-term-spawn-in-buffer)
               (lambda (&rest _) (error "Terminal failed")))
              ((symbol-function 'pop-to-buffer) #'ignore))
      (should-error (baton-new "term-fail-agent" "/tmp" "tf-1"))
      (should (null (baton-session-list)))
      (should-not (get-buffer "*baton:tf-1*")))))

;;; ─── baton-process-spawn environment inheritance tests ──────────────────────

(ert-deftest baton-test-spawn-inherits-buffer-local-process-environment ()
  "`process-environment' is inherited from the calling buffer at spawn time.
Covers the envrc.el/direnv scenario: envrc.el sets `process-environment'
buffer-locally in project buffers; baton-process-spawn must capture that value
before switching to the new vterm buffer."
  (baton-test-with-clean-state
    (baton-define-agent :name 'spawn-env-agent :command "true"
                        :status-function-trigger :periodic)
    (let* ((captured-env nil)
           (session (baton-session-create :agent 'spawn-env-agent
                                          :command "true"
                                          :directory "/tmp"))
           ;; Simulates a direnv-managed project buffer where envrc.el has
           ;; injected vars into the buffer-local process-environment.
           (caller-buf (get-buffer-create " *baton-test-envrc-caller*")))
      (unwind-protect
          (progn
            (with-current-buffer caller-buf
              (setq-local process-environment
                          (cons "BATON_TEST_DIRENV_VAR=from-envrc"
                                process-environment)))
            ;; Mock vterm so the test runs without a real terminal.
            (cl-letf (((symbol-function 'require)
                       (lambda (feat &rest args)
                         (unless (eq feat 'vterm) (apply #'require feat args))))
                      ((symbol-function 'vterm-mode)
                       (lambda () (setq captured-env process-environment)))
                      ((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'baton-process--start-watcher) #'ignore))
              (let ((baton-terminal-backend 'vterm))
                (with-current-buffer caller-buf
                  (baton-process-spawn session)))))
        (kill-buffer caller-buf)
        (when-let* ((buf (baton--session-buffer session)))
          (when (buffer-live-p buf) (kill-buffer buf))))
      (should (member "BATON_TEST_DIRENV_VAR=from-envrc" captured-env)))))

(ert-deftest baton-test-spawn-extra-env-survives-envrc-caller ()
  "Agent extra-env reaches the spawn when the caller's env is buffer-local.
Covers the envrc.el/direnv scenario: the calling buffer has a buffer-local
`process-environment'.  Regression: a plain `setq' during spawn wrote that
buffer-local binding instead of the default value the terminal buffer reads,
so extra-env (monet ports etc.) was dropped across the buffer switch and the
caller's environment was polluted with per-session vars."
  (baton-test-with-clean-state
    (baton-define-agent :name 'spawn-extra-env-agent :command "true"
                        :status-function-trigger :periodic
                        :env-functions
                        (list (lambda (_name _dir)
                                '(:env ("BATON_TEST_EXTRA_VAR=from-agent")))))
    (let* ((captured-env nil)
           (session (baton-session-create :agent 'spawn-extra-env-agent
                                          :command "true"
                                          :directory "/tmp"))
           ;; Simulates a direnv-managed project buffer where envrc.el has
           ;; injected vars into the buffer-local process-environment.
           (caller-buf (get-buffer-create " *baton-test-envrc-extra-caller*")))
      (unwind-protect
          (progn
            (with-current-buffer caller-buf
              (setq-local process-environment
                          (cons "BATON_TEST_DIRENV_VAR=from-envrc"
                                process-environment)))
            ;; Mock vterm so the test runs without a real terminal.
            (cl-letf (((symbol-function 'require)
                       (lambda (feat &rest args)
                         (unless (eq feat 'vterm) (apply #'require feat args))))
                      ((symbol-function 'vterm-mode)
                       (lambda () (setq captured-env process-environment)))
                      ((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'baton-process--start-watcher) #'ignore))
              (let ((baton-terminal-backend 'vterm))
                (with-current-buffer caller-buf
                  (baton-process-spawn session))))
            ;; Both the caller's direnv env and the agent extra-env reach the
            ;; spawned process.
            (should (member "BATON_TEST_DIRENV_VAR=from-envrc" captured-env))
            (should (member "BATON_TEST_EXTRA_VAR=from-agent" captured-env))
            ;; The caller's buffer-local env must not accumulate session vars.
            (with-current-buffer caller-buf
              (should-not (member "BATON_TEST_EXTRA_VAR=from-agent"
                                  process-environment))))
        (kill-buffer caller-buf)
        (when-let* ((buf (baton--session-buffer session)))
          (when (buffer-live-p buf) (kill-buffer buf)))))))

;;; ─── baton-process env-functions tests ──────────────────────────────────────

(ert-deftest baton-test-env-functions-nil-by-default ()
  "`baton-define-agent' without :env-functions stores nil."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd"
                        :status-function-trigger :periodic)
    (should (null (plist-get (gethash 'test-agent baton-agents) :env-functions)))))

(ert-deftest baton-test-env-functions-add-appends ()
  "`baton-add-env-function' appends; calling twice gives two entries in order."
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
  "`baton-add-env-function' is idempotent: adding the same fn twice gives one entry."
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
  "Nil :env-functions does not produce extra env vars."
  (baton-test-with-clean-state
    (baton-define-agent :name 'test-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let* ((def (gethash 'test-agent baton-agents))
           (env-fns (plist-get def :env-functions))
           (extra-env (when env-fns
                        (apply #'append
                               (mapcar (lambda (f) (funcall f "id" "/tmp")) env-fns)))))
      (should (null extra-env)))))

;;; ─── env aggregation (:env/:ports contract) tests ──────────────────────────

(ert-deftest baton-test-agent-env-plist-shape ()
  "Env-functions returning (:env … :ports …) aggregate both keys, in order."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'plist-agent :command "cmd" :status-function-trigger :periodic
     :env-functions (list (lambda (_k _d) '(:env ("A=1" "B=2") :ports (1234)))
                          (lambda (_k _d) '(:env ("C=3") :ports (5678)))))
    (let* ((s (baton-session-create :agent 'plist-agent :command "cmd" :directory "/tmp"))
           (result (baton-executor--agent-env s "/tmp")))
      (should (equal (plist-get result :env) '("A=1" "B=2" "C=3")))
      (should (equal (plist-get result :ports) '(1234 5678))))))

(ert-deftest baton-test-agent-env-rejects-bare-list ()
  "An env-function returning a bare \"VAR=VALUE\" list is an error."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'bare-list-agent :command "cmd" :status-function-trigger :periodic
     :env-functions (list (lambda (_k _d) '("A=1"))))
    (let ((s (baton-session-create :agent 'bare-list-agent :command "cmd" :directory "/tmp")))
      (should-error (baton-executor--agent-env s "/tmp")))))

(ert-deftest baton-test-agent-env-nil-contribution-allowed ()
  "An env-function returning nil contributes nothing without erroring."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'nil-agent :command "cmd" :status-function-trigger :periodic
     :env-functions (list (lambda (_k _d) nil)
                          (lambda (_k _d) '(:env ("A=1")))))
    (let* ((s (baton-session-create :agent 'nil-agent :command "cmd" :directory "/tmp"))
           (result (baton-executor--agent-env s "/tmp")))
      (should (equal (plist-get result :env) '("A=1")))
      (should (null (plist-get result :ports))))))

(ert-deftest baton-test-agent-env-ports-deduped ()
  "Duplicate ports declared by multiple env-functions aggregate uniquely."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'dup-agent :command "cmd" :status-function-trigger :periodic
     :env-functions (list (lambda (_k _d) '(:env ("A=1") :ports (1234)))
                          (lambda (_k _d) '(:env ("B=2") :ports (1234 5678)))))
    (let* ((s (baton-session-create :agent 'dup-agent :command "cmd" :directory "/tmp"))
           (result (baton-executor--agent-env s "/tmp")))
      (should (equal (plist-get result :ports) '(1234 5678))))))

(ert-deftest baton-test-agent-env-no-env-functions ()
  "An agent without env-functions yields empty env and ports."
  (baton-test-with-clean-state
    (baton-define-agent :name 'bare-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let* ((s (baton-session-create :agent 'bare-agent :command "cmd" :directory "/tmp"))
           (result (baton-executor--agent-env s "/tmp")))
      (should (null (plist-get result :env)))
      (should (null (plist-get result :ports))))))

(ert-deftest baton-test-agent-env-receives-name-and-dir ()
  "Env-functions are called with the session name and the given directory."
  (baton-test-with-clean-state
    (let (seen)
      (baton-define-agent
       :name 'args-agent :command "cmd" :status-function-trigger :periodic
       :env-functions (list (lambda (k d) (setq seen (list k d)) nil)))
      (let ((s (baton-session-create :agent 'args-agent :command "cmd"
                                     :directory "/tmp" :name "my-session")))
        (baton-executor--agent-env s "/elsewhere")
        (should (equal seen '("my-session" "/elsewhere")))))))

;;; ─── built-in claude-code agent env ────────────────────────────────────────

(defun baton-test--builtin-claude-code-env (fullscreen)
  "Return the built-in claude-code agent's aggregate :env.
FULLSCREEN is bound as `baton-claude-code-fullscreen' during evaluation."
  (let ((def (gethash 'claude-code baton-agents)))
    (baton-test-with-clean-state
      (puthash 'claude-code def baton-agents)
      (let ((baton-claude-code-fullscreen fullscreen)
            (s (baton-session-create :agent 'claude-code :command "claude"
                                     :directory "/tmp")))
        (plist-get (baton-executor--agent-env s "/tmp") :env)))))

(ert-deftest baton-test-claude-code-fullscreen-enabled ()
  "Claude Code sessions get the fullscreen renderer env when enabled."
  (should (member "CLAUDE_CODE_NO_FLICKER=1"
                  (baton-test--builtin-claude-code-env t))))

(ert-deftest baton-test-claude-code-fullscreen-disabled ()
  "Claude Code sessions get no fullscreen renderer env when disabled."
  (should-not (cl-some (lambda (s) (string-prefix-p "CLAUDE_CODE_NO_FLICKER=" s))
                       (baton-test--builtin-claude-code-env nil))))

;;; ─── executor dispatch tests ───────────────────────────────────────────────

(ert-deftest baton-test-session-executor-defaults-to-exec ()
  "`baton-session-create' defaults the executor slot to `exec'."
  (baton-test-with-clean-state
    (baton-define-agent :name 'ex-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let ((s (baton-session-create :agent 'ex-agent :command "cmd" :directory "/tmp")))
      (should (eq (baton--session-executor s) 'exec)))))

(ert-deftest baton-test-exec-resolve-returns-session-fields ()
  "The `exec' executor resolves to the session's own directory and command."
  (baton-test-with-clean-state
    (baton-define-agent :name 'ex-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let* ((s (baton-session-create :agent 'ex-agent :command "my-cmd --flag"
                                    :directory "/tmp"))
           (resolved (baton-executor--resolve 'exec s)))
      (should (equal (plist-get resolved :directory) "/tmp"))
      (should (equal (plist-get resolved :command) "my-cmd --flag"))
      (should (null (plist-get resolved :extra-env))))))

(ert-deftest baton-test-exec-resolve-includes-agent-env ()
  "The `exec' executor exposes aggregated agent env as :extra-env, ignoring ports."
  (baton-test-with-clean-state
    (baton-define-agent
     :name 'ex-env-agent :command "cmd" :status-function-trigger :periodic
     :env-functions (list (lambda (_k _d) '(:env ("PORT_VAR=1234") :ports (1234)))
                          (lambda (_k _d) '(:env ("OTHER=x")))))
    (let* ((s (baton-session-create :agent 'ex-env-agent :command "cmd" :directory "/tmp"))
           (resolved (baton-executor--resolve 'exec s)))
      (should (equal (plist-get resolved :extra-env) '("PORT_VAR=1234" "OTHER=x"))))))

(ert-deftest baton-test-exec-teardown-default-noop ()
  "The default `baton-executor--teardown' method is a no-op."
  (baton-test-with-clean-state
    (baton-define-agent :name 'ex-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let ((s (baton-session-create :agent 'ex-agent :command "cmd" :directory "/tmp")))
      (should (null (baton-executor--teardown 'exec s))))))

(defvar baton-test--teardown-calls nil
  "Session names captured by the test executor's teardown method.")

(cl-defmethod baton-executor--teardown ((_executor (eql baton-test--executor)) session)
  "Record SESSION's name for executor-dispatch assertions."
  (push (baton--session-name session) baton-test--teardown-calls))

(ert-deftest baton-test-teardown-dispatches-on-executor ()
  "Session kill dispatches teardown on the session's executor symbol."
  (baton-test-with-clean-state
    (baton-define-agent :name 'td-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let ((baton-test--teardown-calls nil)
          (baton-session-killed-hook (list #'baton-executor--teardown-on-kill)))
      (let ((s (baton-session-create :agent 'td-agent :command "cmd"
                                     :directory "/tmp" :name "td-1"
                                     :executor 'baton-test--executor)))
        (baton-session-kill s)
        (should (equal baton-test--teardown-calls '("td-1")))))))

(ert-deftest baton-test-teardown-hook-registered ()
  "Loading baton-executor registers the executor-teardown dispatch globally."
  (should (memq #'baton-executor--teardown-on-kill baton-session-killed-hook)))

;;; ─── baton-process-spawn executor regression tests ─────────────────────────

(ert-deftest baton-test-spawn-applies-agent-env-once ()
  "Spawn injects agent env, evaluating each env-function exactly once."
  (baton-test-with-clean-state
    (let ((eval-count 0)
          (captured-env nil))
      (baton-define-agent
       :name 'spawn-once-agent :command "true" :status-function-trigger :periodic
       :env-functions (list (lambda (_k _d)
                              (cl-incf eval-count)
                              '(:env ("BATON_TEST_ONCE=yes") :ports (4321)))))
      (let ((session (baton-session-create :agent 'spawn-once-agent
                                           :command "true" :directory "/tmp")))
        (unwind-protect
            (cl-letf (((symbol-function 'require)
                       (lambda (feat &rest args)
                         (unless (eq feat 'vterm) (apply #'require feat args))))
                      ((symbol-function 'vterm-mode)
                       (lambda () (setq captured-env process-environment)))
                      ((symbol-function 'pop-to-buffer) #'ignore)
                      ((symbol-function 'baton-process--start-watcher) #'ignore))
              (let ((baton-terminal-backend 'vterm))
                (baton-process-spawn session)))
          (when-let* ((buf (baton--session-buffer session)))
            (when (buffer-live-p buf) (kill-buffer buf))))
        (should (member "BATON_TEST_ONCE=yes" captured-env))
        (should (= 1 eval-count))))))

;;; ─── baton-process-session-tail tests ──────────────────────────────────────

(ert-deftest baton-test-session-tail-live-buffer ()
  "`baton-process-session-tail' returns buffer text when buffer is live."
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
  "`baton-process-session-tail' returns empty string when buffer is dead."
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
  "`baton-process--state-tick' does not call :status-function for :on-event sessions."
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
