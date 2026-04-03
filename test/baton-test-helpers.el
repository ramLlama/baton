;;; baton-test-helpers.el --- Shared ERT test macros for baton  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; Shared test isolation macros used across all baton ERT test files.

;;; Code:
(require 'ert)
(require 'baton-session)
(require 'baton-notify)
(require 'baton-alert)

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

(defmacro baton-alert-test-with-clean-state (&rest body)
  "Execute BODY with isolated alert and session state."
  (declare (indent 0))
  `(baton-test-with-clean-state
     (let ((baton-alert--backends nil)
           (baton-notify-function #'baton-notify--default))
       ,@body)))

(provide 'baton-test-helpers)
;;; baton-test-helpers.el ends here
