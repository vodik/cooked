//! Renditions: SGR, underline colours, background colour erase and XTPUSHSGR.

use super::*;

#[test]
fn sgr_sets_colors_and_attributes() {
    let mut t = term(2, 20, b"\x1b[1;31mred\x1b[0m.");
    let delta = t.drain();
    let runs = &delta.rows.iter().find(|r| r.index == 0).unwrap().runs;
    assert_eq!(runs[0].text, "red");
    assert_eq!(runs[0].style.fg, Color::Indexed(1));
    assert!(runs[0].style.attrs.contains(Attrs::BOLD));
    assert_eq!(runs[1].text, ".");
    assert_eq!(runs[1].style, Style::default());
}

#[test]
fn overline_is_set_by_53_and_cleared_by_55_and_0() {
    let style = |input: &[u8]| term(2, 20, input).screen().row(0).unwrap().runs()[0].style;
    assert!(style(b"\x1b[53mx").attrs.contains(Attrs::OVERLINE));
    // Its own bit, not a reading of another: 55 leaves an underline alone, and 24
    // leaves the overline alone.
    let both = style(b"\x1b[4:3;53m\x1b[55mx").attrs;
    assert!(!both.contains(Attrs::OVERLINE));
    assert_eq!(both.underline_style(), 3);
    let kept = style(b"\x1b[4:3;53m\x1b[24mx").attrs;
    assert!(kept.contains(Attrs::OVERLINE));
    assert!(!kept.contains(Attrs::UNDERLINE));
    assert!(!style(b"\x1b[53;5m\x1b[0mx").attrs.contains(Attrs::OVERLINE));
    assert!(style(b"\x1b[53m\x1b[25mx").attrs.contains(Attrs::OVERLINE));
}

#[test]
fn truecolor_arrives_in_both_spellings() {
    let semi = term(2, 20, b"\x1b[38;2;10;20;30mx");
    assert_eq!(
        semi.screen().row(0).unwrap().runs()[0].style.fg,
        Color::Rgb(10, 20, 30)
    );

    let colon = term(2, 20, b"\x1b[38:2::10:20:30mx");
    assert_eq!(
        colon.screen().row(0).unwrap().runs()[0].style.fg,
        Color::Rgb(10, 20, 30)
    );
}

#[test]
fn indexed_256_color() {
    let t = term(2, 20, b"\x1b[38;5;200mx");
    assert_eq!(
        t.screen().row(0).unwrap().runs()[0].style.fg,
        Color::Indexed(200)
    );
}

#[test]
fn underline_styles_arrive_from_the_subparameter() {
    for (input, want) in [
        (&b"\x1b[4mx"[..], 1u8),
        (&b"\x1b[4:1mx"[..], 1),
        (&b"\x1b[4:3mx"[..], 3),
        (&b"\x1b[4:5mx"[..], 5),
    ] {
        let t = term(2, 8, input);
        let style = t.screen().row(0).unwrap().runs()[0].style;
        assert!(style.attrs.contains(Attrs::UNDERLINE), "{input:?}");
        assert_eq!(style.attrs.underline_style(), want, "{input:?}");
    }
}

#[test]
fn underline_is_removed_by_both_spellings() {
    for input in [&b"\x1b[4:3m\x1b[4:0mx"[..], &b"\x1b[4:3m\x1b[24mx"[..]] {
        let style = term(2, 8, input).screen().row(0).unwrap().runs()[0].style;
        assert!(!style.attrs.contains(Attrs::UNDERLINE), "{input:?}");
        assert_eq!(style.attrs.underline_style(), 0, "{input:?}");
    }
}

#[test]
fn underline_colour_parses_both_spellings() {
    let indexed = term(2, 8, b"\x1b[4m\x1b[58;5;196mx");
    assert_eq!(
        indexed.screen().row(0).unwrap().runs()[0].underline,
        Color::Indexed(196)
    );
    let rgb = term(2, 8, b"\x1b[4m\x1b[58:2::255:0:0mx");
    assert_eq!(
        rgb.screen().row(0).unwrap().runs()[0].underline,
        Color::Rgb(255, 0, 0)
    );
    let reset = term(2, 8, b"\x1b[4m\x1b[58;5;196m\x1b[59mx");
    assert_eq!(
        reset.screen().row(0).unwrap().runs()[0].underline,
        Color::Default
    );
}

#[test]
fn a_wide_character_keeps_its_underline_colour() {
    // The colour has to land on the lead cell. `Row::runs` skips continuation cells,
    // so a colour recorded one column to the right disappears entirely.
    let t = term(2, 8, b"\x1b[4;58;5;196m\xe5\xb9\xb8");
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.len(), 1, "{runs:?}");
    assert_eq!(runs[0].underline, Color::Indexed(196));
}

#[test]
fn a_combining_mark_does_not_move_an_underline_colour() {
    let t = term(2, 8, b"\x1b[4;58;5;196me\xcc\x81x");
    let runs = t.screen().row(0).unwrap().runs();
    assert!(
        runs.iter().all(|r| r.underline == Color::Indexed(196)),
        "{runs:?}"
    );
}

#[test]
fn an_underline_colour_splits_a_run() {
    // Two cells differing only in underline colour are not the same style.
    let t = term(2, 8, b"\x1b[4ma\x1b[58;5;196mb");
    assert_eq!(t.screen().row(0).unwrap().runs().len(), 2);
}

#[test]
fn an_erase_drops_the_underline_colour() {
    let t = term(2, 8, b"\x1b[4;58;5;196m\x1b[41mab\x1b[K");
    let runs = t.screen().row(0).unwrap().runs();
    let last = runs.last().unwrap();
    assert_eq!(last.underline, Color::Default);
    assert!(!last.style.attrs.contains(Attrs::UNDERLINE));
}

#[test]
fn an_underline_colour_survives_a_rewrap() {
    // The side table is keyed by column, so a reflow has to rebase it the way the
    // combining-mark table is rebased or the colour lands on the wrong character.
    let mut t = term(2, 4, b"ab\x1b[4;58;5;196mcd");
    t.resize(2, 8);
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert_eq!(runs[0].text, "ab");
    assert_eq!(runs[1].text, "cd");
    assert_eq!(runs[1].underline, Color::Indexed(196));
}

#[test]
fn overwriting_a_cell_retires_its_underline_colour() {
    // `Row::set` retires whatever the old occupant had attached to the cell, which
    // is what this proves: the colour goes with the character it belonged to.
    let t = term(2, 8, b"\x1b[4;58;5;196mab\x1b[1G\x1b[mxy");
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.len(), 1, "{runs:?}");
    assert_eq!(runs[0].text, "xy");
    assert_eq!(runs[0].underline, Color::Default);
}

#[test]
fn an_erased_row_forgets_its_underline_colours() {
    let t = term(2, 8, b"\x1b[4;58;5;196mab\x1b[1G\x1b[K\x1b[mxy");
    assert_eq!(
        t.screen().row(0).unwrap().runs()[0].underline,
        Color::Default
    );
}

#[test]
fn dch_spares_an_underline_colour_on_a_column_it_never_touched() {
    // Dropping the row's whole table on DCH would take every colour on the row with it,
    // including ones to the left of the cut.
    let t = term(2, 8, b"\x1b[58;5;196ma\x1b[mbcdef\x1b[5G\x1b[1P");
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs[0].text, "a");
    assert_eq!(runs[0].underline, Color::Indexed(196));
    assert_eq!(runs[1].text, "bcdf");
    assert_eq!(runs[1].underline, Color::Default);
}

#[test]
fn ich_carries_an_underline_colour_along_with_its_character() {
    let t = term(2, 8, b"\x1b[58;5;196mab\x1b[m\x1b[1G\x1b[2@");
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs[0].text, "  ");
    assert_eq!(runs[0].underline, Color::Default);
    assert_eq!(runs[1].text, "ab");
    assert_eq!(runs[1].underline, Color::Indexed(196));
}

/// The style of the last cell of a row, which is where an erase-to-end lands.
fn last_style(t: &Term, row: usize) -> Style {
    let r = t.screen().row(row).unwrap();
    r.runs().last().map(|run| run.style).unwrap_or_default()
}

#[test]
fn bce_fills_an_erase_with_the_pens_background() {
    // Red background, then erase to end of line: the bar reaches the right margin.
    let t = term(2, 8, b"\x1b[41mab\x1b[K");
    assert_eq!(last_style(&t, 0).bg, Color::Indexed(1));
    assert_eq!(
        t.screen().row(0).unwrap().to_text(),
        "ab      ",
        "the wash is blanks, not text"
    );
}

#[test]
fn bce_ignores_the_foreground_and_the_attributes() {
    // The regression guard for `Row::content_len`, which counts a styled blank as
    // content: a coloured *foreground* must not turn an erase into trailing cells.
    let plain = term(2, 8, b"ab\x1b[K");
    let fg = term(2, 8, b"\x1b[31;4mab\x1b[K");
    assert_eq!(
        fg.screen().row(0).unwrap().runs().len(),
        plain.screen().row(0).unwrap().runs().len(),
        "SGR 31 then EL must not append a run"
    );
    assert_eq!(last_style(&fg, 0).bg, Color::Default);
}

#[test]
fn bce_keeps_reverse_video() {
    // Reverse is resolved into a face by Lisp, so the bar's colour is the foreground.
    let t = term(2, 8, b"\x1b[7;31mab\x1b[K");
    let style = last_style(&t, 0);
    assert!(style.attrs.contains(Attrs::REVERSE));
    assert_eq!(style.fg, Color::Indexed(1));
}

#[test]
fn bce_applies_to_ech_ich_and_scrolls() {
    let t = term(3, 8, b"abcdef\r\x1b[41m\x1b[3X");
    assert_eq!(
        t.screen().row(0).unwrap().runs()[0].style.bg,
        Color::Indexed(1),
        "ECH erases with the pen"
    );

    // ICH, which the name has always claimed and the body never fed: `insert_chars`
    // passes `pen.erase()` down like the other two, so the blanks it opens up carry the
    // background as well.
    let t = term(3, 8, b"abcdef\r\x1b[41m\x1b[2@");
    let row = t.screen().row(0).unwrap();
    assert_eq!(
        row.runs()[0].style.bg,
        Color::Indexed(1),
        "ICH opens its gap with the pen"
    );
    assert_eq!(row.to_text().trim_end(), "  abcdef");

    // A scroll exposes a fresh row, which is an erase too.
    let t = term(2, 8, b"\x1b[41m\x1b[2Sx");
    assert_eq!(
        t.screen().row(1).unwrap().runs()[0].style.bg,
        Color::Indexed(1)
    );
}

#[test]
fn a_background_wash_is_not_transcript() {
    // Paint the screen and clear it. Without `has_text` this hands Emacs a screenful
    // of pure colour with nothing written on it.
    let mut t = term(3, 8, b"\x1b[41m\x1b[2J");
    assert!(
        t.drain().scrolled.is_empty(),
        "an erased wash must not become scrollback"
    );
}

#[test]
fn a_washed_screen_still_archives_its_text() {
    let mut t = term(3, 8, b"\x1b[41mhello\x1b[2J");
    let scrolled = t.drain().scrolled;
    assert_eq!(scrolled.len(), 1, "the written row is still history");
    assert_eq!(runs_text(&scrolled[0]), "hello");
}

#[test]
fn an_erase_with_no_background_is_unchanged() {
    // The common case must stay byte-identical to life before `bce`.
    let mut t = term(2, 8, b"one\x1b[K\r\ntwo\r\nthree");
    let delta = t.drain();
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
}

/// A pop must put back every part of the pen, the side-table underline colour included,
/// and not merely the parts a later SGR happened to touch.
#[test]
fn xtpushsgr_push_change_pop_restores_the_pen_exactly() {
    let t = term(
        2,
        20,
        b"\x1b[1;3;4:3;38;2;1;2;3;48;5;200;58;5;9ma\
          \x1b[#{\x1b[0;7;32mb\x1b[#}c",
    );
    assert_eq!(run_style(&t, "a"), run_style(&t, "c"));
    let (b, b_underline) = run_style(&t, "b");
    assert_eq!(b.fg, Color::Indexed(2));
    assert_eq!(b_underline, Color::Default);

    // xterm's older spelling of the same pair.
    let t = term(2, 20, b"\x1b[31ma\x1b[#p\x1b[32mb\x1b[#qc");
    assert_eq!(run_style(&t, "a"), run_style(&t, "c"));
}

/// `CSI Pm # {` restores only what it names; the rest of the pen stays as changed.
#[test]
fn xtpushsgr_with_parameters_restores_only_what_it_names() {
    let t = term(
        2,
        20,
        b"\x1b[1;4;31;44ma\x1b[30;4#{\x1b[0;7;32;45mb\x1b[#}c",
    );
    let (c, _) = run_style(&t, "c");
    assert_eq!(c.fg, Color::Indexed(1), "30 names the foreground");
    assert!(c.attrs.contains(Attrs::UNDERLINE), "4 names the underline");
    assert_eq!(c.bg, Color::Indexed(5), "the background was not named");
    assert!(!c.attrs.contains(Attrs::BOLD), "bold was not named");
    assert!(c.attrs.contains(Attrs::REVERSE), "reverse was not named");
}

/// Ten deep, as xterm is: the eleventh push is dropped, and a pop with nothing pushed
/// leaves the pen alone.
#[test]
fn xtpushsgr_stack_is_bounded_and_pop_on_empty_is_harmless() {
    let mut input = Vec::new();
    for i in 1..=11 {
        input.extend(format!("\x1b[38;5;{i}m\x1b[#{{").into_bytes());
    }
    input.extend(b"\x1b[38;5;99m\x1b[#}a");
    let t = term(2, 20, &input);
    assert_eq!(run_style(&t, "a").0.fg, Color::Indexed(10));

    let t = term(2, 20, b"\x1b[31m\x1b[#}a");
    assert_eq!(run_style(&t, "a").0.fg, Color::Indexed(1));
}
