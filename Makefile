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

EL_FILES := $(filter-out baton-autoloads.el,$(wildcard *.el))

MATCH ?=

.PHONY: clean checkdoc test compile pre-commit

default: compile

clean:
	rm -f *.elc baton-autoloads.el

# baton-test-helpers.el must be first: it defines macros used by all other test files.
TEST_FILES := test/baton-test-helpers.el \
              $(filter-out test/baton-test-helpers.el,$(wildcard test/*.el))

checkdoc:
	for FILE in $(EL_FILES) $(TEST_FILES); do \
	  $(EMACS) --batch $(LOAD_PATHS) \
	    --eval "(package-initialize)" \
	    --eval "(setq sentence-end-double-space nil)" \
	    --eval "(checkdoc-file \"$$FILE\")" 2>&1 \
	    | grep -v "should be imperative" || true ; \
	done

test: compile
	$(EMACS) --batch $(LOAD_PATHS) \
	  --eval "(package-initialize)" \
	  -l ert \
	  -l baton-session.el \
	  -l baton-term.el \
	  -l baton-process.el \
	  -l baton-notify.el \
	  -l baton-alert.el \
	  $(if $(MONET_DIR),-l monet -l baton-monet.el) \
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
