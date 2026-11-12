EMACS ?= emacs
SANDBOX := .sandbox
SOURCES := furball.el furball-api.el furball-query.el furball-transient.el furball-evil.el
TESTS := tests/furball-tests.el tests/furball-transient-tests.el
BATCH := $(EMACS) -Q --batch --eval '(setq load-prefer-newer t)' --eval '(setq package-user-dir "$(CURDIR)/$(SANDBOX)")' --eval '(package-initialize)' -L . -L tests

.PHONY: all check format lint test clean

all: check

check: lint test

# Reindent every source and test file in place the way Emacs would.
format: $(SANDBOX)/.installed
	$(BATCH) -l scripts/format.el -f furball-format-files $(SOURCES) $(TESTS)

# Byte-compile, checkdoc, indentation, and whitespace checks via elisp-lint;
# package-lint runs separately so its warnings are reported without failing.
lint: $(SANDBOX)/.installed
	$(BATCH) -l elisp-lint \
	  --eval '(setq-default indent-tabs-mode nil)' \
	  -f elisp-lint-files-batch --no-fill-column --no-package-lint $(SOURCES)
	$(BATCH) -l package-lint \
	  --eval '(setq package-lint-main-file "furball.el" package-lint-batch-fail-on-warnings nil)' \
	  -f package-lint-batch-and-exit $(SOURCES)

test:
	$(BATCH) $(foreach f,$(TESTS),-l $(f)) -f ert-run-tests-batch-and-exit

$(SANDBOX)/.installed: scripts/install.el
	$(BATCH) -l scripts/install.el
	touch $@

clean:
	rm -rf $(SANDBOX) *.elc tests/*.elc
