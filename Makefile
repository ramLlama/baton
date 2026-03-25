EMACS ?= emacs

ifndef VTERM_DIR
VTERM_DIR := $(shell $(EMACS) --batch \
  --eval "(package-initialize)" \
  --eval "(when-let* ((f (locate-library \"vterm\"))) (princ (file-name-directory f)))" \
  2>/dev/null)
endif

ifndef MONET_DIR
MONET_DIR := $(shell $(EMACS) --batch \
  --eval "(package-initialize)" \
  --eval "(when-let* ((f (locate-library \"monet\"))) (princ (file-name-directory f)))" \
  2>/dev/null)
endif

LOAD_PATHS := -L . \
              $(if $(MONET_DIR),-L $(MONET_DIR)) \
              $(if $(VTERM_DIR),-L $(VTERM_DIR))

EL_FILES := birbal-session.el birbal-process.el birbal-notify.el \
            birbal-monet.el birbal.el

MATCH ?=

.PHONY: all checkdoc compile test clean

default: all

clean:
	rm -f *.elc birbal-autoloads.el

checkdoc:
	for FILE in $(EL_FILES) birbal-tests.el; do \
	  $(EMACS) --batch $(LOAD_PATHS) \
	    --eval "(package-initialize)" \
	    --eval "(setq sentence-end-double-space nil)" \
	    --eval "(checkdoc-file \"$$FILE\")" 2>&1 \
	    | grep -v "should be imperative" || true ; \
	done

compile: clean
	$(EMACS) --batch $(LOAD_PATHS) \
	  --eval "(package-initialize)" \
	  --eval "(setq sentence-end-double-space nil)" \
	  --eval "(package-generate-autoloads \"birbal\" \".\")" \
	  -f batch-byte-compile $(EL_FILES) 2>&1 | grep -v "vterm" || true

test:
	$(EMACS) --batch $(LOAD_PATHS) \
	  --eval "(package-initialize)" \
	  -l ert \
	  -l birbal-session.el \
	  -l birbal-process.el \
	  -l birbal-notify.el \
	  -l birbal.el \
	  -l birbal-tests.el \
	  $(if $(MATCH),--eval "(ert-run-tests-batch-and-exit \"$(MATCH)\")",-f ert-run-tests-batch-and-exit)

all: checkdoc compile
