//! Grapheme clusters, mode 2027 and the kitty text sizing protocol (OSC 66).

use super::*;

/// The three cursor positions a client reads while deciding what this terminal supports.
///
/// This is the spec's detection procedure copied out, and it is the only one there is —
/// `OSC 66` has no query and no reply, so a client learns whether the width half is
/// implemented by printing two cells' worth of text between cursor reports and doing
/// arithmetic on the answers. Which makes the cursor arithmetic in `Screen::place` and
/// `Screen::settle_cursor` a *protocol surface*: off by one and a client concludes the
/// escape does nothing, falls back to padding by hand, and the disagreement this
/// protocol exists to end comes straight back.
///
/// The third report is the interesting one. It probes `s=2`, which cooked does not
/// implement, and the correct thing for an unimplementing terminal to do is move the
/// cursor by one — `s` defaults to 1 and `w` defaults to 0, so what is drawn is an
/// ordinary space. A client reading 4 rather than 5 concludes scale is unsupported, and
/// is right.
#[test]
fn the_detection_sequence_a_client_walks_reads_back_width_but_not_scale() {
    let mut t = term(4, 20, b"");
    t.feed(b"\r\x1b[6n\x1b]66;w=2; \x07\x1b[6n\x1b]66;s=2; \x07\x1b[6n");
    let replies = reply_strings(&mut t);
    assert_eq!(
        replies,
        vec!["\x1b[1;1R", "\x1b[1;3R", "\x1b[1;4R"],
        "w=2 moved two cells and s=2 moved one, which says width yes and scale no"
    );
}

#[test]
fn a_declared_width_overrides_what_a_width_table_would_say() {
    // The spec's own example of the `w` key doing something no width table can express:
    // two ASCII characters the client wants rendered in one cell.
    let t = term(2, 20, b"\x1b]66;w=1;Ha\x07\x1b]66;w=1;lf\x07");
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(
        runs.iter().map(|r| r.text.as_str()).collect::<String>(),
        "Half"
    );
    assert_eq!(
        runs.iter().map(|r| r.cols).sum::<usize>(),
        2,
        "four characters standing on the two cells the child declared"
    );
    assert_eq!(t.screen().cursor().col, 2);
}

#[test]
fn a_declared_width_lays_down_continuation_cells_like_any_wide_character() {
    let t = term(2, 20, b"\x1b]66;w=3;x\x07y");
    assert_eq!(t.screen().cursor().col, 4);
    let grid_row = t.screen().row(0).unwrap();
    let cells = grid_row.cells();
    assert_eq!(cells[0].ch, 'x');
    assert!(cells[1].is_continuation() && cells[2].is_continuation());
    assert_eq!(cells[3].ch, 'y');
    // One run: the `y` shares the pen, so it joins the block's run and the column count
    // covers both — three declared cells plus the one the `y` stands on.
    assert_eq!(t.screen().row(0).unwrap().runs()[0].cols, 4);
}

#[test]
fn a_block_that_cannot_fit_the_screen_is_discarded() {
    // "If the multicell block is larger than the screen size in either dimension, the
    // terminal must discard the character." Six cells declared on a five-column screen.
    let t = term(2, 5, b"\x1b]66;w=6;x\x07");
    assert_eq!(text(&t, 0), "");
    assert_eq!(t.screen().cursor().col, 0);
}

#[test]
fn a_block_that_does_not_fit_the_line_wraps_whole_under_decawm() {
    let t = term(3, 6, b"abcde\x1b]66;w=2;x\x07");
    assert_eq!(text(&t, 0), "abcde", "the block did not straddle the edge");
    assert_eq!(text(&t, 1), "x");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (1, 2));
}

#[test]
fn with_wrapping_off_a_block_backs_up_far_enough_to_land_whole() {
    // DECAWM off: the cursor never leaves the row, so the block is moved back to the
    // last position where all of it fits and overwrites what was there.
    let t = term(3, 6, b"\x1b[?7labcde\x1b]66;w=2;x\x07");
    assert_eq!(text(&t, 0), "abcdx");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (0, 5));
}

#[test]
fn text_longer_than_the_protocol_allows_is_dropped_rather_than_truncated() {
    let long = format!("\x1b]66;w=1;{}\x07", "a".repeat(MAX_TEXT_SIZE_LEN + 1));
    let t = term(2, 20, long.as_bytes());
    assert_eq!(text(&t, 0), "");
    // One byte under the cap still draws, so the bound is the spec's and not an accident
    // of some other limit sitting lower.
    let ok = format!("\x1b]66;w=1;{}\x07", "a".repeat(MAX_TEXT_SIZE_LEN - 8));
    let t = term(2, 20, ok.as_bytes());
    assert_eq!(t.screen().cursor().col, 1);
}

#[test]
fn a_value_outside_its_range_drops_the_whole_escape() {
    // `w` is 0 to 7. An 8 is a sender that has misunderstood something, and guessing at
    // what it meant would put a wrong width on the grid — which is the one failure this
    // protocol was written to remove.
    let t = term(2, 20, b"\x1b]66;w=8;x\x07");
    assert_eq!(text(&t, 0), "");
    // An unknown key is a *newer* sender, not a broken one, and is ignored.
    let t = term(2, 20, b"\x1b]66;w=2:q=9;x\x07");
    assert_eq!(t.screen().cursor().col, 2);
}

#[test]
fn the_keys_this_declines_are_parsed_and_then_ignored() {
    // Fractional scale and alignment change nothing about how many cells the text takes,
    // by the spec's own definition, so accepting and dropping them is not a divergence.
    let t = term(2, 20, b"\x1b]66;n=1:d=2:v=2:h=1:w=1;ab\x07");
    assert_eq!(t.screen().cursor().col, 1);
    assert_eq!(t.screen().row(0).unwrap().runs()[0].text, "ab");
}

#[test]
fn w_zero_splits_the_payload_by_grapheme_cluster() {
    // The default, and the reason the escape is useful even with no `w`: the text is
    // still segmented properly, so the family emoji is one two-cell block.
    let t = term(
        2,
        20,
        "\x1b]66;;a\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}b\x07".as_bytes(),
    );
    assert_eq!(t.screen().cursor().col, 4);
}

#[test]
fn a_zwj_emoji_family_stands_on_two_cells_and_not_on_six() {
    // Printed as ordinary text, with no escape code in sight. Per code point a width
    // table calls this 2 + 0 + 2 + 0 + 2; per grapheme cluster it is one cell block two
    // columns wide, and that is what the grid must hold or every column after it on the
    // row is somewhere the child did not put it.
    let t = term(
        2,
        20,
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}|".as_bytes(),
    );
    assert_eq!(t.screen().cursor().col, 3);
    let grid_row = t.screen().row(0).unwrap();
    let cells = grid_row.cells();
    assert_eq!(cells[0].ch, '\u{1F468}');
    assert!(cells[1].is_continuation());
    assert_eq!(cells[2].ch, '|');
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.iter().map(|r| r.cols).sum::<usize>(), 3);
    assert_eq!(
        runs.iter().map(|r| r.text.as_str()).collect::<String>(),
        "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}|",
        "every code point still reaches Emacs; only the columns collapsed"
    );
}

/// The rules DEC mode 2027 is a promise about, measured where a child measures them: by
/// where the cursor ends up.
///
/// DECRQM answers 3 for 2027 on the strength of this table, so a row that stops passing
/// is a reason to revisit that answer and not only a width bug. Each case is fed twice,
/// whole and one byte per `feed`, since a cluster that only holds together within a
/// single read is not segmentation. The sources are contour's terminal-unicode-core
/// draft, which defines the mode, kitty's text sizing spec, which `emu::text` follows,
/// and ghostty's `unicode/grapheme.zig`, the other implementation of 2027 to hand. Where
/// they split, the comment says which one this sides with.
#[test]
fn mode_2027_corpus() {
    let corpus: &[(&str, usize, &str)] = &[
        // Emoji are two cells, and a ZWJ sequence is one image on two cells.
        ("\u{1F600}", 2, "emoji presentation by default"),
        (
            "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}",
            2,
            "ZWJ family",
        ),
        (
            "\u{1F3F4}\u{200D}\u{2620}\u{FE0F}",
            2,
            "ZWJ sequence ending in VS16",
        ),
        (
            "\u{1F3F4}\u{E0067}\u{E0062}\u{E0065}\u{E006E}\u{E0067}\u{E007F}",
            2,
            "tag sequence flag",
        ),
        // VS16 promotes a text-presentation base to two, and does nothing to a base with
        // no emoji variant.
        ("\u{2764}\u{FE0F}", 2, "VS16 promotes"),
        ("#\u{FE0F}\u{20E3}", 2, "keycap sequence"),
        ("x\u{FE0F}", 1, "VS16 on a base with no emoji variant"),
        // VS15. A text-default base stays one under every reading. An emoji-default one
        // is the divergence: the draft keeps it at two, kitty, ghostty and
        // `unicode-width` narrow it to one, and this narrows; see `emu::text`.
        ("\u{2714}\u{FE0E}", 1, "VS15 on a text-default base"),
        (
            "\u{231A}\u{FE0E}",
            1,
            "VS15 on an emoji-default base narrows",
        ),
        (
            "\u{1F600}\u{FE0E}",
            2,
            "VS15 on a base with no text variant is ignored",
        ),
        (
            "\u{231A}\u{FE0E}\u{FE0F}",
            1,
            "a second selector has no base to act on",
        ),
        // Emoji modifiers ride their base. A modifier after something that is not a
        // modifier base still joins its cluster, since it is `Extend`; ghostty gives that
        // cluster two cells, and so does this.
        ("\u{1F44B}\u{1F3FF}", 2, "modifier sequence"),
        (
            "\u{261D}\u{1F3FF}",
            2,
            "modifier widens a text-default base",
        ),
        ("\u{1F3FF}", 2, "a lone modifier is a swatch"),
        (
            "a\u{1F3FF}",
            2,
            "a modifier on a non-base is one cluster, never three cells",
        ),
        // Regional indicators pair from the left, two cells a flag and two for an
        // unpaired one.
        ("\u{1F1E6}", 2, "lone regional indicator"),
        ("\u{1F1E6}\u{1F1FA}", 2, "flag"),
        ("\u{1F1E6}\u{1F1FA}\u{1F1E8}", 4, "flag and half a flag"),
        ("\u{1F1E6}\u{1F1FA}\u{1F1E8}\u{1F1E6}", 4, "two flags"),
        // Hangul jamo compose into one syllable block, two cells however it is spelled.
        (
            "\u{1100}\u{1161}\u{11A8}",
            2,
            "leading, vowel and trailing jamo",
        ),
        (
            "\u{AC00}\u{11A8}",
            2,
            "precomposed LV syllable and a trailing jamo",
        ),
        ("\u{A960}\u{1161}", 2, "Jamo Extended-A leading consonant"),
        ("\u{1100}\u{D7B0}", 2, "Jamo Extended-B vowel"),
        ("\u{3131}", 2, "compatibility jamo stands alone"),
        // The cap from the other direction: a wide base and a spacing mark.
        ("\u{65E5}\u{0903}", 2, "wide base and a spacing mark"),
    ];
    for &(cluster, cells, what) in corpus {
        let input = format!("{cluster}|");
        let whole = term(2, 20, input.as_bytes());
        let mut bytewise = Term::new(2, 20);
        for byte in input.as_bytes() {
            bytewise.feed(std::slice::from_ref(byte));
        }
        for (how, t) in [("whole", &whole), ("a byte at a time", &bytewise)] {
            assert_eq!(
                t.screen().cursor().col,
                cells + 1,
                "{what}: {cluster:?} fed {how}"
            );
        }
    }
}

#[test]
fn mode_2027_cannot_be_reset() {
    // The per-code-point rule is not kept anywhere to fall back on, so a child that
    // turns the mode off, or soft-resets, gets clustering all the same — which is what
    // answering 3 promised it.
    let family = "\u{1F468}\u{200D}\u{1F469}\u{200D}\u{1F467}|";
    for setup in [&b"\x1b[?2027l"[..], b"\x1b[!p", b"\x1bc"] {
        let mut t = term(2, 20, setup);
        t.feed(family.as_bytes());
        assert_eq!(t.screen().cursor().col, 3, "after {setup:?}");
    }
}

#[test]
fn a_variation_selector_resizes_the_cell_it_lands_on() {
    // U+2714 is one column bare. VS16 promotes it to emoji presentation, which is two —
    // retroactively, since the cell was written a code point ago.
    let bare = term(2, 20, "\u{2714}|".as_bytes());
    assert_eq!(bare.screen().cursor().col, 2);
    let wide = term(2, 20, "\u{2714}\u{FE0F}|".as_bytes());
    assert_eq!(wide.screen().cursor().col, 3);
    let grid_row = wide.screen().row(0).unwrap();
    let cells = grid_row.cells();
    assert!(cells[1].is_continuation());
    assert_eq!(cells[2].ch, '|');
}

#[test]
fn a_widening_with_no_room_left_on_the_row_is_declined_rather_than_wrapped() {
    // The case the spec calls out as awkward: the character is already on this row, and
    // moving it to the next one to gain a column would be a worse answer than being a
    // column narrow. The cell stays where it was drawn.
    let t = term(3, 2, "a\u{2714}\u{FE0F}".as_bytes());
    // The selector itself is still kept — it is a character the child sent, and Emacs
    // renders it — but it bought no second column and moved nothing to the next row.
    assert_eq!(text(&t, 0), "a\u{2714}\u{FE0F}");
    assert_eq!(text(&t, 1), "");
    assert!(!t.screen().row(0).unwrap().cells()[1].is_continuation());
}

#[test]
fn a_cluster_split_across_two_feeds_is_still_one_cluster() {
    // The reason the segmenter is a field on `State` rather than a loop over a string: a
    // read can end anywhere, including between an emoji and the joiner that binds it to
    // the next one.
    let mut t = Term::new(2, 20);
    t.feed("\u{1F468}\u{200D}".as_bytes());
    t.feed("\u{1F469}|".as_bytes());
    assert_eq!(t.screen().cursor().col, 3);
}

#[test]
fn a_mark_after_a_declared_block_joins_the_block() {
    // The block was declared three cells wide, so the cell it occupies starts three
    // columns back — not one, and not wherever a width table would put it.
    let t = term(2, 20, "\x1b]66;w=3;x\x07\u{301}".as_bytes());
    assert_eq!(t.screen().cursor().col, 3);
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs[0].text, "x\u{301}");
    assert_eq!(runs[0].cols, 3);
}
