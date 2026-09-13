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
            // `SGR 53`/`55`. 54 would be ECMA-48's "not framed or encircled", which
            // clears 51 and 52; neither is kept, so 54 has nothing to clear.
            53 => pen.attrs |= Attrs::OVERLINE,
            55 => pen.attrs.remove(Attrs::OVERLINE),
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

/// PEN and UNDERLINE as the `CSI Ps m` parameters that would recreate them from nothing:
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
pub(crate) fn describe(pen: Style, underline: Color) -> String {
    let mut out = String::from("0");
    let mut push = |param: std::fmt::Arguments<'_>| {
        use std::fmt::Write as _;
        // Cannot fail: `String`'s `write_fmt` is infallible.
        let _ = write!(out, ";{param}");
    };
    let attrs = pen.attrs;
    for (flag, code) in [(Attrs::BOLD, 1), (Attrs::FAINT, 2), (Attrs::ITALIC, 3)] {
        if attrs.contains(flag) {
            push(format_args!("{code}"));
        }
    }
    match attrs.underline_style() {
        0 => {}
        1 => push(format_args!("4")),
        style => push(format_args!("4:{style}")),
    }
    for (flag, code) in [
        (Attrs::BLINK, 5),
        (Attrs::REVERSE, 7),
        (Attrs::CONCEAL, 8),
        (Attrs::STRIKE, 9),
        (Attrs::OVERLINE, 53),
    ] {
        if attrs.contains(flag) {
            push(format_args!("{code}"));
        }
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
    color(underline, 58, false);
    out
}
