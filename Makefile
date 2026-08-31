EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L lisp -L tests

# Where the evil tests look for evil and its one hard dependency, goto-chg.  -Q is
# deliberate -- the suite must not inherit your configuration -- so an installed
# package is not on `load-path' unless it is named here.  A run that cannot find
# evil says so and skips, which is quiet enough to be mistaken for passing.
EVIL_LOAD_PATH ?=

.PHONY: all test rust-test lisp-test lint checkdoc compile bench clean

all: test

test: rust-test lisp-test lint

rust-test:
	cargo test

lisp-test:
	$(BATCH) $(EVIL_LOAD_PATH) -l ert -l cooked-tests.el -f ert-run-tests-batch-and-exit

lint: compile checkdoc
	cargo clippy --all-targets -- -D warnings

# Warnings are errors here: the tree is clean, and the only way it stays clean is
# if a new one fails the build rather than scrolling past.
#
# Make does the globbing and `batch-byte-compile' takes the files as arguments, so
# there is no regexp in the middle to get wrong.  There was: `"[.]el\z"' spent a long
# time here, and `\z' is not an escape Elisp strings know -- it collapsed to the
# regexp `[.]elz', which matches nothing, so this target compiled no files and
# reported success for years.  A gate that cannot fail is worse than no gate.
compile:
	$(BATCH) -l bytecomp --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(wildcard lisp/*.el)
	@rm -f lisp/*.elc

# Advisory rather than gating.  Three of checkdoc's rules disagree with this tree
# on purpose: the `cooked: ' prefix every message carries, evil's own lowercase
# `emacs state', and keys already spelled the modern \\=`C-c\\=' way that its regexp
# cannot see.  Read the output; do not chase it to zero.
checkdoc:
	@for f in lisp/*.el; do \
	  $(EMACS) -Q --batch -l checkdoc \
	    --eval "(progn (setq checkdoc-arguments-in-order-flag nil \
	                         sentence-end-double-space t) \
	                   (checkdoc-file \"$$f\"))" 2>&1; \
	done | grep -v '^Warning (emacs): $$' || true

bench:
	cargo test --release --test throughput -- --ignored --nocapture
	$(BATCH) -l cooked-bench.el -f cooked-bench

clean:
	cargo clean
	rm -f lisp/*.elc tests/*.elc
