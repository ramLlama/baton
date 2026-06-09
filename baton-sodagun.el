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
;; egress rule per declared port, bridges each port with an in-guest socat
;; forwarder (the guest's 127.0.0.1:PORT dials the host alias), and attaches
;; the agent via `sodagun sandbox attach ... --env K=V ... -- CMD'.
;; Killing the session removes the sandbox but keeps the worktree.

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

;;; Sandboxes

(defconst baton-sodagun--host-alias "host.microsandbox.internal"
  "DNS alias under which the guest reaches the host (microsandbox-network).")

(defvar baton-sodagun--workspaces (make-hash-table :test 'equal)
  "Hash table mapping session names to their sodagun workspace state.
Each value is a plist (:rootdir :worktree-path :sandbox-name :ports :env
:forwarder-procs), recorded by the `sodagun' executor's resolve and
consumed by its teardown.")

(defun baton-sodagun--net-rules (ports)
  "Return a guest-to-host egress net-rule SPEC for each port in PORTS."
  (mapcar (lambda (port) (format "allow@host:tcp:%d" port)) ports))

(defun baton-sodagun--sandbox-start (rootdir net-rules)
  "Start the sandbox for workspace ROOTDIR with NET-RULES; return its name.
NET-RULES are sodagun `--net-rule' SPEC strings appended after the
workspace config's own rules."
  (let ((result (apply #'baton-sodagun--run
                       `("sandbox" "start" ,rootdir
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

(defun baton-sodagun--start-forwarder (rootdir port session-name)
  "Bridge guest PORT to the host for ROOTDIR's sandbox; return the process.
Runs socat inside the guest (via `sodagun sandbox exec'): it listens on the
guest's 127.0.0.1:PORT and dials `baton-sodagun--host-alias':PORT, so
in-guest clients reach the host service at the address they expect.
SESSION-NAME labels the process."
  (make-process
   :name (format "baton-sodagun-fwd-%s-%d" session-name port)
   :command (list "sodagun" "sandbox" "exec" rootdir
                  "socat"
                  (format "TCP-LISTEN:%d,bind=127.0.0.1,reuseaddr,fork" port)
                  (format "TCP:%s:%d" baton-sodagun--host-alias port))
   :noquery t))

(cl-defun baton-sodagun--attach-command (rootdir agent-command &key env)
  "Build the shell command attaching AGENT-COMMAND to ROOTDIR's sandbox.
ENV is a list of \"VAR=VALUE\" strings injected into the in-guest command
via repeated --env flags.  AGENT-COMMAND is embedded verbatim after the
-- separator (it is already a complete shell command string)."
  (concat "sodagun sandbox attach "
          (shell-quote-argument rootdir)
          (mapconcat (lambda (kv) (concat " --env " (shell-quote-argument kv)))
                     env "")
          " -- " agent-command))

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
starts a socat forwarder per port, and returns the attach command as the
session's :command — `baton-process-spawn' then launches it in the
terminal backend like any other session command, so the attach (and the
agent inside it) starts when the terminal spawns.
Env reaches the agent via attach --env, not the host environment.
Side effects register incrementally in `baton-sodagun--workspaces'; on a
mid-resolve failure the partial state is torn down (sandbox removed,
forwarders killed, worktree kept) before the error propagates."
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
                                    rootdir (baton-sodagun--net-rules ports)))
          ;; Forwarders start before the agent attaches, but socat's listen
          ;; setup races the agent's first connect; in practice the agent
          ;; boots much slower.  A lost race surfaces in-guest as connection
          ;; refused on 127.0.0.1:PORT.
          (dolist (port ports)
            (let ((proc (baton-sodagun--start-forwarder rootdir port name))
                  (ws (gethash name baton-sodagun--workspaces)))
              (baton-sodagun--register name :forwarder-procs
                                       (cons proc (plist-get ws :forwarder-procs)))))
          ;; Re-anchor the session to the worktree so directory-based lookups
          ;; (and the status buffer) reflect where the agent actually works.
          (setf (baton--session-directory session) worktree-path)
          (list :directory worktree-path
                :command (baton-sodagun--attach-command
                          rootdir (baton--session-command session) :env env)
                :extra-env nil))
      (error
       (baton-executor--teardown 'sodagun session)
       (signal (car err) (cdr err))))))

(cl-defmethod baton-executor--teardown ((_executor (eql sodagun)) session)
  "Remove SESSION's sandbox and kill its forwarders; keep the worktree.
The agent's attach process dies with the terminal buffer before the
killed-hook fires, and the forwarders are killed here first, so the
sandbox has no users left when the removal is issued.  Tolerates
partially-resolved state: the sandbox is only removed when it was
actually started.  Idempotent: the workspace registry entry is removed
on the first call, making subsequent calls no-ops."
  (when-let* ((ws (gethash (baton--session-name session)
                           baton-sodagun--workspaces)))
    (dolist (proc (plist-get ws :forwarder-procs))
      (when (process-live-p proc)
        (delete-process proc)))
    (when (plist-get ws :sandbox-name)
      (baton-sodagun--remove-sandbox (plist-get ws :rootdir)
                                     (baton--session-name session)))
    (remhash (baton--session-name session) baton-sodagun--workspaces)))

(provide 'baton-sodagun)
;;; baton-sodagun.el ends here
