;;; baton-term.el --- Terminal backend abstraction (eat / vterm / ghostel)  -*- lexical-binding: t -*-

;; Author: Ram Raghunathan
;; Keywords: tools, ai

;;; Commentary:
;; Provides a generic terminal backend abstraction over eat, vterm, and ghostel.
;; The active backend is controlled by `baton-terminal-backend' (default: eat).
;; Per-backend setup is fully configurable via `baton-terminal-backend-config'.

;;; Code:
(require 'cl-lib)

;;; External symbol declarations (byte-compiler hygiene; packages not required at load time)

(defvar eat-kill-buffer-on-exit)
(defvar eat-terminal)

(declare-function eat-exec              "eat" (buffer name command startfile args))
(declare-function eat-term-send-string "eat" (terminal string))

(defvar vterm-shell)
(defvar vterm-buffer-name-string)
(defvar vterm--redraw-immediately)

(declare-function vterm-mode        "vterm" ())
(declare-function vterm-send-string "vterm" (string &optional paste-p))
(declare-function vterm-send-key    "vterm" (key &optional shift meta ctrl))

(defvar ghostel-set-title-function)

(declare-function ghostel-exec        "ghostel" (buffer command args))
(declare-function ghostel-send-string "ghostel" (string))
(declare-function ghostel-send-key    "ghostel" (key mods))

;;; Input-command constants
;;
;; Declared before `baton-terminal-backend-config' because the defcustom
;; default value references them directly.

(defconst baton-term-vterm-input-commands
  '(vterm--self-insert vterm-send-key vterm-send-return vterm-send-string
    vterm-send-backspace vterm-send-tab vterm-send-up vterm-send-down
    vterm-send-left vterm-send-right vterm-send-ctrl-c vterm-send-ctrl-d
    vterm-send-ctrl-z vterm-send-escape vterm-send-meta-backspace)
  "Commands in vterm that count as user input for baton status-reset purposes.")

(defconst baton-term-eat-input-commands
  '(eat-self-input eat-yank eat-send-password)
  "Commands in eat that count as user input for baton status-reset purposes.")

(defconst baton-term-ghostel-input-commands
  '(ghostel--self-insert          ; private but used only as a symbol for `memq', never called
    ghostel-send-string ghostel-send-key
    ghostel-send-C-c ghostel-send-C-z ghostel-send-C-d ghostel-send-C-backslash)
  "Commands in ghostel that count as user input for baton status-reset purposes.")

;;; Per-backend setup functions
;;
;; Declared before `baton-terminal-backend-config' because the defcustom
;; default value references them directly.

(defun baton-term-eat-default-pre ()
  "Default eat pre-activation setup for baton sessions.
Must run before `eat-exec', which reads `eat-kill-buffer-on-exit' to decide
whether to add an exit hook.  Matches vterm's default: process exits → buffer
killed → `kill-buffer-hook' → baton-process--on-buffer-killed."
  (setq-local eat-kill-buffer-on-exit t))

(defun baton-term-vterm-default-post ()
  "Default vterm post-activation setup for baton sessions."
  ;; Prevent vterm from overriding our buffer name with a process title.
  (setq-local vterm-buffer-name-string nil)
  ;; Let vterm manage the cursor entirely; without this Emacs renders its own
  ;; cursor at buffer position 0 while vterm's overlay cursor is elsewhere.
  (setq-local cursor-type nil)
  (setq-local cursor-in-non-selected-windows nil)
  ;; Batch redraws to reduce flicker.
  (setq-local vterm--redraw-immediately nil))

(defun baton-term-ghostel-default-pre ()
  "Default ghostel pre-activation setup for baton sessions."
  ;; Prevents ghostel from overwriting baton's buffer name on title sequences.
  (setq-local ghostel-set-title-function nil))

;;; Customizables

(defcustom baton-terminal-backend-config
  (list (list 'eat
              :pre  #'baton-term-eat-default-pre
              :post nil
              :input-commands baton-term-eat-input-commands)
        (list 'vterm
              :pre  nil
              :post #'baton-term-vterm-default-post
              :input-commands baton-term-vterm-input-commands)
        (list 'ghostel
              :pre  #'baton-term-ghostel-default-pre
              :post nil
              :input-commands baton-term-ghostel-input-commands))
  "Alist of (BACKEND :pre FN :post FN :input-commands LIST).
Mixing plain-symbol alist keys (looked up with `alist-get') and keyword plist
keys (looked up with `plist-get') is idiomatic Emacs Lisp — e.g.:
  (plist-get (alist-get \\='eat baton-terminal-backend-config) :pre)
Default value encodes baton's built-in setup for each backend; override entries
to customize.  Example — extend eat's pre-activation:
  (setf (alist-get \\='eat baton-terminal-backend-config)
        (list :pre (lambda ()
                     (baton-term-eat-default-pre)
                     (setq-local eat-term-scrollback-size 50000))
              :post nil
              :input-commands baton-term-eat-input-commands))"
  :type '(alist :key-type symbol :value-type plist)
  :group 'baton)

(defcustom baton-terminal-backend 'eat
  "Terminal emulator backend used by baton for agent sessions."
  :type '(radio (const eat) (const vterm) (const ghostel))
  :group 'baton)

;;; Generic interface

(cl-defgeneric baton-term--activate (backend buf dir cmd)
  "Activate terminal BACKEND in BUF, running CMD in DIR.")

(cl-defgeneric baton-term--send-string (backend buf string)
  "Send STRING to terminal BACKEND in BUF.")

(cl-defgeneric baton-term--send-key (backend buf key)
  "Send KEY (named string like \"RET\" or \"TAB\") to terminal BACKEND in BUF.")

;;; Input-commands accessor

(defun baton-term-input-commands (backend)
  "Return the input-command list for BACKEND from `baton-terminal-backend-config'."
  (plist-get (alist-get backend baton-terminal-backend-config) :input-commands))

;;; Public entry point

(defun baton-term-spawn-in-buffer (buf dir command)
  "Activate the configured terminal backend in BUF running COMMAND in DIR."
  (baton-term--activate baton-terminal-backend buf dir command))

;;; ─── eat backend ─────────────────────────────────────────────────────────────

(cl-defmethod baton-term--activate ((_backend (eql eat)) buf dir cmd)
  "Activate eat in BUF running CMD in DIR."
  (let* ((config  (alist-get 'eat baton-terminal-backend-config))
         (pre-fn  (plist-get config :pre))
         (post-fn (plist-get config :post)))
    (require 'eat)
    (with-current-buffer buf
      (let ((default-directory (file-name-as-directory dir)))
        (when pre-fn (funcall pre-fn))
        (eat-exec buf (buffer-name buf) cmd nil nil)
        (when post-fn (funcall post-fn))))))

(cl-defmethod baton-term--send-string ((_backend (eql eat)) buf string)
  "Send STRING to eat terminal in BUF."
  (with-current-buffer buf
    (eat-term-send-string eat-terminal string)))

(cl-defmethod baton-term--send-key ((_backend (eql eat)) buf key)
  "Send KEY to eat terminal in BUF."
  (let ((seq (pcase key
               ("RET" "\r")
               ("TAB" "\t")
               ("ESC" "\e")
               ("C-c" "\C-c")
               ("C-d" "\C-d")
               ("C-z" "\C-z")
               ("DEL" "\177")
               (_     key))))
    (baton-term--send-string 'eat buf seq)))

;;; ─── vterm backend ───────────────────────────────────────────────────────────

(cl-defmethod baton-term--activate ((_backend (eql vterm)) buf dir cmd)
  "Activate vterm in BUF running CMD in DIR."
  (let* ((config  (alist-get 'vterm baton-terminal-backend-config))
         (pre-fn  (plist-get config :pre))
         (post-fn (plist-get config :post))
         ;; vterm-mode reads vterm-shell dynamically during init.
         (vterm-shell cmd))
    (require 'vterm)
    (when pre-fn
      (with-current-buffer buf (funcall pre-fn)))
    ;; vterm-mode must run while buf is in a visible window so the PTY gets
    ;; the correct terminal size (TIOCGWINSZ).  save-selected-window keeps
    ;; focus on the calling window; baton-new's pop-to-buffer switches to buf.
    (save-selected-window
      (pop-to-buffer buf)
      (with-current-buffer buf
        (let ((default-directory (file-name-as-directory dir)))
          (vterm-mode))))
    (when post-fn
      (with-current-buffer buf (funcall post-fn)))))

(cl-defmethod baton-term--send-string ((_backend (eql vterm)) buf string)
  "Send STRING to vterm terminal in BUF."
  (with-current-buffer buf
    (vterm-send-string string)))

(cl-defmethod baton-term--send-key ((_backend (eql vterm)) buf key)
  "Send KEY to vterm terminal in BUF."
  (with-current-buffer buf
    (vterm-send-key key)))

;;; ─── ghostel backend ─────────────────────────────────────────────────────────

(cl-defmethod baton-term--activate ((_backend (eql ghostel)) buf dir cmd)
  "Activate ghostel in BUF running CMD in DIR."
  (let* ((config  (alist-get 'ghostel baton-terminal-backend-config))
         (pre-fn  (plist-get config :pre))
         (post-fn (plist-get config :post)))
    (require 'ghostel)
    (with-current-buffer buf
      (let ((default-directory (file-name-as-directory dir)))
        (when pre-fn (funcall pre-fn))
        (ghostel-exec buf cmd nil)
        (when post-fn (funcall post-fn))))))

(cl-defmethod baton-term--send-string ((_backend (eql ghostel)) buf string)
  "Send STRING to ghostel terminal in BUF."
  (with-current-buffer buf
    (ghostel-send-string string)))

(cl-defmethod baton-term--send-key ((_backend (eql ghostel)) buf key)
  "Send KEY to ghostel terminal in BUF."
  (with-current-buffer buf
    (pcase key
      ("RET" (ghostel-send-key "return" nil))
      ("TAB" (ghostel-send-key "tab"    nil))
      ("ESC" (ghostel-send-key "escape" nil))
      ("C-c" (ghostel-send-key "c" "ctrl"))
      ("C-d" (ghostel-send-key "d" "ctrl"))
      ("C-z" (ghostel-send-key "z" "ctrl"))
      (_     (ghostel-send-string key)))))

(provide 'baton-term)
;;; baton-term.el ends here
