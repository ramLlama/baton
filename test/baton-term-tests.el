;;; baton-term-tests.el --- ERT tests for baton-term backend abstraction  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai, test

;;; Commentary:
;; Pure ERT tests for the terminal backend abstraction.  All tests use
;; mocks (cl-letf) — no live terminal is required.

;;; Code:
(require 'ert)
(require 'baton-term)

;;; ─── Input-command lookup tests ──────────────────────────────────────────────

(ert-deftest baton-test-term-input-commands-vterm ()
  "`baton-term-input-commands' for vterm returns a list containing vterm--self-insert."
  (should (memq 'vterm--self-insert (baton-term-input-commands 'vterm))))

(ert-deftest baton-test-term-input-commands-eat ()
  "`baton-term-input-commands' for eat returns a list containing eat-self-input."
  (should (memq 'eat-self-input (baton-term-input-commands 'eat))))

(ert-deftest baton-test-term-input-commands-ghostel ()
  "`baton-term-input-commands' for ghostel returns a list containing ghostel--self-insert."
  (should (memq 'ghostel--self-insert (baton-term-input-commands 'ghostel))))

;;; ─── Pre/post ordering tests ─────────────────────────────────────────────────

(ert-deftest baton-test-term-pre-fn-called-before-mode ()
  "`baton-term--activate' calls :pre fn before the mode function."
  (let* ((call-order '())
         (buf (get-buffer-create " *baton-term-test-pre*")))
    (unwind-protect
        (let ((baton-terminal-backend-config
               (list (list 'eat
                           :pre  (lambda () (push 'pre call-order))
                           :post nil
                           :input-commands baton-term-eat-input-commands))))
          (cl-letf (((symbol-function 'require) #'ignore)
                    ((symbol-function 'eat-exec)
                     (lambda (_buf _name _cmd _sf _args)
                       (push 'mode call-order))))
            (baton-term--activate 'eat buf "/tmp" "true"))
          (should (equal (reverse call-order) '(pre mode))))
      (kill-buffer buf))))

(ert-deftest baton-test-term-post-fn-called-after-mode ()
  "`baton-term--activate' calls :post fn after the mode function."
  (let* ((call-order '())
         (buf (get-buffer-create " *baton-term-test-post*")))
    (unwind-protect
        (let ((baton-terminal-backend-config
               (list (list 'vterm
                           :pre  nil
                           :post (lambda () (push 'post call-order))
                           :input-commands baton-term-vterm-input-commands))))
          (cl-letf (((symbol-function 'require) #'ignore)
                    ((symbol-function 'pop-to-buffer) #'ignore)
                    ((symbol-function 'vterm-mode)
                     (lambda () (push 'mode call-order))))
            (baton-term--activate 'vterm buf "/tmp" "true"))
          (should (equal (reverse call-order) '(mode post))))
      (kill-buffer buf))))

;;; ─── Config override test ────────────────────────────────────────────────────

(ert-deftest baton-test-term-backend-config-override ()
  "A custom :pre fn in baton-terminal-backend-config replaces the default."
  (let* ((called nil)
         (buf (get-buffer-create " *baton-term-test-override*")))
    (unwind-protect
        (let ((baton-terminal-backend-config
               (list (list 'eat
                           :pre  (lambda () (setq called t))
                           :post nil
                           :input-commands baton-term-eat-input-commands))))
          (cl-letf (((symbol-function 'require) #'ignore)
                    ((symbol-function 'eat-exec) #'ignore))
            (baton-term--activate 'eat buf "/tmp" "true"))
          (should called))
      (kill-buffer buf))))

;;; ─── send-string test ────────────────────────────────────────────────────────

(ert-deftest baton-test-term-send-string-eat ()
  "`baton-term--send-string' for eat calls eat-term-send-string with eat-terminal."
  (let* ((mock-terminal 'test-terminal)
         (sent-terminal nil)
         (sent-string nil)
         (buf (get-buffer-create " *baton-term-test-send-str*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local eat-terminal mock-terminal))
          (cl-letf (((symbol-function 'eat-term-send-string)
                     (lambda (term str)
                       (setq sent-terminal term
                             sent-string str))))
            (baton-term--send-string 'eat buf "hello"))
          (should (eq sent-terminal mock-terminal))
          (should (equal sent-string "hello")))
      (kill-buffer buf))))

;;; ─── send-key translation tests ──────────────────────────────────────────────

(ert-deftest baton-test-term-send-key-eat-ret ()
  "`baton-term--send-key' for eat translates \"RET\" to the carriage-return byte."
  (let* ((sent nil)
         (buf (get-buffer-create " *baton-term-test-key-ret*")))
    (unwind-protect
        (progn
          (with-current-buffer buf
            (setq-local eat-terminal 'mock))
          (cl-letf (((symbol-function 'eat-term-send-string)
                     (lambda (_term str) (setq sent str))))
            (baton-term--send-key 'eat buf "RET"))
          (should (equal sent "\r")))
      (kill-buffer buf))))

(ert-deftest baton-test-term-send-key-ghostel-ctrl-c ()
  "`baton-term--send-key' for ghostel translates the ctrl-c sequence to (ghostel-send-key \"c\" \"ctrl\")."
  (let* ((sent-key nil)
         (sent-mods nil)
         (buf (get-buffer-create " *baton-term-test-key-ghostel*")))
    (unwind-protect
        (progn
          (cl-letf (((symbol-function 'ghostel-send-key)
                     (lambda (key mods)
                       (setq sent-key key
                             sent-mods mods))))
            (baton-term--send-key 'ghostel buf "C-c"))
          (should (equal sent-key "c"))
          (should (equal sent-mods "ctrl")))
      (kill-buffer buf))))

(provide 'baton-term-tests)
;;; baton-term-tests.el ends here
