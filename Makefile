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

EL_FILES := baton-session.el baton-process.el baton-notify.el \
            baton-alert.el baton-monet.el baton.el

MATCH ?=

.PHONY: clean checkdoc test compile pre-commit

default: compile

clean:
	rm -f *.elc baton-autoloads.el

TEST_FILES := test/baton-test-helpers.el \
             test/baton-session-tests.el \
             test/baton-process-tests.el \
             test/baton-notify-tests.el \
             test/baton-monet-tests.el \
             test/baton-alert-tests.el

checkdoc:
	for FILE in $(EL_FILES) $(TEST_FILES); do \
	  $(EMACS) --batch $(LOAD_PATHS) \
	    --eval "(package-initialize)" \
	    --eval "(setq sentence-end-double-space nil)" \
	    --eval "(checkdoc-file \"$$FILE\")" 2>&1 \
	    | grep -v "should be imperative" || true ; \
	done

test:
	$(EMACS) --batch $(LOAD_PATHS) \
	  --eval "(package-initialize)" \
	  -l ert \
	  -l baton-session.el \
	  -l baton-process.el \
	  -l baton-notify.el \
	  -l baton-alert.el \
	  -l baton.el \
	  $(foreach f,$(TEST_FILES),-l $(f)) \
	  $(if $(MATCH),--eval "(ert-run-tests-batch-and-exit \"$(MATCH)\")",-f ert-run-tests-batch-and-exit)

compile: clean
	$(EMACS) --batch $(LOAD_PATHS) \
	  --eval "(package-initialize)" \
	  --eval "(setq sentence-end-double-space nil)" \
	  --eval "(package-generate-autoloads \"baton\" \".\")" \
	  -f batch-byte-compile $(EL_FILES) 2>&1 | grep -v "vterm" || true

pre-commit: checkdoc test compile
