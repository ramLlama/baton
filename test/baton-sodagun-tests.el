;;; baton-sodagun-tests.el --- ERT tests for baton-sodagun  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; ERT tests for the sodagun CLI integration: JSON invocation wrapper,
;; worktree creation, and the worktree path through `baton-new'.
;; All tests stub the sodagun binary — no sandbox or git state is touched.

;;; Code:
(require 'ert)
(require 'baton-test-helpers)
(require 'baton-sodagun)
(require 'baton)

;;; ─── baton-sodagun--run tests ───────────────────────────────────────────────

(ert-deftest baton-test-sodagun-run-parses-json ()
  "`baton-sodagun--run' returns the parsed JSON object from stdout."
  (cl-letf (((symbol-function 'call-process)
             (lambda (_program _infile _destination _display &rest _args)
               (insert "{\"status\":\"ok\",\"rootdir\":\"/tmp/ws\"}\n")
               0)))
    (let ((result (baton-sodagun--run "git" "add-worktree" "feat")))
      (should (equal (alist-get 'rootdir result) "/tmp/ws")))))

(ert-deftest baton-test-sodagun-run-passes-global-flags ()
  "`baton-sodagun--run' invokes sodagun with --output json --quiet before ARGS."
  (let (seen-args)
    (cl-letf (((symbol-function 'call-process)
               (lambda (program _infile _destination _display &rest args)
                 (setq seen-args (cons program args))
                 (insert "{\"status\":\"ok\"}")
                 0)))
      (baton-sodagun--run "sandbox" "stop" "/tmp/ws")
      (should (equal seen-args
                     '("sodagun" "--output" "json" "--quiet"
                       "sandbox" "stop" "/tmp/ws"))))))

(ert-deftest baton-test-sodagun-run-skips-progress-noise ()
  "`baton-sodagun--run' parses the trailing JSON line even with leading noise."
  (cl-letf (((symbol-function 'call-process)
             (lambda (_program _infile _destination _display &rest _args)
               (insert "setup: cloning...\nsetup: done\n{\"status\":\"ok\",\"sandbox_name\":\"sb-1\"}\n")
               0)))
    (let ((result (baton-sodagun--run "sandbox" "start" "/tmp/ws")))
      (should (equal (alist-get 'sandbox_name result) "sb-1")))))

(ert-deftest baton-test-sodagun-run-errors-on-failure ()
  "`baton-sodagun--run' signals an error when sodagun exits non-zero."
  (cl-letf (((symbol-function 'call-process)
             (lambda (_program _infile _destination _display &rest _args)
               (insert "error: no such workspace")
               1)))
    (should-error (baton-sodagun--run "sandbox" "stop" "/nope"))))

;;; ─── baton-sodagun--add-worktree tests ──────────────────────────────────────

(defmacro baton-sodagun-test--with-rootdir (worktree-path &rest body)
  "Run BODY with a temp rootdir whose sodagun.json names WORKTREE-PATH.
The rootdir path is bound to `rootdir' within BODY."
  (declare (indent 1))
  `(let ((rootdir (make-temp-file "baton-sodagun-test-" t)))
     (unwind-protect
         (progn
           (with-temp-file (expand-file-name "sodagun.json" rootdir)
             (insert (format "{\"repo_path\":\"/repo\",\"branch\":\"feat\",\"worktree_path\":%S}"
                             ,worktree-path)))
           ,@body)
       (delete-directory rootdir t))))

(ert-deftest baton-test-sodagun-add-worktree-returns-paths ()
  "`baton-sodagun--add-worktree' returns (ROOTDIR . WORKTREE-PATH)."
  (baton-sodagun-test--with-rootdir "/work/feat"
    (let (run-args)
      (cl-letf (((symbol-function 'baton-sodagun--run)
                 (lambda (&rest args)
                   (setq run-args args)
                   `((status . "ok") (rootdir . ,rootdir)))))
        (let ((result (baton-sodagun--add-worktree "feat" "/repo")))
          (should (equal result (cons rootdir "/work/feat")))
          (should (equal run-args (list "git" "add-worktree" "feat" "/repo"))))))))

(ert-deftest baton-test-sodagun-add-worktree-passes-base ()
  "`baton-sodagun--add-worktree' forwards BASE as --base."
  (baton-sodagun-test--with-rootdir "/work/feat"
    (let (run-args)
      (cl-letf (((symbol-function 'baton-sodagun--run)
                 (lambda (&rest args)
                   (setq run-args args)
                   `((status . "ok") (rootdir . ,rootdir)))))
        (baton-sodagun--add-worktree "feat" "/repo" "origin/dev")
        (should (equal run-args
                       (list "git" "add-worktree" "feat" "/repo"
                             "--base" "origin/dev")))))))

(ert-deftest baton-test-sodagun-add-worktree-runs-created-hook ()
  "The worktree-created hook fires with (WORKTREE-PATH REPO BRANCH).
It runs only after the worktree passes validation."
  (baton-sodagun-test--with-rootdir "/work/feat"
    (let (hook-args)
      (cl-letf (((symbol-function 'baton-sodagun--run)
                 (lambda (&rest _args) `((status . "ok") (rootdir . ,rootdir)))))
        (let ((baton-sodagun-worktree-created-hook
               (list (lambda (&rest args) (setq hook-args args)))))
          (baton-sodagun--add-worktree "feat" "/repo" "origin/dev")
          (should (equal hook-args '("/work/feat" "/repo" "feat"))))))))

(ert-deftest baton-test-sodagun-add-worktree-errors-without-metadata ()
  "`baton-sodagun--add-worktree' fails fast when sodagun.json is missing."
  (let ((rootdir (make-temp-file "baton-sodagun-test-empty-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'baton-sodagun--run)
                   (lambda (&rest _args) `((status . "ok") (rootdir . ,rootdir)))))
          (should-error (baton-sodagun--add-worktree "feat" "/repo")))
      (delete-directory rootdir t))))

;;; ─── pure builder tests (net rules, attach command) ─────────────────────────

(ert-deftest baton-test-sodagun-net-rules ()
  "`baton-sodagun--net-rules' builds an allow@host egress rule per port."
  (should (equal (baton-sodagun--net-rules '(1234 5678))
                 '("allow@host:tcp:1234" "allow@host:tcp:5678")))
  (should (null (baton-sodagun--net-rules nil))))

(ert-deftest baton-test-sodagun-attach-command-bare ()
  "`baton-sodagun--attach-command' without env wraps the agent command."
  (cl-letf (((symbol-function 'baton-sodagun--executable) (lambda () "sodagun")))
    (should (equal (baton-sodagun--attach-command "/root" "claude")
                   "sodagun sandbox attach /root -- claude"))))

(ert-deftest baton-test-sodagun-attach-command-env ()
  "`baton-sodagun--attach-command' injects each env string via --env."
  (cl-letf (((symbol-function 'baton-sodagun--executable) (lambda () "sodagun")))
    (should (equal (baton-sodagun--attach-command "/root" "claude"
                                                  :env '("A=1" "B=2"))
                   (concat "sodagun sandbox attach /root"
                           " --env " (shell-quote-argument "A=1")
                           " --env " (shell-quote-argument "B=2")
                           " -- claude")))))

(ert-deftest baton-test-sodagun-attach-command-quotes ()
  "`baton-sodagun--attach-command' shell-quotes the rootdir and env values."
  (cl-letf (((symbol-function 'baton-sodagun--executable) (lambda () "sodagun")))
    (let ((cmd (baton-sodagun--attach-command "/my root" "claude"
                                              :env '("MSG=hello world"))))
      (should (string-match-p (regexp-quote (shell-quote-argument "/my root")) cmd))
      (should (string-match-p (regexp-quote (shell-quote-argument "MSG=hello world")) cmd)))))

(ert-deftest baton-test-sodagun-attach-command-absolute-binary ()
  "`baton-sodagun--attach-command' uses the absolute sodagun path.
The attach string runs through /bin/sh -c with Emacs's own PATH, which
may not include the directory the variable `exec-path' found sodagun in."
  (cl-letf (((symbol-function 'baton-sodagun--executable)
             (lambda () "/home/u/.cargo/bin/sodagun")))
    (should (string-prefix-p "/home/u/.cargo/bin/sodagun sandbox attach"
                             (baton-sodagun--attach-command "/root" "claude")))))

(ert-deftest baton-test-sodagun-attach-command-ports-wrap ()
  "With :ports, the in-guest command backgrounds one socat per port.
The sandbox accepts a single concurrent connection, so the forwarders
must ride the attach connection and the agent runs via exec in the same
wrapper shell."
  (cl-letf (((symbol-function 'baton-sodagun--executable) (lambda () "sodagun")))
    (let ((cmd (baton-sodagun--attach-command "/root" "claude"
                                              :env '("A=1")
                                              :ports '(1234 5678))))
      ;; Still a single attach invocation with env.
      (should (string-prefix-p "sodagun sandbox attach /root --env" cmd))
      ;; The guest payload is one sh -c token (host-quoted as a whole).
      (should (string-match-p " -- sh -c " cmd))
      ;; One socat bridge per port, backgrounded, then exec the agent —
      ;; matched in their host-quoted form.
      (dolist (port '(1234 5678))
        (should (string-match-p
                 (regexp-quote
                  (shell-quote-argument (baton-sodagun--guest-forward-command port)))
                 cmd)))
      (should (string-match-p
               (regexp-quote (shell-quote-argument "exec claude")) cmd)))))

(ert-deftest baton-test-sodagun-guest-forward-command ()
  "The in-guest forwarder bridges guest loopback PORT to the host alias."
  (should (equal (baton-sodagun--guest-forward-command 4321)
                 (concat "socat TCP-LISTEN:4321,bind=127.0.0.1,reuseaddr,fork"
                         " TCP:host.microsandbox.internal:4321"))))

(ert-deftest baton-test-sodagun-attach-command-no-ports-no-wrap ()
  "Without :ports the agent command is attached directly (no wrapper shell)."
  (cl-letf (((symbol-function 'baton-sodagun--executable) (lambda () "sodagun")))
    (let ((cmd (baton-sodagun--attach-command "/root" "claude" :ports nil)))
      (should (string-suffix-p " -- claude" cmd))
      (should-not (string-match-p "socat" cmd)))))

;;; ─── sandbox start tests ────────────────────────────────────────────────────

(ert-deftest baton-test-sodagun-sandbox-start-passes-rules ()
  "`baton-sodagun--sandbox-start' passes each net rule and returns the name."
  (let (run-args)
    (cl-letf (((symbol-function 'baton-sodagun--run)
               (lambda (&rest args)
                 (setq run-args args)
                 '((status . "ok") (sandbox_name . "sb-1")))))
      (should (equal (baton-sodagun--sandbox-start
                      "/root" '("allow@host:tcp:1234" "allow@host:tcp:5678"))
                     "sb-1"))
      (should (equal run-args
                     '("sandbox" "start" "/root"
                       "--net-rule" "allow@host:tcp:1234"
                       "--net-rule" "allow@host:tcp:5678"))))))

(ert-deftest baton-test-sodagun-sandbox-start-passes-config ()
  "`baton-sodagun--sandbox-start' forwards CONFIG as --config before rules."
  (let (run-args)
    (cl-letf (((symbol-function 'baton-sodagun--run)
               (lambda (&rest args)
                 (setq run-args args)
                 '((status . "ok") (sandbox_name . "sb-1")))))
      (baton-sodagun--sandbox-start "/root" '("allow@host:tcp:1234")
                                    "/repo/custom-sodagun.toml")
      (should (equal run-args
                     '("sandbox" "start" "/root"
                       "--config" "/repo/custom-sodagun.toml"
                       "--net-rule" "allow@host:tcp:1234"))))))

(ert-deftest baton-test-sodagun-sandbox-start-errors-without-name ()
  "`baton-sodagun--sandbox-start' fails fast when no sandbox_name is returned."
  (cl-letf (((symbol-function 'baton-sodagun--run)
             (lambda (&rest _args) '((status . "ok")))))
    (should-error (baton-sodagun--sandbox-start "/root" nil))))

;;; ─── sodagun executor resolve/teardown tests ────────────────────────────────

(defmacro baton-sodagun-test--with-executor-stubs (&rest body)
  "Run BODY with the sodagun CLI side effects stubbed and recorded.
Binds `wt-calls', `start-calls', and an isolated
`baton-sodagun--workspaces'.  The stubbed worktree is /root//work/feat."
  (declare (indent 0))
  `(let ((wt-calls nil) (start-calls nil)
         (baton-sodagun--workspaces (make-hash-table :test 'equal)))
     (ignore wt-calls start-calls)
     (cl-letf (((symbol-function 'baton-sodagun--add-worktree)
                (lambda (branch repo &optional base)
                  (push (list branch repo base) wt-calls)
                  '("/root" . "/work/feat")))
               ((symbol-function 'baton-sodagun--sandbox-start)
                (lambda (rootdir rules &optional config)
                  (push (list rootdir rules config) start-calls)
                  "sb-1")))
       ,@body)))

(ert-deftest baton-test-sodagun-resolve-full-flow ()
  "The sodagun executor creates worktree + sandbox + forwarders and registers them."
  (baton-test-with-clean-state
    (baton-sodagun-test--with-executor-stubs
      (baton-define-agent
       :name 'sbx-agent :command "cmd" :status-function-trigger :periodic
       :env-functions (list (lambda (_k dir)
                              `(:env (,(format "DIR=%s" dir) "PORT=1234")
                                :ports (1234 5678)))))
      (let* ((s (baton-session-create :agent 'sbx-agent :command "claude"
                                      :directory "/repo" :name "sbx-1"
                                      :executor 'sodagun)))
        (setf (baton--session-metadata s)
              (list :sodagun-branch "feat" :sodagun-base "origin/dev"))
        (let ((resolved (baton-executor--resolve 'sodagun s)))
          ;; Worktree created from stashed branch/base against the repo.
          (should (equal wt-calls '(("feat" "/repo" "origin/dev"))))
          ;; Env-functions saw the worktree as the directory.
          (should (member "DIR=/work/feat" (plist-get
                                            (gethash "sbx-1" baton-sodagun--workspaces)
                                            :env)))
          ;; Sandbox started with one allow@host rule per declared port.
          (should (equal start-calls
                         '(("/root" ("allow@host:tcp:1234" "allow@host:tcp:5678") nil))))
          ;; Resolve contract: run in the worktree, attach command carrying
          ;; env and the in-guest forwarder ports, no host env.
          (should (equal (plist-get resolved :directory) "/work/feat"))
          (should (equal (plist-get resolved :command)
                         (baton-sodagun--attach-command
                          "/root" "claude"
                          :env '("DIR=/work/feat" "PORT=1234")
                          :ports '(1234 5678))))
          (should (null (plist-get resolved :extra-env)))
          ;; Session re-anchored to the worktree; workspace registered.
          (should (equal (baton--session-directory s) "/work/feat"))
          (let ((ws (gethash "sbx-1" baton-sodagun--workspaces)))
            (should (equal (plist-get ws :rootdir) "/root"))
            (should (equal (plist-get ws :sandbox-name) "sb-1"))
            (should (equal (plist-get ws :ports) '(1234 5678)))))))))

(ert-deftest baton-test-sodagun-resolve-passes-config ()
  "Resolve forwards the stashed :sodagun-config to sandbox start."
  (baton-test-with-clean-state
    (baton-sodagun-test--with-executor-stubs
      (baton-define-agent :name 'sbx-agent :command "cmd"
                          :status-function-trigger :periodic)
      (let ((s (baton-session-create :agent 'sbx-agent :command "claude"
                                     :directory "/repo" :name "sbx-cfg"
                                     :executor 'sodagun)))
        (setf (baton--session-metadata s)
              (list :sodagun-config "/repo/custom-sodagun.toml"))
        (baton-executor--resolve 'sodagun s)
        (should (equal start-calls
                       '(("/root" nil "/repo/custom-sodagun.toml"))))))))

(ert-deftest baton-test-sodagun-resolve-auto-branch ()
  "Sandbox without an explicit branch derives one from the session name."
  (baton-test-with-clean-state
    (baton-sodagun-test--with-executor-stubs
      (baton-define-agent :name 'sbx-agent :command "cmd"
                          :status-function-trigger :periodic)
      (let ((s (baton-session-create :agent 'sbx-agent :command "claude"
                                     :directory "/repo" :name "sbx-auto"
                                     :executor 'sodagun)))
        (baton-executor--resolve 'sodagun s)
        (should (equal wt-calls '(("baton/sbx-auto" "/repo" nil))))))))

(ert-deftest baton-test-sodagun-resolve-cleans-up-on-sandbox-failure ()
  "A sandbox-start failure mid-resolve deregisters without removing anything.
The worktree is kept; no sandbox was started so no removal is issued."
  (baton-test-with-clean-state
    (let ((baton-sodagun--workspaces (make-hash-table :test 'equal))
          (removed nil))
      (baton-define-agent :name 'sbx-agent :command "cmd"
                          :status-function-trigger :periodic)
      (cl-letf (((symbol-function 'baton-sodagun--add-worktree)
                 (lambda (&rest _args) '("/root" . "/work/feat")))
                ((symbol-function 'baton-sodagun--sandbox-start)
                 (lambda (&rest _args) (error "Boot failed")))
                ((symbol-function 'baton-sodagun--remove-sandbox)
                 (lambda (rootdir _session-name) (push rootdir removed))))
        (let ((s (baton-session-create :agent 'sbx-agent :command "claude"
                                       :directory "/repo" :name "sbx-fail"
                                       :executor 'sodagun)))
          (should-error (baton-executor--resolve 'sodagun s))
          (should (null (gethash "sbx-fail" baton-sodagun--workspaces)))
          (should (null removed)))))))

(ert-deftest baton-test-sodagun-resolve-rejects-duplicate-registration ()
  "Resolve fails fast when a workspace is already registered for the session."
  (baton-test-with-clean-state
    (let ((baton-sodagun--workspaces (make-hash-table :test 'equal)))
      (baton-define-agent :name 'sbx-agent :command "cmd"
                          :status-function-trigger :periodic)
      (let ((s (baton-session-create :agent 'sbx-agent :command "claude"
                                     :directory "/repo" :name "sbx-dup"
                                     :executor 'sodagun)))
        (puthash "sbx-dup" '(:rootdir "/stale") baton-sodagun--workspaces)
        (should-error (baton-executor--resolve 'sodagun s))))))

(ert-deftest baton-test-sodagun-remove-sandbox-command ()
  "`baton-sodagun--remove-sandbox' issues an async sandbox remove (not stop).
The process is labeled with the session name."
  (let (seen-command seen-name)
    (cl-letf (((symbol-function 'make-process)
               (lambda (&rest plist)
                 (setq seen-command (plist-get plist :command)
                       seen-name (plist-get plist :name))
                 'fake-proc)))
      (baton-sodagun--remove-sandbox "/root" "sbx-1")
      (should (equal seen-name "baton-sodagun-remove-sbx-1"))
      (should (equal seen-command '("sodagun" "sandbox" "remove" "/root"))))))

(ert-deftest baton-test-sodagun-teardown ()
  "Teardown removes the sandbox, keeps the worktree, and deregisters."
  (baton-test-with-clean-state
    (baton-define-agent :name 'sbx-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let ((baton-sodagun--workspaces (make-hash-table :test 'equal))
          (removed nil))
      (let ((s (baton-session-create :agent 'sbx-agent :command "claude"
                                     :directory "/repo" :name "sbx-td"
                                     :executor 'sodagun)))
        (puthash "sbx-td"
                 (list :rootdir "/root" :worktree-path "/work/feat"
                       :sandbox-name "sb-1" :ports '(1234))
                 baton-sodagun--workspaces)
        (cl-letf (((symbol-function 'baton-sodagun--remove-sandbox)
                   (lambda (rootdir _session-name) (push rootdir removed))))
          (baton-executor--teardown 'sodagun s)
          (should (equal removed '("/root")))
          (should (null (gethash "sbx-td" baton-sodagun--workspaces)))
          ;; Idempotent: a second teardown is a no-op.
          (baton-executor--teardown 'sodagun s)
          (should (equal removed '("/root"))))))))

;;; ─── baton-new worktree path tests ──────────────────────────────────────────

(ert-deftest baton-test-new-worktree-resolves-directory ()
  "`baton-new' with a worktree branch runs the session in the worktree.
The executor stays `exec' (worktree without sandbox runs on the host)."
  (baton-test-with-clean-state
    (baton-define-agent :name 'wt-agent :command "cmd"
                        :status-function-trigger :periodic)
    (let (wt-args)
      (cl-letf (((symbol-function 'baton-sodagun--add-worktree)
                 (lambda (branch repo &optional base)
                   (setq wt-args (list branch repo base))
                   '("/root" . "/work/feat-x")))
                ((symbol-function 'baton-process-spawn) #'ignore)
                ((symbol-function 'pop-to-buffer) #'ignore))
        (let ((session (baton-new "wt-agent" "/repo" nil "feat-x" "origin/dev")))
          (should (equal wt-args '("feat-x" "/repo" "origin/dev")))
          (should (equal (baton--session-directory session) "/work/feat-x"))
          (should (eq (baton--session-executor session) 'exec)))))))

(ert-deftest baton-test-new-worktree-requires-module ()
  "`baton-new' with a worktree branch errors when baton-sodagun is not loaded."
  (baton-test-with-clean-state
    (baton-define-agent :name 'wt-agent :command "cmd"
                        :status-function-trigger :periodic)
    (cl-letf* ((real-featurep (symbol-function 'featurep))
               ((symbol-function 'featurep)
                (lambda (feature &rest rest)
                  (and (not (eq feature 'baton-sodagun))
                       (apply real-featurep feature rest)))))
      (should-error (baton-new "wt-agent" "/repo" nil "feat-x")))))

(ert-deftest baton-test-new-sandbox-sets-executor-and-metadata ()
  "`baton-new' with sandbox defers to the sodagun executor.
The worktree is NOT created up front; branch/base are stashed in the
session metadata for `baton-executor--resolve' to consume."
  (baton-test-with-clean-state
    (baton-define-agent :name 'sbx-agent :command "cmd"
                        :status-function-trigger :periodic)
    (cl-letf (((symbol-function 'baton-sodagun--add-worktree)
               (lambda (&rest _args) (error "Worktree must not be created up front")))
              ((symbol-function 'baton-process-spawn) #'ignore)
              ((symbol-function 'pop-to-buffer) #'ignore))
      (let ((session (baton-new "sbx-agent" "/repo" nil "feat-x" "origin/dev" t
                                "/repo/custom-sodagun.toml")))
        (should (eq (baton--session-executor session) 'sodagun))
        (should (equal (plist-get (baton--session-metadata session) :sodagun-branch)
                       "feat-x"))
        (should (equal (plist-get (baton--session-metadata session) :sodagun-base)
                       "origin/dev"))
        (should (equal (plist-get (baton--session-metadata session) :sodagun-config)
                       (expand-file-name "/repo/custom-sodagun.toml")))
        ;; Directory stays the repo until resolve re-anchors it.
        (should (equal (baton--session-directory session)
                       (expand-file-name "/repo")))))))

(ert-deftest baton-test-new-without-worktree-unchanged ()
  "`baton-new' without a worktree branch uses the given directory directly."
  (baton-test-with-clean-state
    (baton-define-agent :name 'plain-agent :command "cmd"
                        :status-function-trigger :periodic)
    (cl-letf (((symbol-function 'baton-process-spawn) #'ignore)
              ((symbol-function 'pop-to-buffer) #'ignore))
      (let ((session (baton-new "plain-agent" "/repo")))
        (should (equal (baton--session-directory session)
                       (expand-file-name "/repo")))
        (should (eq (baton--session-executor session) 'exec))))))

(provide 'baton-sodagun-tests)
;;; baton-sodagun-tests.el ends here
