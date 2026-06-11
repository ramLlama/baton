;;; baton-executor.el --- Execution-environment abstraction  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Sessions vary along two orthogonal axes: the agent (what runs;
;; `baton-agents') and the executor (how/where it runs; the session's
;; `executor' slot).  Executors plug in via cl-defgeneric dispatch on the
;; executor symbol, mirroring baton-term.el's terminal-backend dispatch.
;;
;; This file defines the executor generics and the reference `exec'
;; executor, which runs the session command directly on the host.

;;; Code:
(require 'cl-lib)
(require 'baton-session)

(defvar baton-agents)

;;; Generic interface

(defvar baton-executor-guest-path-mappings nil
  "Host-to-guest path mappings the current executor exposes to agents.
An alist of (HOST-DIR . GUEST-DIR).  Sandboxed executors bind this
\(dynamically, around agent env-function evaluation) to describe where
the session's directory appears inside the guest — e.g.
\((\"/path/to/worktree\" . \"/workspace\")) — so integrations (monet's
IDE lockfile and protocol path translation) can map paths in both
directions.  Nil for host execution.")

(cl-defgeneric baton-executor--resolve (executor session)
  "Perform pre-spawn setup for SESSION under EXECUTOR.
Returns a plist (:directory DIR :command CMD :extra-env ENV).  DIR is the
directory the terminal buffer anchors to, CMD the shell command to run,
and ENV a list of \"VAR=VALUE\" strings prepended to the host
`process-environment' — or nil when the executor delivers env another way.")

(cl-defgeneric baton-executor--teardown (_executor _session)
  "Release executor resources held for SESSION by EXECUTOR.
Called from `baton-session-killed-hook' via
`baton-executor--teardown-on-kill'.  Implementations must be idempotent —
the kill paths in baton-session.el guard against double-fire, but that
guard lives elsewhere; do not rely on being called exactly once.
The default method is a no-op."
  nil)

(defun baton-executor--teardown-on-kill (session)
  "Dispatch executor teardown for SESSION on session kill."
  (baton-executor--teardown (baton--session-executor session) session))

(add-hook 'baton-session-killed-hook #'baton-executor--teardown-on-kill)

;;; Agent environment aggregation

(defun baton-executor--agent-env (session dir)
  "Evaluate SESSION's agent :env-functions once with DIR as the directory.
Returns an aggregate plist (:env STRINGS :ports PORTS) where STRINGS is a
list of \"VAR=VALUE\" assignments and PORTS the host ports the agent process
must be able to reach.  Each env-function must return that same plist shape,
or nil for no contribution; anything else is an error."
  (let* ((agent-def (gethash (baton--session-agent session) baton-agents))
         (env-fns (and agent-def (plist-get agent-def :env-functions)))
         (env nil)
         (ports nil))
    (dolist (fn env-fns)
      (let ((result (funcall fn (baton--session-name session) dir)))
        (when result
          (unless (and (consp result) (keywordp (car result)))
            (error "Env-function %S returned %S; expected (:env STRINGS :ports PORTS)"
                   fn result))
          (setq env   (append env   (plist-get result :env))
                ports (append ports (plist-get result :ports))))))
    (list :env env :ports (delete-dups ports))))

;;; `exec' executor — run the command directly on the host

(cl-defmethod baton-executor--resolve ((_executor (eql exec)) session)
  "Resolve SESSION for direct host execution.
Uses the session's own directory and command; agent env goes through the
host `process-environment' (:ports is ignored — localhost is reachable)."
  (let ((dir (or (baton--session-directory session) default-directory)))
    (list :directory dir
          :command (baton--session-command session)
          :extra-env (plist-get (baton-executor--agent-env session dir) :env))))

(provide 'baton-executor)
;;; baton-executor.el ends here
