//! Handing the child text the user did not type: what is taken out of it, how it is
//! framed, and which of the two the child has asked for.
//!
//! All three together, because they are one decision. The stripping is unconditional and
//! the framing is not, and a caller that reads the mode, then strips, then frames, is
//! reading a mode that can have changed by the time it writes -- so a paste could be
//! bracketed for a child that had just turned bracketing off, which reads the markers as
//! keystrokes, or left unbracketed for one that had just turned it on. Lisp asks for a
//! paste and the answer is composed here, under the lock the mode lives behind.

use super::Term;

/// Bytes turned into a space in anything pasted to the child.
///
/// This is xterm's list, whose `disallowedPasteControls` resource defaults to
/// `BS,DEL,ENQ,EOT,ESC,NUL,STTY` (xterm's own `main.h`, `DEF_DISALLOWED_PASTE_CONTROLS`):
/// NUL, BS, ENQ, EOT, ESC and DEL, plus -- that is what the `STTY` keyword means -- the
/// tty driver's own special characters, which xterm reads live with `tcgetattr`.
///
/// Those are spelled out here at their conventional values rather than read from the
/// child's termios: VINTR C-c, VQUIT C-\, VKILL C-u, VSUSP C-z, VSTART C-q, VSTOP C-s,
/// VWERASE C-w, VLNEXT C-v, VREPRINT C-r, VDISCARD C-o. The core samples the child's
/// termios but keeps only the mode it implies, not `c_cc`, and a program that has
/// remapped its interrupt key is rare enough not to be worth the plumbing -- ghostty made
/// the same call and wrote the same caveat down.
///
/// What is deliberately *not* here is as important: TAB, LF and CR go through untouched,
/// because a paste is expected to contain lines and indentation. LF is dealt with
/// separately by [`Term::paste`], and is the one byte a paste can carry that runs
/// something -- which is why it is confirmed, by Lisp, rather than mangled.
const DISALLOWED: &[u8] = b"\x00\x08\x05\x04\x1b\x7f\x03\x1c\x15\x1a\x11\x13\x17\x16\x12\x0f";

/// `CSI 200 ~`, which tells a child implementing DEC mode 2004 that a paste begins.
const PASTE_START: &[u8] = b"\x1b[200~";

/// `CSI 201 ~`, which tells it the paste ends -- and which therefore may not appear in
/// the middle; see [`bracket`].
const PASTE_END: &[u8] = b"\x1b[201~";

impl Term {
    /// TEXT as this child should receive a paste of it, right now.
    ///
    /// Stripped unconditionally, and in particular not conditionally on bracketed paste,
    /// which is xterm's posture as well. Bracketing tells a *cooperating* reader where
    /// the paste ends; it does nothing about a byte the tty driver acts on before any
    /// reader sees it, and nothing at all about a program that does not implement the
    /// protocol but is being pasted into anyway. A copied escape sequence pasted into a
    /// shell can arrive as key presses, a copied C-c can kill the command the user meant
    /// to paste into, and neither is visible in the text they copied.
    ///
    /// A child that asked for mode 2004 then gets the paste bracketed. One that did not
    /// gets its newlines as carriage returns, because CR is what the Return key
    /// transmits and a line editor bound to CR is what is reading them.
    pub(crate) fn paste(&self, text: &str) -> Vec<u8> {
        let text = strip_controls(text);
        if self.bracketed_paste() {
            bracket(&text).into_bytes()
        } else {
            text.replace('\n', "\r").into_bytes()
        }
    }

    /// TEXT as this child should receive a submitted line of it, right now, the
    /// Return appended as pressing it would send.
    ///
    /// Bracketed when TEXT holds more than one line and the child has asked for
    /// mode 2004 -- the mode read here, under the same lock the framing is built
    /// under, so it cannot move between being read and being acted on, exactly as
    /// [`Term::paste`] reads it. A shell's line editor otherwise reads every
    /// embedded newline as its own Enter and runs the lines one at a time rather
    /// than as the one edit they were composed as.
    ///
    /// A single line, or a child that never asked, gets TEXT with the Return
    /// appended and nothing else: unlike a paste, whose unbracketed newlines
    /// [`Term::paste`] turns into carriage returns because nothing downstream of
    /// it has a line discipline of its own, a submitted line's embedded newlines
    /// are already what the kernel's line discipline treats as line endings, so
    /// rewriting them here would be turning one terminator into another.
    ///
    /// TEXT is not stripped here. `cooked--send-input-string' has already run its
    /// pasted parts through `cooked--strip-paste-controls', keyed off the
    /// `cooked-pasted' text property, and what the user typed needs no stripping
    /// at all; the core cannot see that property, so it cannot do this strip
    /// itself and must not do it again over the whole line.
    pub(crate) fn submit_line(&self, text: &str) -> Vec<u8> {
        let mut bytes = if text.contains('\n') && self.bracketed_paste() {
            bracket(text).into_bytes()
        } else {
            text.as_bytes().to_vec()
        };
        bytes.push(b'\r');
        bytes
    }
}

/// TEXT with every byte of [`DISALLOWED`] turned into a space.
///
/// Turned into spaces rather than dropped, as xterm does: the byte count survives, so a
/// paste that was tampered with looks wrong rather than looking like something shorter
/// that was pasted on purpose.
///
/// Byte-wise, which is safe because every byte in the list is ASCII and no byte of a
/// multi-byte UTF-8 sequence is: a character the user pasted cannot be broken open by
/// this, and the result is still UTF-8.
pub(crate) fn strip_controls(text: &str) -> String {
    let mut bytes = text.as_bytes().to_vec();
    for b in &mut bytes {
        if DISALLOWED.contains(b) {
            *b = b' ';
        }
    }
    String::from_utf8(bytes).expect("only ASCII bytes are replaced, so this is still UTF-8")
}

/// TEXT wrapped in the bracketed-paste markers, made safe to wrap.
///
/// Any end marker inside TEXT is dropped. One left in would close the bracket early and
/// hand whatever followed it to the child as if it had been typed -- which is how a
/// copied line runs something nobody read. The child is told where the paste ends;
/// nothing in the middle gets to say otherwise.
///
/// Kept even though [`strip_controls`] has already turned every ESC in a paste into a
/// space, which leaves no marker for this to find: the two guards answer to different
/// callers -- `cooked--send-input-string' brackets a multi-line submission whose typed
/// half was never stripped -- and a marker assembled without an ESC must still not close
/// the bracket.
///
/// Dropped to a fixed point rather than in one pass over the text, which is the whole
/// reason this is a scan and not a `replace`: deleting the marker in
/// `ESC [ 201 ESC [ 201 ~ ~` joins its neighbours into another one, and a single pass
/// would emit the marker it had just been asked to remove. Each byte is appended and the
/// tail of the output checked, so what is checked is always what the child will read.
pub(crate) fn bracket(text: &str) -> String {
    let mut out = PASTE_START.to_vec();
    for &b in text.as_bytes() {
        out.push(b);
        if out.ends_with(PASTE_END) {
            out.truncate(out.len() - PASTE_END.len());
        }
    }
    out.extend_from_slice(PASTE_END);
    // Still UTF-8: everything removed is a run of ASCII bytes, which no character of the
    // text can have any part of itself inside.
    String::from_utf8(out).expect("only whole ASCII markers are removed")
}

#[cfg(test)]
mod tests {
    use super::*;

    fn term() -> Term {
        Term::new(4, 20)
    }

    #[test]
    fn the_stripped_bytes_are_xterms_list_and_no_more() {
        let strip = "\0\x08\x05\x04\x1b\x7f\x03\x1c\x15\x1a\x11\x13\x17\x16\x12\x0f";
        assert_eq!(strip_controls(strip), " ".repeat(strip.len()));
        // Tabs and newlines are what a paste is made of, and survive.
        assert_eq!(strip_controls("a\tb\nc\rd"), "a\tb\nc\rd");
        // An escape sequence and an interrupt in a copied line become spaces, so the
        // byte count of what was pasted still matches what was copied.
        assert_eq!(strip_controls("rm\x1bx\x03y"), "rm x y");
    }

    #[test]
    fn stripping_leaves_a_multibyte_character_whole() {
        assert_eq!(strip_controls("héllo\x03·"), "héllo ·");
    }

    #[test]
    fn a_pasted_end_marker_cannot_close_the_bracket_early() {
        assert_eq!(bracket("a\x1b[201~rm -rf /"), "\x1b[200~arm -rf /\x1b[201~");
    }

    #[test]
    fn dropping_a_marker_does_not_assemble_another_one() {
        // The inner marker's removal joins `ESC [ 201' to the trailing `~'.
        assert_eq!(bracket("\x1b[201\x1b[201~~x"), "\x1b[200~x\x1b[201~");
    }

    #[test]
    fn an_ordinary_paste_is_bracketed_whole() {
        assert_eq!(bracket("one\ntwo"), "\x1b[200~one\ntwo\x1b[201~");
    }

    #[test]
    fn a_child_that_asked_for_2004_is_told_where_the_paste_ends() {
        let mut t = term();
        t.feed(b"\x1b[?2004h");
        assert_eq!(
            t.paste("ls\nrm\x1b[201~ -rf /"),
            // The ESC became a space before the bracket was ever built, so what is
            // left of the marker is inert text.
            b"\x1b[200~ls\nrm [201~ -rf /\x1b[201~".as_slice()
        );
    }

    #[test]
    fn a_child_that_did_not_ask_reads_newlines_as_returns() {
        let t = term();
        assert_eq!(t.paste("one\ntwo\n"), b"one\rtwo\r".as_slice());
        // And is stripped just the same: bracketing is not what makes a paste safe.
        assert_eq!(t.paste("rm\x03 -rf"), b"rm  -rf".as_slice());
    }

    #[test]
    fn a_multi_line_submission_is_bracketed_when_the_mode_is_held_at_the_call() {
        let mut t = term();
        t.feed(b"\x1b[?2004h");
        assert_eq!(
            t.submit_line("one\ntwo"),
            b"\x1b[200~one\ntwo\x1b[201~\r".as_slice()
        );
    }

    #[test]
    fn a_single_line_submission_is_never_bracketed_even_with_the_mode_held() {
        let mut t = term();
        t.feed(b"\x1b[?2004h");
        assert_eq!(t.submit_line("one"), b"one\r".as_slice());
    }

    #[test]
    fn a_multi_line_submission_with_no_mode_held_keeps_its_embedded_newlines() {
        let t = term();
        // Unlike a paste, whose unbracketed newlines become carriage returns: the
        // kernel's own line discipline already treats these as line endings, so
        // nothing here rewrites them.
        assert_eq!(t.submit_line("one\ntwo"), b"one\ntwo\r".as_slice());
    }
}
