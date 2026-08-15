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
compile:
	$(BATCH) --eval '(let ((byte-compile-error-on-warn t)) (dolist (f (directory-files "lisp" t "[.]el\z")) (unless (byte-compile-file f) (kill-emacs 1))))'
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
