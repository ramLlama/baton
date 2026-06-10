;;; baton-sodagun.el --- sodagun worktree and sandbox integration  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Integrates baton with the sodagun CLI (https://github.com/ramraghunathan/sodagun)
;; for running agent sessions in dedicated git worktrees and microVM sandboxes.
;;
;; This module is optional.  It is loaded by `baton-mode' when the sodagun
;; binary is on `exec-path'; `baton-new' then accepts a worktree branch
;; (transient -w) so the agent runs in a fresh sodagun-managed worktree,
;; and a sandbox switch (transient -s) that additionally runs the agent
;; inside a sodagun microVM sandbox via the `sodagun' executor.
;;
;; The sandbox path: resolve creates a worktree, evaluates the agent's
;; env-functions once against it, starts the sandbox with an allow@host
;; egress rule per declared port, and attaches the agent via
;; `sodagun sandbox attach ... --env K=V ... -- sh -c "socat ... & exec CMD"'.
;; Each declared port is bridged by an in-guest socat (the guest's
;; 127.0.0.1:PORT dials the host alias) backgrounded on the attach
;; connection itself — the sandbox accepts only one concurrent connection,
;; so forwarders cannot be separate exec clients.
;; Killing the session removes the sandbox but keeps the worktree.

;;; Code:
(require 'cl-lib)
(require 'baton-session)
(require 'baton-executor)

(defun baton-sodagun-available-p ()
  "Return non-nil when the sodagun CLI is available."
  (and (executable-find "sodagun") t))

(defun baton-sodagun--executable ()
  "Return the absolute path of the sodagun binary, or \"sodagun\".
Commands run through the terminal's /bin/sh see Emacs's PATH environment
variable, which may not cover the variable `exec-path' — so shell command
strings must embed the absolute path."
  (or (executable-find "sodagun") "sodagun"))

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

(defcustom baton-sodagun-worktree-created-hook nil
  "Hook called after a sodagun worktree is created.
Each function is called with three arguments: WORKTREE-PATH (the
checked-out worktree), REPO (the source repository the worktree was
created from), and BRANCH (the new branch name).  Useful for
site-specific post-creation setup — e.g. propagating direnv trust from
the repository's .envrc to the freshly created worktree."
  :type 'hook
  :group 'baton)

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
    (run-hook-with-args 'baton-sodagun-worktree-created-hook
                        worktree-path repo branch)
    (cons rootdir worktree-path)))

;;; Sandboxes

(defconst baton-sodagun--host-alias "host.microsandbox.internal"
  "DNS alias under which the guest reaches the host (microsandbox-network).")

(defvar baton-sodagun--workspaces (make-hash-table :test 'equal)
  "Hash table mapping session names to their sodagun workspace state.
Each value is a plist (:rootdir :worktree-path :sandbox-name :ports
:env), recorded by the `sodagun' executor's resolve and consumed by its
teardown.")

(defun baton-sodagun--net-rules (ports)
  "Return a guest-to-host egress net-rule SPEC for each port in PORTS."
  (mapcar (lambda (port) (format "allow@host:tcp:%d" port)) ports))

(defun baton-sodagun--sandbox-start (rootdir net-rules &optional config)
  "Start the sandbox for workspace ROOTDIR with NET-RULES; return its name.
NET-RULES are sodagun `--net-rule' SPEC strings appended after the
workspace config's own rules.  CONFIG, when non-nil, is an alternative
sodagun.toml path passed as --config — overriding the worktree's own
config (useful when the in-repo config has uncommitted changes the new
worktree's checkout doesn't have)."
  (let ((result (apply #'baton-sodagun--run
                       `("sandbox" "start" ,rootdir
                         ,@(when config (list "--config" config))
                         ,@(mapcan (lambda (rule) (list "--net-rule" rule))
                                   net-rules)))))
    (or (alist-get 'sandbox_name result)
        (error "Sodagun sandbox start for %s returned no sandbox_name" rootdir))))

(defun baton-sodagun--remove-sandbox (rootdir session-name)
  "Stop and remove the sandbox for workspace ROOTDIR asynchronously.
Uses `sodagun sandbox remove' so no stopped sandboxes accumulate; the
worktree is left on disk.  SESSION-NAME labels the process.  A failed
removal is reported via `message' (the kill flow must not block or
error on it)."
  (make-process
   :name (format "baton-sodagun-remove-%s" session-name)
   :command (list "sodagun" "sandbox" "remove" rootdir)
   :noquery t
   :sentinel (lambda (proc _event)
               (when (and (eq (process-status proc) 'exit)
                          (/= (process-exit-status proc) 0))
                 (message "baton-sodagun: sandbox remove for %s (%s) failed (exit %d)"
                          session-name rootdir (process-exit-status proc))))))

(defun baton-sodagun--guest-forward-command (port)
  "Return the in-guest socat invocation bridging PORT to the host.
It listens on the guest's 127.0.0.1:PORT and dials
`baton-sodagun--host-alias':PORT, so in-guest clients reach the host
service at the address they expect."
  (format "socat TCP-LISTEN:%d,bind=127.0.0.1,reuseaddr,fork TCP:%s:%d"
          port baton-sodagun--host-alias port))

(cl-defun baton-sodagun--attach-command (rootdir agent-command &key env ports)
  "Build the shell command attaching AGENT-COMMAND to ROOTDIR's sandbox.
ENV is a list of \"VAR=VALUE\" strings injected into the in-guest command
via repeated --env flags.  AGENT-COMMAND is embedded verbatim (it is
already a complete shell command string).
PORTS is a list of host ports to bridge from inside the guest.  The
sandbox accepts only ONE concurrent connection (microsandbox SDK), so the
forwarders cannot be separate `sodagun sandbox exec' clients: each port
gets a backgrounded in-guest socat launched by a wrapper shell on the
attach connection itself, which then execs AGENT-COMMAND.  The socats are
orphaned to the guest init and die with the sandbox."
  (concat (shell-quote-argument (baton-sodagun--executable))
          " sandbox attach "
          (shell-quote-argument rootdir)
          (mapconcat (lambda (kv) (concat " --env " (shell-quote-argument kv)))
                     env "")
          " -- "
          (if ports
              (concat
               "sh -c "
               (shell-quote-argument
                (concat
                 "command -v socat >/dev/null"
                 " || echo baton: socat missing in guest, port forwarding disabled; "
                 (mapconcat (lambda (port)
                              (concat (baton-sodagun--guest-forward-command port)
                                      " & "))
                            ports "")
                 "exec " agent-command)))
            agent-command)))

;;; `sodagun' executor

(defun baton-sodagun--register (name &rest props)
  "Merge PROPS into NAME's workspace entry in `baton-sodagun--workspaces'."
  (let ((ws (gethash name baton-sodagun--workspaces)))
    (while props
      (setq ws (plist-put ws (car props) (cadr props)))
      (setq props (cddr props)))
    (puthash name ws baton-sodagun--workspaces)))

(cl-defmethod baton-executor--resolve ((_executor (eql sodagun)) session)
  "Resolve SESSION to run inside a sodagun sandbox.
Creates a worktree (branch/base from the session's create-time
:sodagun-branch/:sodagun-base metadata; branch auto-derived from the
session name when absent), evaluates the agent env once against the
worktree, starts the sandbox with an allow@host rule per declared port,
and returns the attach command as the session's :command —
`baton-process-spawn' then launches it in the terminal backend like any
other session command, so the attach (and the agent inside it) starts
when the terminal spawns.  Port forwarders ride the attach connection
as in-guest socats (see `baton-sodagun--attach-command') because the
sandbox accepts only one concurrent connection.
Env reaches the agent via attach --env, not the host environment.
Side effects register incrementally in `baton-sodagun--workspaces'; on a
mid-resolve failure the partial state is torn down (sandbox removed,
worktree kept) before the error propagates."
  (let ((name (baton--session-name session)))
    (when (gethash name baton-sodagun--workspaces)
      (error "Sodagun workspace already registered for session %s" name))
    (condition-case err
        (let* ((meta (baton--session-metadata session))
               (branch (or (plist-get meta :sodagun-branch)
                           (concat "baton/" name)))
               (base (plist-get meta :sodagun-base))
               (worktree (baton-sodagun--add-worktree
                          branch (baton--session-directory session) base))
               (rootdir (car worktree))
               (worktree-path (cdr worktree))
               (agent-env (baton-executor--agent-env session worktree-path))
               (env (plist-get agent-env :env))
               (ports (plist-get agent-env :ports)))
          (baton-sodagun--register name
                                   :rootdir rootdir
                                   :worktree-path worktree-path
                                   :ports ports
                                   :env env
                                   :sandbox-name
                                   (baton-sodagun--sandbox-start
                                    rootdir (baton-sodagun--net-rules ports)
                                    (plist-get meta :sodagun-config)))
          ;; Re-anchor the session to the worktree so directory-based lookups
          ;; (and the status buffer) reflect where the agent actually works.
          (setf (baton--session-directory session) worktree-path)
          (list :directory worktree-path
                :command (baton-sodagun--attach-command
                          rootdir (baton--session-command session)
                          :env env :ports ports)
                :extra-env nil))
      (error
       (baton-executor--teardown 'sodagun session)
       (signal (car err) (cdr err))))))

(cl-defmethod baton-executor--teardown ((_executor (eql sodagun)) session)
  "Remove SESSION's sandbox; keep the worktree on disk.
The agent's attach process dies with the terminal buffer before the
killed-hook fires (freeing the sandbox's single connection), and the
in-guest socat forwarders die with the sandbox itself — nothing to kill
host-side.  Tolerates partially-resolved state: the sandbox is only
removed when it was actually started.  Idempotent: the workspace
registry entry is removed on the first call, making subsequent calls
no-ops."
  (when-let* ((ws (gethash (baton--session-name session)
                           baton-sodagun--workspaces)))
    (when (plist-get ws :sandbox-name)
      (baton-sodagun--remove-sandbox (plist-get ws :rootdir)
                                     (baton--session-name session)))
    (remhash (baton--session-name session) baton-sodagun--workspaces)))

(provide 'baton-sodagun)
;;; baton-sodagun.el ends here
