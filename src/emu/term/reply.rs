//! The bytes the terminal owes the child, framed in one place.
//!
//! Every reply is an introducer, a body and a terminator, and the body is the only part
//! that differs between reports. [`frame`] is the one function that joins them, so there
//! is one place to ask whether a body is safe to send. A C0 control or DEL inside a body
//! either ends the sequence early or starts one of its own: a colour name that arrived in
//! an OSC 11 set request and comes back out in the echo is the case that makes the
//! payload attacker-reachable.
//!
//! A refused body is dropped whole rather than trimmed. The child is waiting for one
//! answer, and the tail of a broken sequence does not stop being bytes -- it arrives at
//! the next prompt as typed input.

use super::ColorScheme;
use crate::emu::image::{CellMetrics, PixelSize};

/// How a string-type sequence ended: BEL, or ST (`ESC \`).
///
/// It matters for replies because xterm echoes the terminator it was asked with, and a
/// client scanning its input for BEL hangs on an ST-terminated answer.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Terminator {
    Bel,
    St,
}

impl Terminator {
    /// The terminator the parser reported, which says only whether it was BEL.
    pub(crate) fn from_bell(bell: bool) -> Self {
        if bell { Self::Bel } else { Self::St }
    }

    fn as_str(self) -> &'static str {
        match self {
            Self::Bel => "\x07",
            Self::St => "\x1b\\",
        }
    }
}

/// Which kind of sequence a reply is.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Framing {
    /// `ESC [ BODY`: every report whose answer is our own arithmetic.
    Csi,
    /// `ESC P BODY ESC \`: XTVERSION, DA3, DECRQSS and XTGETTCAP. The terminator is the
    /// part a hand-written reply would forget, and a DCS that is never closed leaves the
    /// child's parser eating everything printed after it.
    Dcs,
    /// `ESC ] CODE ; BODY` with the terminator the query used.
    Osc(u16, Terminator),
    /// `ESC _ G BODY ESC \`: the kitty graphics protocol's answer to a command.
    KittyGraphics,
}

/// Whether TEXT may go between an introducer and a terminator.
///
/// `char::is_control` covers C0, DEL and C1 alike, which is exactly the set that can end
/// a sequence or begin another.
pub(crate) fn is_safe(text: &str) -> bool {
    !crate::emu::text::has_control(text)
}

/// The reply BODY makes under FRAMING, or `None` if BODY is not safe to send.
pub(crate) fn frame(framing: Framing, body: std::fmt::Arguments<'_>) -> Option<Vec<u8>> {
    use std::fmt::Write as _;
    let introducer = match framing {
        Framing::Csi => "\x1b[",
        Framing::Dcs => "\x1bP",
        Framing::Osc(..) => "\x1b]",
        Framing::KittyGraphics => "\x1b_G",
    };
    let mut reply = String::from(introducer);
    if let Framing::Osc(code, _) = framing {
        // Cannot fail: `String`'s `write_fmt` is infallible.
        let _ = write!(reply, "{code};");
    }
    let start = reply.len();
    let _ = reply.write_fmt(body);
    if !is_safe(&reply[start..]) {
        return None;
    }
    reply.push_str(match framing {
        Framing::Csi => "",
        Framing::Dcs | Framing::KittyGraphics => "\x1b\\",
        Framing::Osc(_, terminator) => terminator.as_str(),
    });
    Some(reply.into_bytes())
}

/// `ESC ] CODE ; PAYLOAD` with TERMINATOR, for the queries only Emacs can answer.
///
/// The default colours resolve against the buffer's faces rather than any palette the
/// core holds, so Lisp decides the payload. The framing still happens here, because the
/// payload can be a string the child supplied.
pub(crate) fn osc_reply(code: u16, payload: &str, terminator: Terminator) -> Option<Vec<u8>> {
    frame(Framing::Osc(code, terminator), format_args!("{payload}"))
}

/// The DSR a child gets for the colour scheme, whether it asked or subscribed to mode
/// 2031. A child cannot tell a solicited answer from an unsolicited one, so both come from
/// here.
pub(crate) fn color_scheme_report(scheme: ColorScheme) -> Vec<u8> {
    frame(Framing::Csi, format_args!("?997;{scheme}n"))
        .expect("a colour scheme report is digits and punctuation")
}

/// The mode 2048 report: `CSI 48 ; rows ; cols ; height px ; width px t`.
///
/// Height before width in both units, which is `14t`'s order and not XTSMGRAPHICS'. The
/// pixel fields are 0 when Emacs has not reported a cell size. `14t` falls silent in that
/// case, but silence here would withhold the row and column count too, and zero is what
/// the tty's own `ws_xpixel`/`ws_ypixel` say at the same moment.
pub(crate) fn size_report(rows: usize, cols: usize, metrics: Option<CellMetrics>) -> Vec<u8> {
    let area = metrics.map_or_else(PixelSize::default, |m| m.text_area(rows, cols));
    frame(
        Framing::Csi,
        format_args!("48;{rows};{cols};{};{}t", area.h, area.w),
    )
    .expect("a size report is digits and punctuation")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn an_osc_reply_echoes_the_terminator_it_was_asked_with() {
        assert_eq!(
            osc_reply(11, "rgb:0000/0000/0000", Terminator::Bel).unwrap(),
            b"\x1b]11;rgb:0000/0000/0000\x07"
        );
        assert_eq!(
            osc_reply(11, "rgb:ffff/ffff/ffff", Terminator::St).unwrap(),
            b"\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
        );
    }

    #[test]
    fn a_body_that_could_close_the_sequence_is_refused_under_every_framing() {
        for framing in [
            Framing::Csi,
            Framing::Dcs,
            Framing::Osc(11, Terminator::Bel),
            Framing::KittyGraphics,
        ] {
            for body in ["red\x07\x1b]0;pwned", "red\x1b\\", "red\x7f", "red\u{9c}"] {
                assert_eq!(frame(framing, format_args!("{body}")), None, "{framing:?}");
            }
        }
    }

    #[test]
    fn each_framing_has_its_own_introducer_and_terminator() {
        let body = format_args!("x");
        assert_eq!(frame(Framing::Csi, body).unwrap(), b"\x1b[x");
        assert_eq!(
            frame(Framing::Dcs, format_args!("x")).unwrap(),
            b"\x1bPx\x1b\\"
        );
        assert_eq!(
            frame(Framing::KittyGraphics, format_args!("x")).unwrap(),
            b"\x1b_Gx\x1b\\"
        );
    }
}
