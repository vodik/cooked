//! Print lisp/cooked-wire.el on stdout. `make wire' redirects it into place.
//!
//! An example rather than a `src/bin/', because a bin is part of `src/' and the cdylib
//! Emacs loads has the dependency list it has on purpose — see the note above
//! `[dev-dependencies]' in Cargo.toml. An example links the rlib and adds nothing to
//! what ships, and `cargo clippy --all-targets' still covers it.

fn main() {
    print!("{}", cooked::wire_gen::cooked_wire_el());
}
