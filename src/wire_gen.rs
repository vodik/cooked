//! Printing lisp/cooked-wire.el from the tables the core already owns.
//!
//! Every fixed-width layout number, every shared tuning default and every key name used
//! to be typed a second time in lisp/, with a pair of tests holding the copies together.
//! A test like that can only say that the two have diverged, never keep them from
//! diverging, and one owner per fact across the seam is a house rule. So Lisp stops
//! typing them: `make wire' runs `cargo run --example gen-wire' and writes what
//! [`cooked_wire_el`] returns.
//!
//! The result is *checked in*, which is the part that looks odd and is not. The package
//! is installed by straight or ELPA and may run against a downloaded prebuilt core, so
//! byte-compilation has to work on a machine with no cargo and no src/ at all — and the
//! numbers are wanted at compile time, since `cooked--do-style-spans' expands them into
//! literals and `cooked--build-passthrough-map' binds every key name before the module
//! is loaded. `make lint` fails while the checked-in file differs from what this prints,
//! the way `cooked--terminfo-digest' fails the suite when terminfo/cooked.ti moves under
//! it.

use crate::emu::NamedKey;
use crate::wire::WireConst;

/// The whole wire layout: each module's half, in the order Lisp reads them.
///
/// `cooked--wire-layout' hands this to a loaded session and [`cooked_wire_el`] prints the
/// generated file from it, so the two cannot describe different tables.
pub(crate) fn layout() -> Vec<WireConst> {
    crate::emu::cell::wire_layout()
        .into_iter()
        .chain(crate::emu::glyph::wire_layout())
        .chain(crate::wire::wire_layout())
        .chain(crate::session::wire_layout())
        .collect()
}

/// lisp/cooked-wire.el, in full, ending in a newline.
pub fn cooked_wire_el() -> String {
    let entries = layout();
    let mut out = String::new();

    out.push_str(HEADER);

    for entry in &entries {
        out.push_str(&format!(
            "(defconst cooked--{} {}\n  {})\n\n",
            entry.name,
            entry.value,
            lisp_string(entry.doc)
        ));
    }

    out.push_str("(defconst cooked--wire-constants\n  '(");
    for (i, entry) in entries.iter().enumerate() {
        if i > 0 {
            out.push_str("\n    ");
        }
        out.push_str(&format!("({} . {})", entry.name, entry.value));
    }
    out.push_str(")\n  ");
    out.push_str(&lisp_string(WIRE_CONSTANTS_DOC));
    out.push_str(")\n\n");

    out.push_str("(defconst cooked--key-names\n  '(");
    out.push_str(&wrapped_names(NamedKey::ALL.iter().map(|key| key.name())));
    out.push_str(")\n  ");
    out.push_str(&lisp_string(KEY_NAMES_DOC));
    out.push_str(")\n\n");

    out.push_str("(defconst cooked--kitty-only-keys\n  '(");
    out.push_str(&wrapped_names(
        NamedKey::ALL
            .iter()
            .filter(|key| key.kitty_only())
            .map(|key| key.name()),
    ));
    out.push_str(")\n  ");
    out.push_str(&lisp_string(KITTY_ONLY_DOC));
    out.push_str(")\n\n");

    out.push_str(FOOTER);
    out
}

/// DOC as an Elisp string literal, indented to sit under a `defconst' name.
///
/// The docstrings are written in the tables as plain text with hard newlines, so the
/// only characters that need anything done to them are the two Elisp reader escapes:
/// a bare `"` would end the string at the first sentence that quoted anything.
fn lisp_string(doc: &str) -> String {
    let escaped = doc.replace('\\', "\\\\").replace('"', "\\\"");
    format!("\"{escaped}\"")
}

/// Symbols as Lisp list elements, wrapped to fit beside a four-space indent.
fn wrapped_names<'a>(names: impl Iterator<Item = &'a str>) -> String {
    let mut out = String::new();
    let mut column = 4;
    for name in names {
        if !out.is_empty() {
            if column + 1 + name.len() > 78 {
                out.push_str("\n    ");
                column = 4;
            } else {
                out.push(' ');
                column += 1;
            }
        }
        out.push_str(name);
        column += name.len();
    }
    out
}

const HEADER: &str = "\
;;; cooked-wire.el --- Constants the native core owns  -*- lexical-binding: t; -*-

;;; Commentary:

;; Generated, do not edit.  `make wire' rewrites this file from the `wire_layout'
;; tables in src/wire.rs, src/emu/cell.rs, src/emu/glyph.rs and src/session.rs and
;; from `NamedKey' in src/emu/term/keypress.rs, and `make lint' fails while what is
;; checked in differs from what those tables say.
;;
;; Checked in rather than built, because the package is installed by straight or ELPA
;; and may run against a downloaded prebuilt core: byte-compilation has to work on a
;; machine with no cargo and no src/ beside it.  And wanted at compile time, because
;; `cooked--do-style-spans' expands these numbers into literals and
;; `cooked--build-passthrough-map' binds every key name before the module is loaded --
;; neither can wait for `cooked--wire-layout' to be callable.
;;
;; So the core is still the one owner, and the check moves to load time: the loaded
;; core reports the same table through `cooked--wire-layout', and
;; `cooked--check-wire-drift' says so when a stale .so disagrees with this file.

;;; Code:

";

const FOOTER: &str = "\
(provide 'cooked-wire)
;;; cooked-wire.el ends here
";

const WIRE_CONSTANTS_DOC: &str = "\
Every constant above, by the name the core gives it.

The same alist `cooked--wire-layout' returns from a loaded core, which is what
makes the comparison in `cooked--check-wire-drift' possible without naming
forty-odd constants a third time.  A name here is the constant above with its
`cooked--' prefix removed.";

const KEY_NAMES_DOC: &str = "\
Every non-character key cooked speaks for, by the symbol Emacs names it with.

The spelling of each is the core's, in `NamedKey' in src/emu/term/keypress.rs,
and this is that table in that order -- the order matters, because
`cooked--build-passthrough-map' binds them in it.  It is written out here
rather than read from `cooked--key-table' because the keymap is built before
the module is loaded.";

const KITTY_ONLY_DOC: &str = "\
Keys with no spelling outside the kitty keyboard protocol.

Pause and Print Screen send nothing in xterm and have no capability in terminfo,
and inventing a sequence for them would put bytes in a program's input that it
never agreed to read.  The protocol gives each a code point of its own, so
`cooked--build-passthrough-map' binds them only while it is negotiated; see
`cooked--kitty-only'.";
