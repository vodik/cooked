EMACS ?= emacs
BATCH  = $(EMACS) -Q --batch -L lisp -L tests

# Cargo builds here; nothing but `module' below ever writes the artifact Emacs
# loads.  The separation is the whole point, and it is not tidiness.
#
# rustc writes its output in place -- same inode, new contents -- and cargo
# hardlinks `target/release/libcooked.so' to the copy under `deps/', so a rebuild
# rewrites the very bytes any running Emacs has mapped.  The kernel answers the
# next page fault with SIGBUS, and Emacs' fatal-signal handler exits without
# dumping core, so what the user sees is the editor vanishing with nothing in
# `coredumpctl' and nothing in the journal to say why.  Developing a dynamic
# module from inside the editor that loads it makes this routine rather than
# exotic: it cost three Emacs sessions in one afternoon before it was understood.
#
# `?=' so an outer CARGO_TARGET_DIR still wins -- a CI cache, or a scratch build
# deliberately kept away from the tree.
CARGO_TARGET_DIR ?= target/cargo
export CARGO_TARGET_DIR

# cargo names a cdylib `libcooked.dylib' on macOS, which is what
# `module-file-suffix' reports there and so what `cooked--load-module' looks for.
ifeq ($(shell uname -s),Darwin)
MODULE_SUFFIX := .dylib
else
MODULE_SUFFIX := .so
endif
MODULE := target/release/libcooked$(MODULE_SUFFIX)

# Where the evil tests look for evil and its one hard dependency, goto-chg.  -Q is
# deliberate -- the suite must not inherit your configuration -- so an installed
# package is not on `load-path' unless it is named here.  A run that cannot find
# evil says so and skips, which is quiet enough to be mistaken for passing.
EVIL_LOAD_PATH ?=

.PHONY: all test rust-test lisp-test lint checkdoc compile bench clean module

all: test

test: rust-test lisp-test lint

rust-test:
	cargo test

# Install by rename, never by writing over the loaded file.
#
# `mv' within a directory is a rename: it swaps which inode the name points at
# and leaves the old one alive for anyone who still has it mapped.  An Emacs
# holding the previous core keeps running against it -- `/proc/PID/maps' shows it
# as `(deleted)' -- instead of taking the SIGBUS an in-place rewrite would have
# dealt it.  The staging copy is made in the same directory on purpose, so the
# rename cannot fall back to a cross-filesystem copy and stop being atomic.
module:
	cargo build --release
	@mkdir -p target/release
	@cp $(CARGO_TARGET_DIR)/release/libcooked$(MODULE_SUFFIX) $(MODULE).new
	@mv -f $(MODULE).new $(MODULE)

# Depends on `module' because the two halves are one protocol: the defuns the
# core provides and the Lisp that calls them are versioned together, so a suite
# run against a stale artifact fails with a void-function several layers from
# anything it is actually testing.  That is not hypothetical -- it is what a
# scratch-dir build looks like from inside the test output.
lisp-test: module
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

# `cargo clean' only reaches CARGO_TARGET_DIR, so the installed core -- which is
# deliberately not cargo's to manage -- has to be named here or it survives.
clean:
	cargo clean
	rm -f lisp/*.elc tests/*.elc $(MODULE) $(MODULE).new
