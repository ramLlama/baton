;;; baton-sodagun.el --- sodagun worktree and sandbox integration  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Integrates baton with the sodagun CLI (https://github.com/ramraghunathan/sodagun)
;; for running agent sessions in dedicated git worktrees and microVM sandboxes.
;;
;; This module is optional.  It is loaded by `baton-mode' when the sodagun
;; binary is on `exec-path'; `baton-new' then accepts a worktree branch
;; (transient -w) so the agent runs in a fresh sodagun-managed worktree.

;;; Code:
(require 'cl-lib)
(require 'baton-session)
(require 'baton-executor)

(defun baton-sodagun-available-p ()
  "Return non-nil when the sodagun CLI is available."
  (and (executable-find "sodagun") t))

;;; CLI invocation

(defun baton-sodagun--run (&rest args)
  "Run sodagun with global json/quiet flags and ARGS synchronously.
Returns the parsed JSON result as an alist.  Progress noise before the
final JSON line is ignored.  Signals an error with the captured output
when sodagun exits non-zero or prints no JSON."
  (with-temp-buffer
    (let ((exit (apply #'call-process "sodagun" nil t nil
                       "--output" "json" "--quiet" args))
          (cmd-desc (mapconcat #'shell-quote-argument args " ")))
      (unless (eql exit 0)
        (error "Sodagun %s failed (exit %s): %s"
               cmd-desc exit (string-trim (buffer-string))))
      ;; sodagun prints its JSON result as a single line; setup scripts may
      ;; log progress lines above it, so parse the last line starting "{".
      (goto-char (point-max))
      (unless (re-search-backward "^{" nil t)
        (error "Sodagun %s produced no JSON output: %s"
               cmd-desc (string-trim (buffer-string))))
      (json-parse-buffer :object-type 'alist))))

;;; Worktrees

(defun baton-sodagun--add-worktree (branch repo &optional base)
  "Create a sodagun worktree on a new BRANCH of REPO, optionally from BASE.
Shells out to `sodagun git add-worktree'.  Returns (ROOTDIR . WORKTREE-PATH)
where ROOTDIR is the sodagun workspace directory and WORKTREE-PATH the
checked-out worktree inside it."
  (let* ((result (apply #'baton-sodagun--run
                        `("git" "add-worktree" ,branch ,repo
                          ,@(when base (list "--base" base)))))
         (rootdir (alist-get 'rootdir result))
         (metadata-file (and rootdir (expand-file-name "sodagun.json" rootdir)))
         (worktree-path
          (when (and metadata-file (file-readable-p metadata-file))
            (alist-get 'worktree_path
                       (with-temp-buffer
                         (insert-file-contents metadata-file)
                         (json-parse-buffer :object-type 'alist))))))
    (unless (and rootdir worktree-path)
      (error "Sodagun worktree for %s missing rootdir or sodagun.json metadata"
             branch))
    ;; Downstream code anchors sessions to these paths verbatim — a relative
    ;; path here would silently resolve against the wrong directory later.
    (unless (and (file-name-absolute-p rootdir)
                 (file-name-absolute-p worktree-path))
      (error "Sodagun returned non-absolute paths: %s, %s" rootdir worktree-path))
    (cons rootdir worktree-path)))

(provide 'baton-sodagun)
;;; baton-sodagun.el ends here
