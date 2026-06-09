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

(ert-deftest baton-test-sodagun-add-worktree-errors-without-metadata ()
  "`baton-sodagun--add-worktree' fails fast when sodagun.json is missing."
  (let ((rootdir (make-temp-file "baton-sodagun-test-empty-" t)))
    (unwind-protect
        (cl-letf (((symbol-function 'baton-sodagun--run)
                   (lambda (&rest _args) `((status . "ok") (rootdir . ,rootdir)))))
          (should-error (baton-sodagun--add-worktree "feat" "/repo")))
      (delete-directory rootdir t))))

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
