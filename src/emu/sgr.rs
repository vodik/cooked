//! `SGR` decoding: the one place that turns `CSI Ps m` into a rendition.
//!
//! Here rather than in [`term`](super::term) because there are two things in this crate
//! that keep a pen and neither is the other's layer. `term::State`
//! keeps one for the grid it writes cells into; [`stream::Filter`](super::stream::Filter)
//! keeps one for a byte stream with no grid behind it at all. The escape sequence they
//! are decoding is the same escape sequence, and the failure mode of two decoders is not
//! a crash but a divergence -- `SGR 4:3` curly-underlining a terminal buffer and plainly
//! underlining a comint one, for a year, until somebody notices.
//!
//! A free function over `&mut Style`, which is the whole rendition, underline colour
//! included: both callers intern the result into a [`StyleId`](super::style::StyleId)
//! when they write with it.

use super::cell::{Attrs, Color, Style};
use super::parser::{Params, ParamsIter};

/// An attribute that is one bit of [`Attrs`], with the SGR codes that set and clear it.
#[derive(Debug, Clone, Copy)]
pub(crate) struct Flag {
    pub(crate) set: u16,
    pub(crate) reset: u16,
    pub(crate) attr: Attrs,
}

/// Every one-bit attribute, in the order DECRQSS spells them.
///
/// The one table of which number means which bit, read by [`apply`] to set and clear,
/// by [`describe`] to answer, and by XTPUSHSGR to name the parts of a selective push.
/// Bold and faint share their reset, 22, as ECMA-48 has it. Overline is last because it
/// is the one XTPUSHSGR's numbering does not include; see [`PUSHABLE`].
pub(crate) const FLAGS: [Flag; 8] = [
    Flag {
        set: 1,
        reset: 22,
        attr: Attrs::BOLD,
    },
    Flag {
        set: 2,
        reset: 22,
        attr: Attrs::FAINT,
    },
    Flag {
        set: 3,
        reset: 23,
        attr: Attrs::ITALIC,
    },
    Flag {
        set: 5,
        reset: 25,
        attr: Attrs::BLINK,
    },
    Flag {
        set: 7,
        reset: 27,
        attr: Attrs::REVERSE,
    },
    Flag {
        set: 8,
        reset: 28,
        attr: Attrs::CONCEAL,
    },
    Flag {
        set: 9,
        reset: 29,
        attr: Attrs::STRIKE,
    },
    Flag {
        set: 53,
        reset: 55,
        attr: Attrs::OVERLINE,
    },
];

/// The flags a selective XTPUSHSGR can name, which are xterm's and stop short of
/// overline.
pub(crate) const PUSHABLE: &[Flag] = FLAGS.split_at(7).0;

/// Apply one `CSI Ps m` to PEN.
pub(crate) fn apply(params: &Params, pen: &mut Style) {
    if params.is_empty() {
        *pen = Style::default();
        return;
    }
    let mut iter = params.iter();
    while let Some(param) = iter.next() {
        let Some(&code) = param.first() else { continue };
        match code {
            0 => *pen = Style::default(),
            // `SGR 4` is single; `4:0`-`4:5` name a style. Only the first
            // subparameter is read, which is all the protocol defines.
            4 => match param.get(1) {
                None => pen.attrs.set_underline_style(1),
                Some(&style) => pen.attrs.set_underline_style(style.min(5) as u8),
            },
            // Rapid blink is kept as blink, and 21 as the bold-and-faint reset, since the
            // pen has no separate bit for either.
            6 => pen.attrs |= Attrs::BLINK,
            21 => pen.attrs.remove(Attrs::BOLD | Attrs::FAINT),
            24 => pen.attrs.set_underline_style(0),
            30..=37 => pen.fg = Color::Indexed((code - 30) as u8),
            38 => pen.fg = extended(param, &mut iter).unwrap_or(pen.fg),
            39 => pen.fg = Color::Default,
            40..=47 => pen.bg = Color::Indexed((code - 40) as u8),
            48 => pen.bg = extended(param, &mut iter).unwrap_or(pen.bg),
            49 => pen.bg = Color::Default,
            // `SGR 58`/`59`: the underline's own colour, parsed by the same
            // `extended` as 38 and 48, so `58:2::r:g:b` and `58:5:n` come free.
            58 => pen.underline = extended(param, &mut iter).unwrap_or(pen.underline),
            59 => pen.underline = Color::Default,
            90..=97 => pen.fg = Color::Indexed((code - 90 + 8) as u8),
            100..=107 => pen.bg = Color::Indexed((code - 100 + 8) as u8),
            // The one-bit attributes. 54, ECMA-48's "not framed or encircled", clears 51
            // and 52, neither of which is kept, so it has nothing to clear.
            _ => {
                for flag in &FLAGS {
                    if flag.set == code {
                        pen.attrs |= flag.attr;
                    } else if flag.reset == code {
                        pen.attrs.remove(flag.attr);
                    }
                }
            }
        }
    }
}

/// `38;5;n` / `38;2;r;g;b` and their colon-subparameter spellings.
fn extended(param: &[u16], iter: &mut ParamsIter<'_>) -> Option<Color> {
    let mut subs = param[1..].iter().copied();
    let mut next = || {
        subs.next()
            .or_else(|| iter.next().and_then(|p| p.first().copied()))
    };
    match next()? {
        5 => Some(Color::Indexed(next()? as u8)),
        // The colon form permits an empty color-space id: 38:2::R:G:B
        2 => {
            let (a, b, c) = (next()?, next()?, next()?);
            // A fourth value only exists in the colon form, where the colour-space id
            // leads. Asking for one otherwise takes the next parameter, so
            // `38;2;r;g;b;48;2;r;g;b` swallowed the `48` and read its colour as codes.
            if param.len() >= 6 {
                next().map(|d| Color::Rgb(b as u8, c as u8, d as u8))
            } else {
                Some(Color::Rgb(a as u8, b as u8, c as u8))
            }
        }
        _ => None,
    }
}

/// PEN as the `CSI Ps m` parameters that would recreate them from nothing:
/// [`apply`] run backwards, for DECRQSS.
///
/// Always led by `0`, which is what xterm sends and what makes the answer a *setting*
/// rather than a delta: a child that saves the reply and replays it later gets this pen
/// whatever the pen had become in between. neovim's truecolour probe accepts the reply
/// with or without it.
///
/// Every value has exactly one spelling, chosen to be the one [`apply`] reads back to
/// the same value, and that constraint decides the two cases where the protocol offers a
/// choice:
///
/// - A palette index below 16 is written `31` or `91` rather than `38:5:1`. The two are
///   one [`Color::Indexed`] once parsed, so nothing distinguishes them to answer with,
///   and the short form is what every child that has not asked for 256 colours sent.
/// - A direct colour is written in the colon form with an empty colour-space id,
///   `48:2::1:2:3`. That is the only spelling that is a single parameter, so the reply
///   cannot be misread by a parser that splits on semicolons first, and it is the form
///   neovim sets and then looks for when it decides whether to turn on
///   `termguicolors`.
///
/// Lossy exactly where [`apply`] is: `SGR 6` (rapid blink) reads back as `5`, and `21`
/// as nothing, because the pen does not keep the difference. The answer describes the
/// pen, not the bytes that built it.
pub(crate) fn describe(pen: Style) -> String {
    let mut out = String::from("0");
    let mut push = |param: std::fmt::Arguments<'_>| {
        use std::fmt::Write as _;
        // Cannot fail: `String`'s `write_fmt` is infallible.
        let _ = write!(out, ";{param}");
    };
    let attrs = pen.attrs;
    // In code order, with the underline, which is a style rather than a bit, in its place
    // between italic and blink.
    let (before, after) = FLAGS.split_at(3);
    for flag in before.iter().filter(|flag| attrs.contains(flag.attr)) {
        push(format_args!("{}", flag.set));
    }
    match attrs.underline_style() {
        0 => {}
        1 => push(format_args!("4")),
        style => push(format_args!("4:{style}")),
    }
    for flag in after.iter().filter(|flag| attrs.contains(flag.attr)) {
        push(format_args!("{}", flag.set));
    }
    // The base is the parameter that introduces the extended form, 38, 48 or 58; the
    // short forms sit at fixed offsets from it only for the first two, which is why
    // the underline colour passes `false` and always takes the long spelling.
    let mut color = |color: Color, base: u16, short: bool| match color {
        Color::Default => {}
        Color::Indexed(i) if short && i < 8 => push(format_args!("{}", base - 8 + u16::from(i))),
        Color::Indexed(i) if short && i < 16 => {
            push(format_args!("{}", base + 52 + u16::from(i) - 8))
        }
        Color::Indexed(i) => push(format_args!("{base}:5:{i}")),
        Color::Rgb(r, g, b) => push(format_args!("{base}:2::{r}:{g}:{b}")),
    };
    color(pen.fg, 38, true);
    color(pen.bg, 48, true);
    color(pen.underline, 58, false);
    out
}
