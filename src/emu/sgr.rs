//! `SGR` decoding: the one place that turns `CSI Ps m` into a rendition.
//!
//! Here rather than in [`term`](super::term) because there are two things in this crate
//! that keep a pen and neither is the other's layer. [`term::State`](super::term::State)
//! keeps one for the grid it writes cells into; [`stream::Filter`](super::stream::Filter)
//! keeps one for a byte stream with no grid behind it at all. The escape sequence they
//! are decoding is the same escape sequence, and the failure mode of two decoders is not
//! a crash but a divergence -- `SGR 4:3` curly-underlining a terminal buffer and plainly
//! underlining a comint one, for a year, until somebody notices.
//!
//! A free function over `&mut Style` and `&mut Color` rather than a trait or a `Pen`
//! struct, because those are the two things both callers already hold as separate
//! fields, for their own reasons: the grid's pen is copied onto every cell it writes and
//! wants to stay [`Copy`] and small, while the underline colour rides a side table
//! (see [`Row::extras`](super::cell::Extras)) precisely because it is rare enough not to
//! belong in a per-cell word. Bundling them here would have pushed that choice back onto
//! both callers to buy nothing.

use super::cell::{Attrs, Color, Style};
use super::parser::{Params, ParamsIter};

/// Apply one `CSI Ps m` to PEN and UNDERLINE.
///
/// UNDERLINE is `SGR 58`'s colour, which is separate from PEN for the reason the module
/// docs give, and is reset by `SGR 0` and by an empty parameter list along with
/// everything in PEN -- so a caller cannot hold one of the two back and stay correct.
pub(crate) fn apply(params: &Params, pen: &mut Style, underline: &mut Color) {
    if params.is_empty() {
        *pen = Style::default();
        *underline = Color::Default;
        return;
    }
    let mut iter = params.iter();
    while let Some(param) = iter.next() {
        let Some(&code) = param.first() else { continue };
        match code {
            0 => {
                *pen = Style::default();
                *underline = Color::Default;
            }
            1 => pen.attrs |= Attrs::BOLD,
            2 => pen.attrs |= Attrs::FAINT,
            3 => pen.attrs |= Attrs::ITALIC,
            // `SGR 4` is single; `4:0`-`4:5` name a style. Only the first
            // subparameter is read, which is all the protocol defines.
            4 => match param.get(1) {
                None => pen.attrs.set_underline_style(1),
                Some(&style) => pen.attrs.set_underline_style(style.min(5) as u8),
            },
            5 | 6 => pen.attrs |= Attrs::BLINK,
            7 => pen.attrs |= Attrs::REVERSE,
            8 => pen.attrs |= Attrs::CONCEAL,
            9 => pen.attrs |= Attrs::STRIKE,
            21 | 22 => pen.attrs.remove(Attrs::BOLD | Attrs::FAINT),
            23 => pen.attrs.remove(Attrs::ITALIC),
            24 => pen.attrs.set_underline_style(0),
            25 => pen.attrs.remove(Attrs::BLINK),
            27 => pen.attrs.remove(Attrs::REVERSE),
            28 => pen.attrs.remove(Attrs::CONCEAL),
            29 => pen.attrs.remove(Attrs::STRIKE),
            30..=37 => pen.fg = Color::Indexed((code - 30) as u8),
            38 => pen.fg = extended(param, &mut iter).unwrap_or(pen.fg),
            39 => pen.fg = Color::Default,
            40..=47 => pen.bg = Color::Indexed((code - 40) as u8),
            48 => pen.bg = extended(param, &mut iter).unwrap_or(pen.bg),
            49 => pen.bg = Color::Default,
            // `SGR 58`/`59`: the underline's own colour, parsed by the same
            // `extended` as 38 and 48, so `58:2::r:g:b` and `58:5:n` come free.
            58 => *underline = extended(param, &mut iter).unwrap_or(*underline),
            59 => *underline = Color::Default,
            90..=97 => pen.fg = Color::Indexed((code - 90 + 8) as u8),
            100..=107 => pen.bg = Color::Indexed((code - 100 + 8) as u8),
            _ => {}
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
            match (param.len() >= 6, next()) {
                (true, Some(d)) => Some(Color::Rgb(b as u8, c as u8, d as u8)),
                _ => Some(Color::Rgb(a as u8, b as u8, c as u8)),
            }
        }
        _ => None,
    }
}
