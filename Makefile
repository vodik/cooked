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

# Every wait in either suite is a deadline on a real child through a real pty,
# so every one of them is a bet about how fast this machine is.  The numbers
# were chosen on an idle laptop; on a shared CI runner, or on that same laptop
# while cargo is linking, the bet is wrong and the code is not.
# COOKED_TEST_TIMEOUT_SCALE stretches all of them at once, which is why
# `src/session.rs::resize_reaches_the_child' -- the one that failed at a load
# average of 38 and passed in isolation on the same commit -- is a knob away
# from green rather than a rewrite away.
#
# Four under CI and one otherwise.  A developer wants a wrong deadline to fail
# fast; CI wants it not to fail at all, and CI's runners are shared, throttled
# and unpredictable in a way no local number can anticipate.
ifdef CI
COOKED_TEST_TIMEOUT_SCALE ?= 4
endif

# Exported only when it has a value, and this `ifdef' is the whole reason the
# parsers on both sides insist on a *positive* number.  A bare
# `export COOKED_TEST_TIMEOUT_SCALE' exports the empty string when the variable
# was never set, `string-to-number' reads "" as 0, and multiplying by that zero
# expires every deadline in the suite before it is taken -- so every wait
# returns at once, every test needing a child fails, and nothing in the output
# says why.  The guard on the other side catches it; not exporting an empty
# value means it never has to.
ifdef COOKED_TEST_TIMEOUT_SCALE
export COOKED_TEST_TIMEOUT_SCALE
endif

# Which tests to run, as an ERT selector.  `t' is all of them; the tags are the
# platform and dependency axis, one per `skip-unless' -- see the Commentary in
# tests/cooked-tests.el.
#
#   make lisp-test SELECTOR='(not (tag zsh))'
#   make lisp-test SELECTOR='(tag evil)'
SELECTOR ?= t

.PHONY: all test rust-test lisp-test lisp-test-parallel lint checkdoc citations \
        compile bench bench-quick clean module terminfo

all: test

test: rust-test lisp-test lint

# `cargo test` is both suites: the unit tests under `src/', and the property test in
# `tests/delta_replay.rs' that replays a drain's deltas against the grid they came from.
#
# The property test runs a fixed 1024 cases here, which is a second or so and the right
# size for a gate -- a suite whose runtime nobody can predict is a suite people learn to
# skip. `PROPTEST_CASES' in the environment overrides it, and is how a suspicion gets
# chased: `PROPTEST_CASES=100000 make rust-test' is a few minutes and a much wider net.
# Anything it finds shrinks and lands in `tests/delta_replay.regressions', which is
# committed and replayed ahead of the random cases on every subsequent run.
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
#
# Installed only when the bytes differ, which is not an optimisation of the copy
# -- the copy is milliseconds -- but of the *mtime*.  An unconditional install
# re-times the artifact on every run, and everything downstream that compares
# timestamps then has to redo itself: the per-file test stamps below were
# rebuilding all seventeen files after any target that touched `module',
# including one that had just rebuilt nothing.  Skipping an identical install
# cannot reintroduce the SIGBUS this target exists to avoid, because it writes
# nothing at all.
module:
	cargo build --release
	@mkdir -p target/release
	@if ! cmp -s $(CARGO_TARGET_DIR)/release/libcooked$(MODULE_SUFFIX) $(MODULE); then \
	  cp $(CARGO_TARGET_DIR)/release/libcooked$(MODULE_SUFFIX) $(MODULE).new && \
	  mv -f $(MODULE).new $(MODULE); \
	fi

# Depends on `module' because the two halves are one protocol: the defuns the
# core provides and the Lisp that calls them are versioned together, so a suite
# run against a stale artifact fails with a void-function several layers from
# anything it is actually testing.  That is not hypothetical -- it is what a
# scratch-dir build looks like from inside the test output.
lisp-test: module
	$(BATCH) $(EVIL_LOAD_PATH) -l ert -l cooked-tests.el \
	  --eval '(ert-run-tests-batch-and-exit (quote $(SELECTOR)))'

# The same tests, one Emacs per file, so that `make -j8 lisp-test-parallel' uses
# the cores this machine has.  The serial run is about eighty seconds and most
# of it is spent waiting on children rather than computing, which is the shape
# of workload that parallelises almost perfectly.
#
# Stamps rather than .PHONY targets, because a stamp is what lets make skip a
# file whose tests cannot have changed.  Each depends on its own test file, on
# every file in `lisp/' -- the code under test -- and on the module, so editing
# one renderer reruns everything and editing one test file reruns one file.
# They are *not* wired into `make test': a stamp tree can be stale in ways a
# release gate must not tolerate, and `test' exists to be the thing that always
# actually runs.  This is the inner-loop target.
#
# Each Emacs loads the whole suite and selects, rather than loading one file;
# `cooked-tests-run-file' explains why.
# `cooked-tests*.el' and not `cooked-tests-*.el': the runner file itself holds a
# test, and the hyphenated glob quietly left it out -- 636 tests here against
# 637 from `lisp-test', which is exactly the kind of shortfall a parallel
# target must not be able to hide.  `cooked-bench.el' is not matched and should
# not be; it is the benchmark, and `cooked-tests-bench.el' is its tests.
TEST_FILES := $(wildcard tests/cooked-tests*.el)
TEST_STAMPS := $(patsubst tests/%.el,target/test-stamps/%.stamp,$(TEST_FILES))

lisp-test-parallel: $(TEST_STAMPS)

target/test-stamps/%.stamp: tests/%.el $(wildcard lisp/*.el) $(MODULE)
	@mkdir -p $(@D)
	@$(BATCH) $(EVIL_LOAD_PATH) -l ert -l cooked-tests.el \
	  --eval '(cooked-tests-run-file "$<")'
	@touch $@

# The compiled database we ship, so that a machine with no `tic' still gets a
# terminal that describes what we implement.  Both subdirectory spellings are
# written: ncurses is built to name them either for the entry's first letter or
# for its hex code, and which one this `tic' chose says nothing about the ncurses
# that will read it.  Regenerate whenever terminfo/cooked.ti changes -- though
# `cooked--terminfo-usable-p' notices if you forget, and rebuilds locally.
#
# The `infocmp' loop is the verification, and it is not ceremony.  `tic' reports
# on the source it was handed; everything after it here is this Makefile copying
# compiled files around by hand, and a `tic' that exited 0 says nothing about
# whether ncurses can still find and read what we ship.  So each entry is looked
# up again by name in `terminfo/db', decompiled, recompiled into a scratch
# database, and decompiled a second time: the two decompilations must be
# identical.  A truncated copy, or a directory named in a spelling this ncurses
# will not look in, fails the first `infocmp'; an extended capability that does
# not survive a compile -- and cooked's description is full of them, `-x' being
# load-bearing here -- shows up as a diff.  Either way it fails now rather than
# on a user's machine, where the symptom is a terminal that mostly works.
#
# `sed 1d' drops infocmp's header comment, which names the file it read and so
# differs between the two runs by construction.  Every entry is checked and not
# just `cooked': the two colour variants are what most sessions actually run
# under.  `terminfo/rt.*' is scratch, cleared on the way in and removed on the
# way out, so an interrupted run leaves nothing behind for the next one to trust.
terminfo:
	@rm -rf terminfo/db terminfo/rt.ti terminfo/rt.db && mkdir -p terminfo/db && \
	  tic -x -o terminfo/db terminfo/cooked.ti && \
	  for dir in terminfo/db/*/; do \
	    for entry in "$$dir"*; do \
	      name=$$(basename "$$entry"); \
	      hex=$$(printf '%02x' "'$$name"); \
	      mkdir -p "terminfo/db/$$hex" && cp "$$entry" "terminfo/db/$$hex/$$name"; \
	    done; \
	  done; \
	  for name in $$(find terminfo/db -type f | sed 's|.*/||' | sort -u); do \
	    infocmp -A terminfo/db -x -1 "$$name" | sed 1d > terminfo/rt.ti && \
	    tic -x -o terminfo/rt.db terminfo/rt.ti && \
	    infocmp -A terminfo/rt.db -x -1 "$$name" | sed 1d | \
	      diff -u terminfo/rt.ti - || exit 1; \
	  done && rm -rf terminfo/rt.ti terminfo/rt.db && \
	  find terminfo/db -type f | sort | sed 's/^/  /'

lint: compile checkdoc citations
	cargo fmt --check
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

# Advisory, like `checkdoc', and for the same reason rather than out of caution.
#
# The comments in this tree are unusually detailed and are therefore trusted, so
# a comment naming a function is an assertion -- and until now it was the only
# assertion here that nothing checked.  A sweep found eleven citing something
# that does not exist, nine of them mechanically detectable, and the category
# that recurs is a cited *test* name: renaming a defun breaks its callers, while
# renaming an `ert-deftest' breaks nothing, so a docstring naming one can be
# wrong for as long as nobody reads it.  One test name managed to be wrong in
# both directions inside a month.
#
# It does not gate, because two of the four findings on the run that landed this
# were prose deliberately naming something gone -- "the fifth table,
# `cooked--special-keys'", "the replacement for `session::is_errno'" -- which is
# accurate writing about history and not a defect.  Gating would force those to
# be reworded to suit the checker, or kept in an exemption list, and an
# exemption list is a second thing that goes stale with nothing checking it.
# The oracle underneath is deliberately loose as well: a name counts as real if
# it appears anywhere in the tree's code, which is the right question for prose
# but not a foundation to fail a build on.  So it is `checkdoc''s bargain --
# read the output, do not chase it to zero -- and it runs inside `lint' so that
# it is read.
#
# The rustdoc half is in here because it is the same job.  It was unreadable
# before: nineteen "links to private item" warnings, which in a cdylib whose
# every internal type is private is the lint describing the crate rather than
# finding a defect, and a genuinely broken link arrived in the middle of them
# and was not seen.  The shape warning is now silenced at the crate root and the
# defect warning kept -- see the comment on the `allow' in src/lib.rs -- which
# turned up nineteen broken links that had been invisible.  Four remain, three
# in `src/emu/screen.rs' and one in `src/emu/stream.rs'; when they are fixed
# this can gate on the Rust side alone by adding RUSTDOCFLAGS='-D warnings' to
# the `cargo doc' line.
#
# `--document-private-items' is not optional: without it this crate documents
# about four items, because everything else is private, and rustdoc checks the
# links of only what it documents.
citations:
	@$(BATCH) $(EVIL_LOAD_PATH) -l ert -l cooked-tests.el \
	  -l scripts/check-citations.el -f cooked-citations-batch
	@cargo doc --no-deps --document-private-items 2>&1 | \
	  grep -E '^(warning|error)' || true

# Byte-compiled, and that is not a detail: every figure this suite produced before
# now was measured on interpreted Lisp that no user ever runs.  Compiled, a styled
# 24x80 frame conses 1,858 cells against 14,112, per-frame styled p50 goes 0.575 to
# 0.183 ms, and the UNSTABLE flag fires on three rows rather than eight -- so most
# of the fat tail the variance check was built to filter out is the harness's own
# and not cooked's.  `cooked--face-packed' on a cache hit conses 42 net interpreted
# and *nothing* compiled, which is what its docstring has always claimed.
#
# Its own step rather than a dependency on `compile', which ends in
# `rm -f lisp/*.elc' on purpose: that target exists to fail the build on a warning,
# and leaving its output behind would silently change what `lisp-test' loads.  The
# same reasoning applies here in reverse, so the `.elc' are removed again when this
# finishes -- from a `trap', so it happens when the bench fails or is interrupted
# too, and a stale `.elc' cannot follow you into the next test run.
#
# `lisp-test' stays interpreted.  A readable backtrace is worth more there than
# speed, and the suite is not measuring anything.
bench:
	$(BATCH) -l bytecomp --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(wildcard lisp/*.el)
	cargo test --release --test throughput -- --ignored --nocapture
	@trap 'rm -f lisp/*.elc' EXIT INT TERM; $(BATCH) -l cooked-bench.el -f cooked-bench

# The same benchmarks, sized to finish inside ten seconds, for the question
# "did I just make it slower by an order of magnitude" -- which is worth asking
# on every commit and is not worth eighty seconds.  It is a smoke test and not a
# measurement: `cooked-bench-min-duration' drops from 0.5s to 0.02s, so each
# case gets a fortieth of the samples and its p99 and its GC counts are noise.
# Nothing produced here belongs in a commit message.  Take a number from
# `make bench'.
#
# The load guard is forced off for the same reason.  It exists to stop a
# *measurement* being taken on a busy machine, and refusing to run a smoke test
# because something else is compiling would only teach people to skip the smoke
# test.
#
# Byte-compiled and cleaned up from a `trap', exactly as `bench' is, and that is
# not copied ceremony: this target measures the same Lisp and would report
# interpreted figures three times the real ones without it, and a `.elc' left
# behind by an interrupted run silently changes what the next `lisp-test'
# loads.  The Rust throughput benchmark is left to `bench' -- it is a release
# build, so it cannot be made to fit in ten seconds by asking for fewer samples.
bench-quick:
	$(BATCH) -l bytecomp --eval '(setq byte-compile-error-on-warn t)' \
	  -f batch-byte-compile $(wildcard lisp/*.el)
	@trap 'rm -f lisp/*.elc' EXIT INT TERM; \
	  COOKED_BENCH_FORCE=1 $(BATCH) \
	    --eval '(setq cooked-bench-min-duration 0.02)' \
	    -l cooked-bench.el -f cooked-bench

# `cargo clean' only reaches CARGO_TARGET_DIR, so the installed core -- which is
# deliberately not cargo's to manage -- has to be named here or it survives.
clean:
	cargo clean
	rm -rf target/test-stamps
	rm -f lisp/*.elc tests/*.elc $(MODULE) $(MODULE).new
