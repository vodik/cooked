//! Renditions: SGR, underline colours, background colour erase and XTPUSHSGR.

use super::*;
use crate::emu::link::MAX_TRACKED_LINKS;

#[test]
fn sgr_sets_colors_and_attributes() {
    let mut t = term(2, 20, b"\x1b[1;31mred\x1b[0m.");
    let delta = t.drain();
    let runs = &delta.rows.iter().find(|r| r.index == 0).unwrap().runs;
    let red = t.style(runs.run(0).style);
    assert_eq!(runs.run(0).text, "red");
    assert_eq!(red.fg, Color::Indexed(1));
    assert!(red.attrs.contains(Attrs::BOLD));
    assert_eq!(runs.run(1).text, ".");
    assert_eq!(runs.run(1).style, StyleId::DEFAULT);
    // And the drain names the rendition it has not sent before, so Lisp can resolve it.
    assert!(
        delta.styles.contains(&(runs.run(0).style, red)),
        "{:?}",
        delta.styles
    );
}

#[test]
fn overline_is_set_by_53_and_cleared_by_55_and_0() {
    let style = |input: &[u8]| cell_style(&term(2, 20, input), 0, 0);
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
    assert_eq!(run_style_at(&semi, 0, 0).fg, Color::Rgb(10, 20, 30));

    let colon = term(2, 20, b"\x1b[38:2::10:20:30mx");
    assert_eq!(run_style_at(&colon, 0, 0).fg, Color::Rgb(10, 20, 30));
}

#[test]
fn truecolor_foreground_and_background_share_one_sequence() {
    let t = term(2, 20, b"\x1b[38;2;255;255;255;48;2;1;2;3;1mx");
    let style = run_style_at(&t, 0, 0);
    assert_eq!(style.fg, Color::Rgb(255, 255, 255));
    assert_eq!(style.bg, Color::Rgb(1, 2, 3));
    assert!(style.attrs.contains(Attrs::BOLD));
}

#[test]
fn indexed_256_color() {
    let t = term(2, 20, b"\x1b[38;5;200mx");
    assert_eq!(run_style_at(&t, 0, 0).fg, Color::Indexed(200));
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
        let style = run_style_at(&t, 0, 0);
        assert!(style.attrs.contains(Attrs::UNDERLINE), "{input:?}");
        assert_eq!(style.attrs.underline_style(), want, "{input:?}");
    }
}

#[test]
fn sgr_21_is_double_underline_and_leaves_bold_alone() {
    let style = run_style_at(&term(2, 8, b"\x1b[1;21mx"), 0, 0);
    assert!(style.attrs.contains(Attrs::BOLD));
    assert_eq!(style.attrs.underline_style(), 2);
    // And 24 takes it off again, as it does every other underline.
    let off = run_style_at(&term(2, 8, b"\x1b[21;24mx"), 0, 0);
    assert_eq!(off.attrs.underline_style(), 0);
}

#[test]
fn underline_is_removed_by_both_spellings() {
    for input in [&b"\x1b[4:3m\x1b[4:0mx"[..], &b"\x1b[4:3m\x1b[24mx"[..]] {
        let style = run_style_at(&term(2, 8, input), 0, 0);
        assert!(!style.attrs.contains(Attrs::UNDERLINE), "{input:?}");
        assert_eq!(style.attrs.underline_style(), 0, "{input:?}");
    }
}

#[test]
fn underline_colour_parses_both_spellings() {
    let indexed = term(2, 8, b"\x1b[4m\x1b[58;5;196mx");
    assert_eq!(run_style_at(&indexed, 0, 0).underline, Color::Indexed(196));
    let rgb = term(2, 8, b"\x1b[4m\x1b[58:2::255:0:0mx");
    assert_eq!(run_style_at(&rgb, 0, 0).underline, Color::Rgb(255, 0, 0));
    let reset = term(2, 8, b"\x1b[4m\x1b[58;5;196m\x1b[59mx");
    assert_eq!(run_style_at(&reset, 0, 0).underline, Color::Default);
}

#[test]
fn a_wide_character_keeps_its_underline_colour() {
    // The colour has to land on the lead cell. `Row::runs` skips continuation cells,
    // so a colour recorded one column to the right disappears entirely.
    let t = term(2, 8, b"\x1b[4;58;5;196m\xe5\xb9\xb8");
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.len(), 1, "{runs:?}");
    assert_eq!(t.style(runs.run(0).style).underline, Color::Indexed(196));
}

#[test]
fn a_combining_mark_does_not_move_an_underline_colour() {
    let t = term(2, 8, b"\x1b[4;58;5;196me\xcc\x81x");
    let runs = t.screen().row(0).unwrap().runs();
    assert!(
        runs.iter()
            .all(|r| t.style(r.style).underline == Color::Indexed(196)),
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
    let last = t.style(runs.iter().next_back().unwrap().style);
    assert_eq!(last.underline, Color::Default);
    assert!(!last.attrs.contains(Attrs::UNDERLINE));
}

#[test]
fn an_underline_colour_survives_a_rewrap() {
    // A reflow moves cells, and the colour rides the cell, so it has to land on the same
    // character at the new width.
    let mut t = term(2, 4, b"ab\x1b[4;58;5;196mcd");
    t.resize(2, 8);
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert_eq!(runs.run(0).text, "ab");
    assert_eq!(runs.run(1).text, "cd");
    assert_eq!(t.style(runs.run(1).style).underline, Color::Indexed(196));
}

#[test]
fn overwriting_a_cell_retires_its_underline_colour() {
    // `Row::set` retires whatever the old occupant had attached to the cell, which
    // is what this proves: the colour goes with the character it belonged to.
    let t = term(2, 8, b"\x1b[4;58;5;196mab\x1b[1G\x1b[mxy");
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.len(), 1, "{runs:?}");
    assert_eq!(runs.run(0).text, "xy");
    assert_eq!(t.style(runs.run(0).style).underline, Color::Default);
}

#[test]
fn an_erased_row_forgets_its_underline_colours() {
    let t = term(2, 8, b"\x1b[4;58;5;196mab\x1b[1G\x1b[K\x1b[mxy");
    assert_eq!(run_style_at(&t, 0, 0).underline, Color::Default);
}

#[test]
fn dch_spares_an_underline_colour_on_a_column_it_never_touched() {
    // DCH slides cells left over the gap, and a colour on a column left of the cut is not
    // moved at all.
    let t = term(2, 8, b"\x1b[58;5;196ma\x1b[mbcdef\x1b[5G\x1b[1P");
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.run(0).text, "a");
    assert_eq!(t.style(runs.run(0).style).underline, Color::Indexed(196));
    assert_eq!(runs.run(1).text, "bcdf");
    assert_eq!(t.style(runs.run(1).style).underline, Color::Default);
}

#[test]
fn ich_carries_an_underline_colour_along_with_its_character() {
    let t = term(2, 8, b"\x1b[58;5;196mab\x1b[m\x1b[1G\x1b[2@");
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.run(0).text, "  ");
    assert_eq!(t.style(runs.run(0).style).underline, Color::Default);
    assert_eq!(runs.run(1).text, "ab");
    assert_eq!(t.style(runs.run(1).style).underline, Color::Indexed(196));
}

/// The style of the last cell of a row, which is where an erase-to-end lands.
fn last_style(t: &Term, row: usize) -> Style {
    let r = t.screen().row(row).unwrap();
    t.style(
        r.runs()
            .iter()
            .next_back()
            .map(|run| run.style)
            .unwrap_or_default(),
    )
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
        run_style_at(&t, 0, 0).bg,
        Color::Indexed(1),
        "ECH erases with the pen"
    );

    // ICH, which the name has always claimed and the body never fed: `insert_chars`
    // passes `pen.erase()` down like the other two, so the blanks it opens up carry the
    // background as well.
    let t = term(3, 8, b"abcdef\r\x1b[41m\x1b[2@");
    let row = t.screen().row(0).unwrap();
    assert_eq!(
        t.style(row.runs().run(0).style).bg,
        Color::Indexed(1),
        "ICH opens its gap with the pen"
    );
    assert_eq!(row.to_text().trim_end(), "  abcdef");

    // A scroll exposes a fresh row, which is an erase too.
    let t = term(2, 8, b"\x1b[41m\x1b[2Sx");
    assert_eq!(run_style_at(&t, 1, 0).bg, Color::Indexed(1));
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

/// A pop must put back every part of the pen, the underline colour included, and not
/// merely the parts a later SGR happened to touch.
#[test]
fn xtpushsgr_push_change_pop_restores_the_pen_exactly() {
    let t = term(
        2,
        20,
        b"\x1b[1;3;4:3;38;2;1;2;3;48;5;200;58;5;9ma\
          \x1b[#{\x1b[0;7;32mb\x1b[#}c",
    );
    assert_eq!(run_style(&t, "a"), run_style(&t, "c"));
    let b = run_style(&t, "b");
    assert_eq!(b.fg, Color::Indexed(2));
    assert_eq!(b.underline, Color::Default);

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
    let c = run_style(&t, "c");
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
    assert_eq!(run_style(&t, "a").fg, Color::Indexed(10));

    let t = term(2, 20, b"\x1b[31m\x1b[#}a");
    assert_eq!(run_style(&t, "a").fg, Color::Indexed(1));
}

/// A child minting a rendition per character cannot grow the style table without
/// bound, and the collections that keep it bounded never recolour anything.
///
/// Every character gets a truecolour foreground no other character has, far past the
/// table's capacity, with a drain every so often as Emacs would take them. Two things are
/// checked: the store stays within a small multiple of what the screen can show, and
/// every run of every drain resolves, through the renditions the drains announced, to the
/// colour its character was written in -- which a reused id announced too late, or not
/// at all, would get wrong.
#[test]
fn a_rendition_per_character_stays_bounded_and_every_run_keeps_its_colour() {
    let (rows, cols) = (4, 20);
    let mut t = Term::new(rows, cols);
    let mut announced = std::collections::HashMap::new();
    let colour = |n: u32| Color::Rgb((n >> 16) as u8, (n >> 8) as u8, n as u8);
    let mut n = 0u32;
    for _ in 0..40 {
        let mut chunk = Vec::new();
        for _ in 0..500 {
            n += 1;
            let Color::Rgb(r, g, b) = colour(n) else {
                unreachable!()
            };
            // The character is the low digit of n, so the run text says which n drew it.
            chunk.extend(format!("\x1b[38;2;{r};{g};{b}m{}", n % 10).into_bytes());
        }
        t.feed(&chunk);
        let delta = t.drain();
        announced.extend(delta.styles.iter().copied());
        for run in delta.rows.iter().flat_map(|row| &row.runs) {
            if run.style == StyleId::DEFAULT {
                continue;
            }
            let style = announced
                .get(&run.style)
                .unwrap_or_else(|| panic!("{:?} was never announced", run.style));
            let Color::Rgb(r, g, b) = style.fg else {
                panic!("{style:?} is not a direct colour");
            };
            let written = (u32::from(r) << 16) | (u32::from(g) << 8) | u32::from(b);
            assert_eq!(
                run.text,
                (written % 10).to_string(),
                "a run of one character carries the colour that character was written in"
            );
        }
    }
    assert!(n as usize > 4 * crate::emu::style::STYLE_TABLE_CAPACITY);
    assert!(
        t.styles_held() <= 2 * crate::emu::style::STYLE_TABLE_CAPACITY,
        "{} renditions held after {n} distinct ones",
        t.styles_held()
    );
}

/// A pen with a background needs two ids, one for its text and one for the blank an erase
/// leaves, and a collection taken for the second must not free the first.
///
/// With a limit of 8 and seven renditions live, `SGR 1;41` gives the bold text a slot of
/// its own, which fills the table, and then collects for the erase rendition. Nothing held
/// the text's id yet, so the collection freed it, the text was written under an id no drain
/// announced, and the next rendition to be given one would have recoloured it.
#[test]
fn a_pen_taken_as_the_table_fills_keeps_its_text_rendition() {
    let mut t = Term::with_id_limits(1, 20, 8, MAX_TRACKED_LINKS);
    t.feed(b"\x1b[31mx\x1b[32mx\x1b[33mx\x1b[34mx\x1b[35mx\x1b[36mx\x1b[0m");
    t.drain();
    t.feed(b"\x1b[H\x1b[2K\x1b[1;41my");
    let delta = t.drain();
    let run = delta.rows[0].runs.run(0);
    assert_eq!(run.text, "y");
    let announced = delta
        .styles
        .iter()
        .find(|(id, _)| *id == run.style)
        .map(|(_, style)| *style);
    let style = announced.unwrap_or_else(|| panic!("{:?} was never announced", run.style));
    assert_eq!(style.bg, Color::Indexed(1));
    assert!(style.attrs.contains(Attrs::BOLD), "{style:?}");
}

#[test]
fn an_underline_colour_and_a_link_reach_the_scrollback_with_their_characters() {
    let mut t = term(
        2,
        10,
        b"\x1b]8;;https://example.com/\x1b\\\x1b[4;58;5;196mlinked\x1b[0m\x1b]8;;\x1b\\\r\n",
    );
    t.feed(b"\r\n\r\n");
    let delta = t.drain();
    let line = delta
        .scrolled
        .iter()
        .find(|line| runs_text(line) == "linked")
        .expect("the row scrolled away");
    let run = line.runs.run(0);
    assert!(run.link.is_some());
    assert_eq!(t.style(run.style).underline, Color::Indexed(196));
    assert!(t.style(run.style).attrs.contains(Attrs::UNDERLINE));
}

/// The font table is read by the row layout hash and by nothing else, so a drain that
/// built no row carries none of it -- a live truecolor gradient holds thousands of
/// renditions, and a child that only scrolled or only rang the bell would be copying one
/// byte of each for a reader that does not exist.
#[test]
fn only_a_drain_with_rows_carries_the_font_table() {
    let mut t = term(3, 10, b"\x1b[1mbold\x1b[0m");
    assert!(
        !t.drain().fonts.is_empty(),
        "the damaged row's layout hash needs it"
    );
    t.feed(b"\x07");
    let delta = t.drain();
    assert!(delta.rows.is_empty());
    assert!(delta.fonts.is_empty());
    assert!(t.drain_hidden().fonts.is_empty());
    assert!(t.drain_scrolled().fonts.is_empty());
}
