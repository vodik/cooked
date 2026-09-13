//! The VT front end, end to end.

use super::*;
// Not in the parent's imports: the SGR arm that used to set these bits moved to
// `emu::sgr`, and the one other name for it here is csi.rs's own import.
use crate::emu::cell::Attrs;

/// An RGBA buffer encoded the way the emulator would encode it.
fn rgba_png(w: u32, h: u32, rgba: &[u8]) -> Vec<u8> {
    use crate::emu::image::PixelSize;
    use crate::emu::png::{PixelFormat, Pixels};
    Pixels::new(PixelSize::new(w, h), PixelFormat::Rgba, rgba.to_vec())
        .encode()
        .1
}
use crate::emu::cell::{Deco, Extra};
use crate::emu::image::Placement;
use crate::emu::link::LinkId;

fn term(rows: usize, cols: usize, input: &[u8]) -> Term {
    let mut t = Term::new(rows, cols);
    t.feed(input);
    t
}

fn runs_text(line: &Scrolled) -> String {
    line.runs.iter().map(|r| r.text.as_str()).collect()
}

fn text(t: &Term, row: usize) -> String {
    t.screen().row(row).unwrap().to_text()
}

#[test]
fn plain_text_lands_on_the_grid() {
    let t = term(4, 20, b"hello");
    assert_eq!(text(&t, 0), "hello");
}

#[test]
fn cursor_addressing_is_one_based() {
    let t = term(4, 20, b"\x1b[2;3Hx");
    assert_eq!(text(&t, 1), "  x");
}

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
fn decstbm_on_a_zero_height_screen_does_not_underflow() {
    // `CSI r` with no parameters defaults its bottom margin to the screen's own
    // height, unlike every other `arg(...) - 1` call site in this module, which
    // passes a non-zero literal default. `Term::new`/`Screen::resize` now floor
    // height at 1 regardless of what is asked for, so this can no longer reach a
    // real `0 - 1`, but the call site's own `saturating_sub` is exercised directly
    // here in case that floor is ever relaxed.
    let mut t = Term::new(0, 20);
    t.feed(b"\x1b[r"); // must not panic (underflow) in a debug/overflow-checked build
    assert_eq!(t.screen().height(), 1, "height is floored, not left at 0");
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

// OSC 8 hyperlinks.
//
// The link is `Extra::Link` in the same side table as the underline colour, so most
// of what could go wrong here is already covered by the underline's own tests. What
// is not, and what these are for, is the *lifetime* of the pen's open link — which
// is the one place OSC 8 is not shaped like an SGR attribute.

fn links(t: &Term, row: usize) -> Vec<(String, Option<LinkId>)> {
    t.screen()
        .row(row)
        .unwrap()
        .runs()
        .into_iter()
        .map(|r| (r.text, r.link))
        .collect()
}

#[test]
fn a_hyperlink_marks_only_the_cells_it_covers() {
    let t = term(
        2,
        30,
        b"see \x1b]8;;https://example.com/\x1b\\here\x1b]8;;\x1b\\ ok",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 3, "{runs:?}");
    assert_eq!(runs[0], ("see ".into(), None));
    assert_eq!(runs[1].0, "here");
    assert!(runs[1].1.is_some());
    assert_eq!(runs[2], (" ok".into(), None));
}

#[test]
fn an_sgr_reset_does_not_close_a_hyperlink() {
    // The trap, and the reason this test exists. `SGR 58`/`59` *are* SGR, so the
    // underline colour goes on `ESC[0m`; a hyperlink is not, and real terminals hold
    // it open across arbitrary rendition changes until an explicit `OSC 8 ; ; ST`.
    // Getting this backwards silently breaks every link a program colours as it
    // prints it, which is the common case — `ls --hyperlink` among them.
    let t = term(
        2,
        30,
        b"\x1b]8;;https://example.com/\x1b\\\x1b[31mred\x1b[0mplain",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 2, "the colour splits the run, not the link");
    assert_eq!(runs[0].0, "red");
    assert_eq!(runs[1].0, "plain");
    assert!(runs[0].1.is_some());
    assert_eq!(
        runs[0].1, runs[1].1,
        "same destination either side of SGR 0"
    );
}

#[test]
fn an_empty_uri_closes_the_hyperlink() {
    let t = term(
        2,
        30,
        b"\x1b]8;;https://example.com/\x1b\\in\x1b]8;;\x1b\\out",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert!(runs[0].1.is_some());
    assert_eq!(runs[1].1, None);
}

#[test]
fn a_reset_closes_the_hyperlink() {
    let t = term(2, 30, b"\x1b]8;;https://example.com/\x1b\\a\x1bcb");
    assert!(links(&t, 0).iter().all(|(_, id)| id.is_none()));
}

#[test]
fn the_id_parameter_is_ignored_and_the_uri_decides() {
    // Two spans of the same destination under different `id=` values are one link
    // here, which is what content-addressing buys — see `LinkStore::intern`.
    let mut t = term(
        2,
        40,
        b"\x1b]8;id=1;https://example.com/\x1b\\a\x1b]8;id=2;https://example.com/\x1b\\b",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 1, "one run, one destination: {runs:?}");
    assert_eq!(t.drain().links.len(), 1, "and one URI across the boundary");
}

#[test]
fn a_uri_crosses_the_boundary_once() {
    let mut t = Term::new(4, 40);
    t.feed(b"\x1b]8;;https://example.com/\x1b\\one\x1b]8;;\x1b\\\r\n");
    assert_eq!(t.drain().links.len(), 1);
    // Same destination, second drain: the id is already Lisp's, so nothing crosses.
    t.feed(b"\x1b]8;;https://example.com/\x1b\\two\x1b]8;;\x1b\\\r\n");
    assert!(t.drain().links.is_empty());
    t.feed(b"\x1b]8;;https://example.org/\x1b\\three\x1b]8;;\x1b\\");
    assert_eq!(t.drain().links.len(), 1, "a new destination does");
}

#[test]
fn a_hyperlink_survives_a_wrap_and_the_scrollback() {
    // Both halves of "the id travels with the row": a rewrap rebases the side table
    // by column, and an evicted row reaches Lisp through the same `Row::runs` the
    // live grid does.
    let mut t = term(2, 4, b"ab\x1b]8;;https://example.com/\x1b\\cd");
    t.resize(2, 8);
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert!(runs[0].1.is_none());
    assert!(runs[1].1.is_some(), "the link rebased with its characters");

    let id = runs[1].1;
    t.feed(b"\r\n\r\n\r\n\r\n");
    let delta = t.drain();
    let scrolled = delta
        .scrolled
        .iter()
        .find(|line| runs_text(line).starts_with("abcd"))
        .expect("the row was evicted");
    assert_eq!(
        scrolled.runs.iter().find_map(|r| r.link),
        id,
        "and again on the way out"
    );
}

#[test]
fn a_wide_character_keeps_its_hyperlink() {
    let t = term(2, 8, b"\x1b]8;;https://example.com/\x1b\\\xe5\xb9\xb8");
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 1, "{runs:?}");
    assert!(
        runs[0].1.is_some(),
        "on the lead cell, not the continuation"
    );
}

#[test]
fn a_hostile_uri_is_refused_rather_than_trimmed() {
    // Both refusals leave the pen closed rather than opening a link that goes
    // somewhere else: a truncated URI is a different destination.
    let long = format!(
        "\x1b]8;;https://example.com/{}\x1b\\x",
        "a".repeat(super::super::link::MAX_URI_LEN)
    );
    assert!(links(&term(2, 8, long.as_bytes()), 0)[0].1.is_none());
}

#[test]
fn an_osc_8_never_reaches_lisp_as_an_event() {
    // The arm returns rather than falling through, so nothing up there can grow a
    // second opinion about what a hyperlink is.
    let mut t = term(2, 20, b"\x1b]8;;https://example.com/\x1b\\x");
    assert!(
        !t.drain()
            .events
            .iter()
            .any(|e| matches!(e, Event::Osc(8, ..)))
    );
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

fn placements(t: &Term, row: usize) -> Vec<Placement> {
    t.screen()
        .row(row)
        .unwrap()
        .extras()
        .iter()
        .filter_map(|(_, e)| match e {
            Extra::Image(p) => Some(*p),
            _ => None,
        })
        .collect()
}

fn with_metrics(rows: usize, cols: usize) -> Term {
    let mut t = Term::new(rows, cols);
    t.set_cell_metrics(CellMetrics {
        width: 10,
        height: 20,
    });
    t
}

#[test]
fn xtwinops_reports_pixel_geometry_once_emacs_has_reported_a_cell_size() {
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[14t\x1b[16t");
    let replies: Vec<_> = t
        .drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect();
    // 24 rows x 20px and 80 cols x 10px; then the cell itself.
    assert_eq!(replies, vec!["\x1b[4;480;800t", "\x1b[6;20;10t"]);
}

fn size_reports(events: &[Event]) -> Vec<String> {
    events
        .iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) if bytes.starts_with(b"\x1b[48;") => {
                Some(String::from_utf8(bytes.clone()).unwrap())
            }
            _ => None,
        })
        .collect()
}

const CELL: CellMetrics = CellMetrics {
    width: 10,
    height: 20,
};

/// TERM.org's three cases, in order: subscribing is one report, a resize is one more,
/// and after unsubscribing a resize is none.
#[test]
fn mode_2048_reports_on_set_and_on_resize_and_not_after_reset() {
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[?2048h");
    // 24 rows x 20px, 80 cols x 10px: height first in both units.
    assert_eq!(size_reports(&t.drain().events), ["\x1b[48;24;80;480;800t"]);

    assert_eq!(
        t.set_size(30, 100, CELL).as_deref(),
        Some(&b"\x1b[48;30;100;600;1000t"[..])
    );
    assert!(
        size_reports(&t.drain().events).is_empty(),
        "the resize report is handed back, not queued as well"
    );

    t.feed(b"\x1b[?2048l");
    assert_eq!(t.set_size(24, 80, CELL), None);
    assert!(size_reports(&t.drain().events).is_empty());
}

#[test]
fn mode_2048_reports_a_cell_change_and_not_a_resize_to_the_same_size() {
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[?2048h");
    t.drain();
    assert_eq!(t.set_size(24, 80, CELL), None, "nothing moved");
    // A text-scale zoom: the grid is untouched and every pixel field is not.
    let zoomed = CellMetrics {
        width: 12,
        height: 24,
    };
    assert_eq!(
        t.set_size(24, 80, zoomed).as_deref(),
        Some(&b"\x1b[48;24;80;576;960t"[..])
    );
}

/// Where `14t` falls silent, this still reports: the rows and columns are known, and a
/// zero pixel field is what the tty's own winsize says in the same case.
#[test]
fn mode_2048_reports_zero_pixels_without_a_cell_size() {
    let mut t = Term::new(24, 80);
    t.feed(b"\x1b[?2048h");
    assert_eq!(size_reports(&t.drain().events), ["\x1b[48;24;80;0;0t"]);
    assert_eq!(
        t.set_size(10, 40, CellMetrics::default()).as_deref(),
        Some(&b"\x1b[48;10;40;0;0t"[..])
    );
}

/// The subscription's report is queued for the drain and a resize's leaves at once, so
/// a resize landing between the two would otherwise be overtaken by the older size.
#[test]
fn a_resize_supersedes_an_undrained_subscription_report() {
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[?2048h\x1b[c");
    assert!(t.set_size(30, 100, CELL).is_some());
    let events = t.drain().events;
    assert!(size_reports(&events).is_empty(), "{events:?}");
    assert!(
        events
            .iter()
            .any(|e| matches!(e, Event::Reply(b) if b.ends_with(b"c"))),
        "and only that reply is dropped"
    );
}

#[test]
fn a_soft_reset_ends_the_size_subscription() {
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[?2048h\x1b[!p");
    t.drain();
    assert_eq!(t.set_size(30, 100, CELL), None);
}

#[test]
fn xtwinops_pixel_geometry_stays_silent_without_a_cell_size() {
    // A terminal frame has no cell size, and answering zero would be a claim.
    let mut t = Term::new(24, 80);
    t.feed(b"\x1b[14t\x1b[16t");
    assert!(
        !t.drain()
            .events
            .iter()
            .any(|e| matches!(e, Event::Reply(_))),
    );
}

/// Base64, so the tests spell a kitty transmission the way a client would.
use crate::emu::kitty::encode_base64 as b64;

#[test]
fn an_explicit_row_count_cannot_force_tens_of_thousands_of_linefeeds() {
    // `f=100` (a file, here a PNG) has no raw pixel count for `kitty::finish`'s
    // payload-vs-geometry check to compare against, so a tiny, entirely valid
    // transmission can still ask for an absurd `r=`. Before the clamp in
    // `Term::intern_image`, this placed the picture with `cells.1 == 65535` and
    // `lay_image` then ran a real `linefeed` — with its own scroll-eviction and
    // scrollback-archival work — that many times from one small APC.
    let mut t = with_metrics(10, 20);
    let png = rgba_png(1, 1, &[0, 0, 0, 255]);
    t.feed(format!("\x1b_Ga=T,f=100,r=65535,c=1,i=1;{}\x1b\\", b64(&png)).as_bytes());
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1);
    assert_eq!(
        placements(&t, 0)[0].rows,
        MAX_IMAGE_CELL_SPAN,
        "the row count is clamped rather than honoured verbatim"
    );
    // The bound above is what keeps this assertion cheap to make at all: if the
    // clamp regressed, this would also be the test that starts taking tens of
    // thousands of linefeeds to run.
    assert!(
        t.screen().height() <= 10,
        "still a 10-row screen, not grown by the image"
    );
}

#[test]
fn a_kitty_transmission_puts_a_picture_on_the_grid() {
    let mut t = with_metrics(10, 20);
    // 2x1 cells' worth of RGB at 10x20 per cell.
    let pixels = vec![0u8; 20 * 20 * 3];
    t.feed(format!("\x1b_Ga=T,f=24,s=20,v=20,i=1;{}\x1b\\", b64(&pixels)).as_bytes());
    assert_eq!(placements(&t, 0).len(), 2);
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1);
    assert!(delta.images[0].bytes.starts_with(b"P6\n20 20\n255\n"));
}

#[test]
fn a_sixel_puts_a_picture_on_the_grid() {
    // The second producer of the same `ImageData`: a sixel arrives as a DCS rather
    // than an APC, and everything past "here are some pixels" is the kitty path.
    let mut t = with_metrics(10, 20);
    // 20 columns of a full band -- two cells wide at 10px a cell, one row tall.
    t.feed(b"\x1bP0;0;0q#0;2;100;0;0!20~\x1b\\");
    assert_eq!(placements(&t, 0).len(), 2);
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1);
    // A PNG rather than the cheaper P6, because sixel has transparency and Emacs'
    // pbm reader has no alpha.
    assert!(delta.images[0].bytes.starts_with(b"\x89PNG"));
    assert_eq!(delta.images[0].px, PixelSize::new(20, 6));
}

#[test]
fn a_sixel_body_split_across_writes_is_one_picture() {
    // A picture arrives in whatever chunks the pty hands over, which for anything
    // interesting is more than one, and the split lands mid-body.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1bP0;0;0q#0;2;100;0;0!1");
    t.feed(b"0~\x1b\\");
    assert_eq!(placements(&t, 0).len(), 1);
    assert_eq!(t.drain().images[0].px, PixelSize::new(10, 6));
}

#[test]
fn a_dcs_that_is_not_a_sixel_is_left_alone() {
    // DECRSPS and the rest are unimplemented, and collecting a payload only to throw
    // it away is worse than not collecting it. DECRQSS is a `q` too, and is told apart
    // by its intermediate -- see `decrqss_is_not_mistaken_for_a_sixel`.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1bP1$t0;0;0q\x1b\\");
    assert!(t.drain().images.is_empty());
    // ...and the parser is left in a state where the next sixel still works.
    t.feed(b"\x1bP0;0;0q#0;2;100;0;0~\x1b\\");
    assert_eq!(t.drain().images.len(), 1);
}

#[test]
fn a_sixel_that_decodes_to_nothing_draws_nothing() {
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1bP0;0;0q\x1b\\");
    assert!(t.drain().images.is_empty());
    assert!(placements(&t, 0).is_empty());
}

#[test]
fn an_overlong_sixel_body_is_truncated_to_a_shorter_picture() {
    // Unlike an over-long APC, which is dropped: a sixel body is a sequence of
    // independent bands, so its prefix is a real picture rather than a parse error
    // with a plausible-looking prefix.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1bP0;0;0q#0;2;100;0;0!100~");
    // `$` is a carriage return: it pads the body without growing the picture, which
    // is what isolates this from the pixel cap. Overrunning with *data* would
    // produce something too large to decode, and that is the other test.
    let filler = vec![b'$'; 4096];
    for _ in 0..(SIXEL_BODY_LIMIT / filler.len()) + 64 {
        t.feed(&filler);
    }
    t.feed(b"\x1b\\");
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1, "a shorter picture, not no picture");
    assert_eq!(delta.images[0].px, PixelSize::new(100, 6));
}

#[test]
fn the_primary_da_advertises_sixel() {
    // How every sixel producer in circulation decides whether to emit one at all.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1b[c");
    let replies: Vec<_> = t
        .drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect();
    assert_eq!(replies, vec!["\x1b[?62;4;22c"]);
}

/// Every reply a drain carries, as text.
fn reply_strings(t: &mut Term) -> Vec<String> {
    t.drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect()
}

#[test]
fn graphics_answers_follow_what_emacs_can_show() {
    // The three probes a picture producer sends, asked with graphics shown, then hidden,
    // then shown again: each answer has to follow the flag in both directions, and a
    // flag that only ever turned off would pass a test that asked once.
    let probes: &[u8] = b"\x1b[c\x1b[?1;1S\x1b[?2;1S\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\";
    let shown = vec![
        "\x1b[?62;4;22c".to_string(),
        format!("\x1b[?1;0;{}S", crate::emu::sixel::PALETTE_SIZE),
        "\x1b[?2;0;800;480S".to_string(),
        "\x1b_Gi=31;OK\x1b\\".to_string(),
    ];
    let mut t = with_metrics(24, 80);
    t.feed(probes);
    assert_eq!(reply_strings(&mut t), shown);

    t.set_graphics_shown(false);
    t.feed(probes);
    assert_eq!(
        reply_strings(&mut t),
        vec![
            "\x1b[?62;22c",
            "\x1b[?1;3S",
            "\x1b[?2;3S",
            "\x1b_Gi=31;ENOTSUPPORTED:display\x1b\\",
        ]
    );

    t.set_graphics_shown(true);
    t.feed(probes);
    assert_eq!(reply_strings(&mut t), shown);
}

#[test]
fn hidden_graphics_survive_a_reset() {
    // What Emacs can display is not something the child negotiated, so neither DECSTR
    // nor RIS may put the `4` back.
    let mut t = with_metrics(10, 20);
    t.set_graphics_shown(false);
    t.feed(b"\x1b[!p\x1bc\x1b[c");
    assert_eq!(reply_strings(&mut t), vec!["\x1b[?62;22c"]);
}

#[test]
fn a_refused_probe_leaves_a_transfer_in_flight_alone() {
    // A probe arriving between two chunks is answered where it stands, as `Kitty::feed`
    // answers one -- and refusing it must not be the thing that eats the picture.
    let png = rgba_png(10, 20, &[0; 10 * 20 * 4]);
    let body = b64(&png);
    let (head, tail) = body.split_at(body.len() / 2);
    let mut t = with_metrics(10, 20);
    t.set_graphics_shown(false);
    t.feed(format!("\x1b_Ga=T,f=100,i=7,m=1;{head}\x1b\\").as_bytes());
    t.feed(b"\x1b_Ga=q,i=8,s=1,v=1,f=24;AAAA\x1b\\");
    t.feed(format!("\x1b_Gm=0;{tail}\x1b\\").as_bytes());
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1, "the picture still arrives");
    let replies: Vec<_> = delta
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect();
    assert!(
        replies.contains(&"\x1b_Gi=8;ENOTSUPPORTED:display\x1b\\".to_string()),
        "{replies:?}"
    );
}

#[test]
fn an_iterm_inline_image_is_not_drawn_where_it_cannot_be_shown() {
    // No probe to refuse, so the picture itself is: laid anyway, it would be a
    // blank rectangle in the transcript with nothing to say why.
    let png = rgba_png(30, 20, &[0; 30 * 20 * 4]);
    let mut t = with_metrics(10, 20);
    t.set_graphics_shown(false);
    t.feed(format!("\x1b]1337;File=inline=1:{}\x07", b64(&png)).as_bytes());
    assert!(placements(&t, 0).is_empty());
    let delta = t.drain();
    assert!(delta.images.is_empty());
    // Consumed rather than passed on: it was ours, and Lisp has nothing to do with it.
    assert!(
        !delta
            .events
            .iter()
            .any(|e| matches!(e, Event::Osc(1337, ..)))
    );
    let cursor = t.screen().cursor;
    assert_eq!((cursor.row, cursor.col), (0, 0), "no rows were laid for it");
}

#[test]
fn an_iterm_inline_image_puts_a_picture_on_the_grid() {
    // The third producer of the same `ImageData`, and the least structured: the
    // payload is a file with no field saying what kind, so the format and the size
    // come from the bytes.
    let png = rgba_png(30, 20, &[0; 30 * 20 * 4]);
    let mut t = with_metrics(10, 20);
    t.feed(format!("\x1b]1337;File=inline=1:{}\x07", b64(&png)).as_bytes());
    assert_eq!(placements(&t, 0).len(), 3, "30px at 10px a cell");
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1);
    assert_eq!(delta.images[0].px, PixelSize::new(30, 20));
    // Passed through rather than converted: Emacs decodes PNG better than we would.
    assert_eq!(delta.images[0].bytes, png);
}

#[test]
fn an_iterm_image_without_inline_is_a_download_and_is_declined() {
    // Without `inline=1` the sequence means "write this to the user's disk", which
    // is a capability a terminal inside an editor has no business growing.
    let png = rgba_png(10, 20, &[0; 10 * 20 * 4]);
    let mut t = with_metrics(10, 20);
    t.feed(format!("\x1b]1337;File=name=Zm9v;size=9:{}\x07", b64(&png)).as_bytes());
    assert!(t.drain().images.is_empty());
    // ...and explicitly turning it off is the same answer.
    t.feed(format!("\x1b]1337;File=inline=0:{}\x07", b64(&png)).as_bytes());
    assert!(t.drain().images.is_empty());
}

#[test]
fn iterm_arguments_survive_being_split_on_semicolons() {
    // Semicolons separate iTerm2's keys and OSC's parameters alike, so the arguments
    // arrive already split and have to be rejoined before they can be read.
    let png = rgba_png(10, 20, &[0; 10 * 20 * 4]);
    let mut t = with_metrics(10, 20);
    let apc = format!(
        "\x1b]1337;File=name=Zm9v;size=64;inline=1;width=4;height=2:{}\x07",
        b64(&png)
    );
    t.feed(apc.as_bytes());
    // `width=4` is four cells, overriding what the 10px picture would imply.
    assert_eq!(placements(&t, 0).len(), 4);
}

#[test]
fn iterm_sizes_in_anything_but_cells_fall_back_to_the_pixels() {
    // `px`, `%` and `auto` are all spellings we do not honour directly, and all of
    // them mean the same thing a missing key does.
    let png = rgba_png(30, 20, &[0; 30 * 20 * 4]);
    for size in ["100px", "50%", "auto", ""] {
        let mut t = with_metrics(10, 20);
        let apc = format!("\x1b]1337;File=inline=1;width={size}:{}\x07", b64(&png));
        t.feed(apc.as_bytes());
        assert_eq!(placements(&t, 0).len(), 3, "width={size}");
    }
}

#[test]
fn an_iterm_payload_emacs_cannot_decode_is_declined() {
    // A format Emacs cannot read renders as nothing, and nothing on screen is
    // indistinguishable from a bug, so it is refused rather than hoped over.
    let mut t = with_metrics(10, 20);
    t.feed(format!("\x1b]1337;File=inline=1:{}\x07", b64(b"BMnot-a-bitmap")).as_bytes());
    assert!(t.drain().images.is_empty());
    // A payload that is not base64 at all, and one with no payload separator.
    t.feed(b"\x1b]1337;File=inline=1:not*base64\x07");
    assert!(t.drain().images.is_empty());
    t.feed(b"\x1b]1337;File=inline=1\x07");
    assert!(t.drain().images.is_empty());
}

#[test]
fn other_iterm_1337_messages_still_reach_lisp() {
    // `OSC 1337` is iTerm2's whole private channel — `SetUserVar`, `CurrentDir` and
    // the rest — so intercepting all of it to find the images would quietly close a
    // door that is already open.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1b]1337;CurrentDir=/tmp\x07");
    let events = t.drain().events;
    assert!(
        events.iter().any(|e| matches!(
            e,
            Event::Osc(1337, parts, _) if parts[0] == "CurrentDir=/tmp"
        )),
        "{events:?}"
    );

    // A `File=` that turned out to be malformed is still ours, and is not passed on
    // as though somebody else might make sense of it.
    t.feed(b"\x1b]1337;File=inline=1:not*base64\x07");
    let events = t.drain().events;
    assert!(!events.iter().any(|e| matches!(e, Event::Osc(1337, ..))));
}

#[test]
fn a_png_transmission_needs_no_dimensions_of_its_own() {
    // Clients omit `s=`/`v=` for PNG, because the file already says.
    let png = rgba_png(30, 20, &[0; 30 * 20 * 4]);
    let mut t = with_metrics(10, 20);
    t.feed(format!("\x1b_Ga=T,f=100,i=1;{}\x1b\\", b64(&png)).as_bytes());
    assert_eq!(placements(&t, 0).len(), 3, "30px at 10px a cell");
}

#[test]
fn an_explicit_cell_rectangle_overrides_the_pixels() {
    let mut t = with_metrics(10, 20);
    let pixels = vec![0u8; 20 * 20 * 3];
    t.feed(
        format!(
            "\x1b_Ga=T,f=24,s=20,v=20,c=5,r=1,i=1;{}\x1b\\",
            b64(&pixels)
        )
        .as_bytes(),
    );
    assert_eq!(placements(&t, 0).len(), 5);
}

#[test]
fn a_transmission_can_be_placed_again_by_its_client_id() {
    let mut t = with_metrics(10, 20);
    let pixels = vec![0u8; 10 * 20 * 3];
    t.feed(format!("\x1b_Ga=t,f=24,s=10,v=20,i=7;{}\x1b\\", b64(&pixels)).as_bytes());
    assert!(
        placements(&t, 0).is_empty(),
        "a=t transmits without drawing"
    );
    t.feed(b"\x1b_Ga=p,i=7\x1b\\");
    assert_eq!(placements(&t, 0).len(), 1);
}

#[test]
fn a_chunked_transmission_arrives_whole() {
    let png = rgba_png(10, 20, &[0; 10 * 20 * 4]);
    let encoded = b64(&png);
    let mut t = with_metrics(10, 20);
    let mut chunks = encoded.as_bytes().chunks(64).peekable();
    let mut first = true;
    while let Some(chunk) = chunks.next() {
        let more = u8::from(chunks.peek().is_some());
        let control = if first {
            format!("a=T,f=100,i=1,m={more}")
        } else {
            format!("m={more}")
        };
        first = false;
        t.feed(format!("\x1b_G{control};{}\x1b\\", String::from_utf8_lossy(chunk)).as_bytes());
    }
    assert_eq!(placements(&t, 0).len(), 1);
    assert_eq!(t.drain().images.len(), 1);
}

#[test]
fn the_capability_probe_clients_actually_send_is_answered() {
    // How kitty graphics support is detected: there is no terminfo capability for
    // it, so a client transmits a 1x1 image with `a=q` and watches for the reply.
    // Answering this is the whole of advertising the protocol.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1b_Gi=31,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    let replies: Vec<_> = t
        .drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect();
    assert_eq!(replies, vec!["\x1b_Gi=31;OK\x1b\\"]);
}

#[test]
fn an_unsupported_capability_is_declined_out_loud() {
    // A client told ENOTSUPPORTED can fall back; one whose transmission vanishes
    // shows the user nothing and cannot find out why. Transmission by file is the
    // remaining one: reading a path a child names is a decision about trust.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1b_Ga=T,f=100,t=f,i=4;AAAA\x1b\\");
    let replies: Vec<_> = t
        .drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect();
    assert_eq!(replies, vec!["\x1b_Gi=4;ENOTSUPPORTED:medium\x1b\\"]);
}

#[test]
fn a_compressed_transmission_reaches_the_grid() {
    // End to end, the way `icat` sends it: APC through the vendored parser, base64
    // off, zlib off, pixels to a PPM, one placement per cell. 20 rows of 10 black
    // RGB pixels compress to a few dozen bytes, which is the point of `o=z`.
    // `zlib.compress(bytes(10 * 20 * 3), 9)` — 600 bytes of black in fifteen.
    const DEFLATED: &[u8] = &[120, 218, 99, 96, 24, 5, 163, 128, 250, 0, 0, 2, 88, 0, 1];
    let mut t = with_metrics(10, 20);
    let apc = format!("\x1b_Ga=T,f=24,o=z,s=10,v=20,i=4;{}\x1b\\", b64(DEFLATED));
    t.feed(apc.as_bytes());
    let update = t.drain();
    assert_eq!(update.images.len(), 1);
    // The PPM the emulator built from the inflated pixels, header and all.
    assert!(update.images[0].bytes.starts_with(b"P6\n10 20\n255\n"));
    assert_eq!(
        update.images[0].bytes.len(),
        "P6\n10 20\n255\n".len() + 10 * 20 * 3
    );
}

#[test]
fn the_same_picture_sent_twice_still_crosses_once() {
    let mut t = with_metrics(10, 20);
    let pixels = vec![0u8; 10 * 20 * 3];
    let cmd = format!("\x1b_Ga=T,f=24,s=10,v=20,i=1;{}\x1b\\", b64(&pixels));
    t.feed(cmd.as_bytes());
    t.feed(cmd.as_bytes());
    assert_eq!(t.drain().images.len(), 1);
}

#[test]
fn an_image_covers_a_rectangle_of_cells() {
    let mut t = with_metrics(10, 20);
    // 30x40 pixels at 10x20 per cell is 3 columns by 2 rows.
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(30, 40));

    for row in 0..2 {
        let placed = placements(&t, row);
        assert_eq!(placed.len(), 3, "row {row}: {placed:?}");
        for (col, p) in placed.iter().enumerate() {
            assert_eq!(p.cell_row, row as u16);
            assert_eq!(p.cell_col, col as u16);
        }
    }
    assert!(placements(&t, 2).is_empty(), "nothing below the picture");
}

/// A `c=`/`r=` kitty transmission of a one-pixel PNG, which is the cheapest way to ask
/// for a picture of an exact cell size.
fn kitty_image(t: &mut Term, control: &str) {
    let png = rgba_png(1, 1, &[0, 0, 0, 255]);
    t.feed(format!("\x1b_G{control};{}\x1b\\", b64(&png)).as_bytes());
}

#[test]
fn kitty_leaves_the_cursor_on_the_pictures_last_row() {
    let mut t = with_metrics(24, 80);
    kitty_image(&mut t, "a=T,f=100,c=3,r=2,i=1");
    // Row 1 is the picture's last, and column 3 is one past its right edge. This is
    // kitty's rule, and its clients print their own newline on top of it.
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (1, 3));
}

#[test]
fn a_sixel_leaves_the_cursor_on_the_line_below() {
    let mut t = with_metrics(24, 80);
    // The same 3x2-cell picture by the route sixel and iTerm2 take. xterm scrolls a
    // sixel to the next line, so the disposition genuinely differs from kitty's.
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(30, 40));
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (2, 0));
}

#[test]
fn a_kitty_picture_reaching_the_right_edge_wraps_to_the_next_line() {
    let mut t = with_metrics(24, 4);
    kitty_image(&mut t, "a=T,f=100,c=4,r=1,i=1");
    // Column 4 is off a four-column screen, so there is nowhere on this row for the
    // cursor to rest -- which is the one case kitty's clients expect the move for.
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (1, 0));
}

#[test]
fn an_animation_redrawn_in_place_does_not_walk_down_the_screen() {
    // What viu does per frame: draw, print a newline, and come back up by the picture's
    // height. An extra linefeed after the last row makes that arithmetic wrong by one
    // row a frame, and the picture crawls off the bottom.
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[6;1H");
    let top = t.screen().cursor.row;
    for _ in 0..4 {
        kitty_image(&mut t, "a=T,f=100,c=3,r=2,i=1");
        t.feed(b"\r\n\x1b[2A");
        assert_eq!(t.screen().cursor.row, top, "the frame drifted");
    }
}

#[test]
fn an_echo_inside_a_frame_does_not_leave_the_shell_to_erase_the_picture() {
    // Ctrl-C during an animation. `ECHOCTL` writes `^C` into the pty's output the moment
    // the key is pressed, which for a child blocked part-way through a four-megabyte
    // frame is between two pieces of that write — so the echo lands inside the payload.
    //
    // What that used to cost is the whole picture. A frame refused over two bytes nobody
    // sent places nothing, so the cursor stays where the client left it between frames:
    // the picture's *top* left, since viu comes back up by the picture's height after
    // each one. The newline viu prints after the frame then moves one row into the
    // picture rather than past it, and the shell's `ED` on its way to a new prompt erases
    // everything below — leaving the first row of the picture and the prompt in the hole.
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[6;1H");
    let top = t.screen().cursor.row;
    // A frame, then the newline viu prints after one and its climb back to the picture's
    // top row, which is where it rests between frames.
    let whole = format!("\x1b_Ga=T,f=32,s=6,v=2,c=3,r=2,i=1;{}\x1b\\", b64(&[9; 48]));
    t.feed(whole.as_bytes());
    t.feed(b"\r\n\x1b[2A");

    // The next frame, mangled the two ways one interrupt mangles it: `^C` spliced into
    // the payload, and the rest of the child's blocked write never made — six of the
    // forty-eight bytes of pixels it declared are missing.
    let payload = b64(&[7; 42]);
    let (head, tail) = payload.split_at(payload.len() / 2);
    t.feed(format!("\x1b_Ga=T,f=32,s=6,v=2,c=3,r=2,i=1;{head}^C{tail}\x1b\\").as_bytes());
    // The picture's last row, one past its right edge: where an untouched frame ends.
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (top + 1, 3));

    // So the newline and the prompt land below the picture, and both its rows survive.
    t.feed(b"\r\n\x1b[J");
    assert_eq!(placements(&t, top).len(), 3);
    assert_eq!(placements(&t, top + 1).len(), 3);
}

#[test]
fn kitty_c_leaves_the_cursor_exactly_where_it_was() {
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[3;6H");
    let entry = t.screen().cursor;
    kitty_image(&mut t, "a=T,f=100,c=3,r=2,i=1,C=1");
    assert_eq!(t.screen().cursor, entry);
    // The picture was still drawn, from the cursor as usual.
    assert_eq!(placements(&t, 2).len(), 3);
}

#[test]
fn image_cells_reach_lisp_as_one_run_of_their_own() {
    let mut t = with_metrics(10, 20);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(30, 20));
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs.len(), 1, "{runs:?}");
    // Blanks, so a yank out of the buffer gives the whitespace the picture occupied.
    assert_eq!(runs[0].text, "   ");
    assert!(matches!(runs[0].deco, Some(Deco::Images(_))), "{runs:?}");
}

#[test]
fn an_image_row_is_not_trimmed_as_trailing_blanks() {
    // Image cells are default-styled blanks, so without `Extra::is_content` the row
    // measures as empty and the picture is cut off the end of it.
    let mut t = with_metrics(10, 4);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(40, 20));
    assert_eq!(t.screen().row(0).unwrap().content_len(), 4);
    assert!(t.screen().row(0).unwrap().has_text());
    assert!(!t.screen().row(0).unwrap().is_blank());
}

#[test]
fn the_same_image_twice_crosses_the_boundary_once() {
    let mut t = with_metrics(10, 20);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(10, 20));
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(10, 20));
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1, "{:?}", delta.images);
    // ...but both placements are on the grid, naming the one id.
    assert_eq!(placements(&t, 0)[0].id, delta.images[0].id);
    assert_eq!(placements(&t, 1)[0].id, delta.images[0].id);
}

/// The bug the single-owner invariant exists for, from the emulator's side: Emacs has
/// dropped the picture, the child sends it again, and it has to arrive as a picture and
/// not as a reference to one nobody holds. Ids are content-addressed, so before
/// `forget_image` existed the second transmission was answered with the first id and no
/// bytes -- placements on the grid, nothing to draw them with.
#[test]
fn an_image_crosses_again_after_the_store_forgot_it() {
    let mut t = with_metrics(10, 20);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(10, 20));
    let first = t.drain().images[0].id;

    t.forget_image(first);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(10, 20));
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1, "{:?}", delta.images);
    assert_ne!(delta.images[0].id, first, "a forgotten id is not reissued");
    assert_eq!(placements(&t, 1)[0].id, delta.images[0].id);
}

/// Forgetting has to reach everything hung off the id, not just the ledger: the cell
/// rectangle a bare `a=p` re-places from, and the client's own name for the picture. A
/// client that places a forgotten image is told `ENOENT:image` -- the same answer as for
/// one never transmitted, because the remedy is the same -- and nothing is drawn.
#[test]
fn forgetting_an_image_takes_its_geometry_and_its_client_name_with_it() {
    let mut t = with_metrics(10, 20);
    let pixels = vec![0u8; 10 * 20 * 3];
    t.feed(format!("\x1b_Ga=t,f=24,s=10,v=20,i=7;{}\x1b\\", b64(&pixels)).as_bytes());
    let id = t.drain().images[0].id;

    t.forget_image(id);
    t.feed(b"\x1b_Ga=p,i=7\x1b\\");
    let delta = t.drain();
    assert!(
        placements(&t, 0).is_empty(),
        "nothing to place, nothing drawn"
    );
    let replies: Vec<_> = delta
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect();
    assert_eq!(replies, vec!["\x1b_Gi=7;ENOENT:image\x1b\\"]);
}

#[test]
fn writing_over_an_image_cell_retires_its_placement() {
    let mut t = with_metrics(10, 20);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(30, 20));
    t.feed(b"\x1b[1;1Hx");
    let placed = placements(&t, 0);
    assert_eq!(placed.len(), 2, "the written cell lets go: {placed:?}");
    assert_eq!(placed[0].cell_col, 1);
}

#[test]
fn erasing_into_a_picture_retires_only_the_rows_it_covered() {
    // How much of a picture survives a prompt drawn over it is decided per cell, and the
    // test above cannot say so: one cell of a one-row picture cannot tell "this cell let
    // go" apart from "the placement was retired". A shell that erases from the middle of
    // a picture to the end of the screen is the case that matters, since that is what a
    // Ctrl-C in an animation does.
    let mut t = with_metrics(10, 20);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(30, 60));
    t.feed(b"\x1b[2;1H\x1b[J");
    assert_eq!(placements(&t, 0).len(), 3, "the rows above are untouched");
    assert!(placements(&t, 1).is_empty());
    assert!(placements(&t, 2).is_empty());
}

#[test]
fn an_image_scrolls_into_history_with_its_placements() {
    let mut t = with_metrics(2, 20);
    // Four rows of picture on a two-row screen: the top rows have to scroll off.
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(20, 80));
    let delta = t.drain();
    assert!(!delta.scrolled.is_empty(), "rows should have been evicted");
    let decorated = delta
        .scrolled
        .iter()
        .flat_map(|line| &line.runs)
        .filter(|run| matches!(run.deco, Some(Deco::Images(_))))
        .count();
    assert!(decorated > 0, "scrollback kept no image cells: {delta:?}");
}

#[test]
fn an_image_survives_a_rewrap() {
    let mut t = with_metrics(4, 20);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(20, 20));
    let before = placements(&t, 0);
    t.resize(4, 40);
    // The rewrap rebases attachments by column; the picture must still be there.
    assert_eq!(placements(&t, 0), before);
}

#[test]
fn without_cell_metrics_an_image_still_lands_somewhere() {
    // A terminal frame reports no cell size. Nothing will draw this, but the grid
    // must not end up with a zero-sized or absent placement.
    let mut t = Term::new(10, 20);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(640, 480));
    assert_eq!(placements(&t, 0).len(), 1);
}

#[test]
fn dch_spares_an_underline_colour_on_a_column_it_never_touched() {
    // DCH used to drop the row's whole table, so deleting a character anywhere took
    // every colour on the row with it — including ones to the left of the cut.
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

#[test]
fn decrqm_answers_honestly_about_every_mode() {
    for (setup, mode, want) in [
        // Implemented and off, implemented and on.
        (&b""[..], 2004u16, 2u8),
        (&b"\x1b[?2004h"[..], 2004, 1),
        (&b""[..], 7, 1),
        (&b"\x1b[?7l"[..], 7, 2),
        (&b""[..], 2031, 2),
        (&b"\x1b[?2031h"[..], 2031, 1),
        (&b""[..], 2048, 2),
        (&b"\x1b[?2048h"[..], 2048, 1),
        (&b"\x1b[?1004h"[..], 1004, 1),
        (&b"\x1b[?1049h"[..], 1049, 1),
        (&b""[..], 5, 2),
        (&b"\x1b[?5h"[..], 5, 1),
        // Deliberately not implemented — the drop list, machine readable.
        (&b""[..], 12, 4),
        (&b""[..], 69, 4),
        (&b""[..], 1034, 4),
        // Never heard of it.
        (&b""[..], 9999, 0),
        // Implemented, and must not answer "never heard of it".
        (&b""[..], 1048, 1),
        // Grapheme clustering is always on, and neither a reset nor a set moves it.
        (&b""[..], 2027, 3),
        (&b"\x1b[?2027l"[..], 2027, 3),
        (&b"\x1b[?2027h\x1b[!p"[..], 2027, 3),
    ] {
        let mut t = term(4, 8, setup);
        t.feed(format!("\x1b[?{mode}$p").as_bytes());
        let want = Event::Reply(format!("\x1b[?{mode};{want}$y").into_bytes());
        assert!(
            t.drain().events.contains(&want),
            "mode {mode} after {setup:?}"
        );
    }
}

/// Every one-flag mode must set, report itself set, and come back reset by DECSTR.
///
/// The guard on `dec_flags!` staying the single table it replaced: before it, set/query/
/// reset were three hand-written lists, and a mode could be settable while reporting
/// itself unrecognised, or survive a soft reset that was supposed to clear it.
#[test]
fn every_flag_mode_sets_reports_and_soft_resets() {
    for mode in [1u16, 5, 25, 66, 1004, 1007, 2004, 2031, 2048] {
        let mut t = term(4, 8, b"");

        // Whatever it powers on as, DECRQM must not answer "never heard of it".
        t.feed(format!("\x1b[?{mode}$p").as_bytes());
        let powered_on = t.drain().events;
        assert!(
            !powered_on.contains(&Event::Reply(format!("\x1b[?{mode};0$y").into_bytes())),
            "mode {mode} reports itself unrecognised"
        );

        // Set it, and it must say so.
        t.feed(format!("\x1b[?{mode}h\x1b[?{mode}$p").as_bytes());
        assert!(
            t.drain()
                .events
                .contains(&Event::Reply(format!("\x1b[?{mode};1$y").into_bytes())),
            "mode {mode} does not report itself set"
        );

        // DECSTR puts it back, without the reset needing its own list.
        t.feed(format!("\x1b[!p\x1b[?{mode}$p").as_bytes());
        let want = if mode == 25 {
            // DECTCEM is the one flag whose power-on value is "set".
            1
        } else {
            2
        };
        assert!(
            t.drain()
                .events
                .contains(&Event::Reply(format!("\x1b[?{mode};{want}$y").into_bytes())),
            "mode {mode} survives a soft reset"
        );
    }
}

#[test]
fn decrqm_answers_for_ansi_modes_too() {
    let mut t = term(2, 8, b"\x1b[4h\x1b[4$p");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[4;1$y".to_vec()))
    );
}

/// The capabilities of every entry in `terminfo/cooked.ti`, as `(name, value)`, with
/// booleans and numbers carrying an empty value. One capability per line is the
/// file's own layout, which is what makes a parser this small enough to trust; a line
/// that does not start with a tab is an entry's name line, and `#` is a comment.
fn terminfo_capabilities() -> Vec<(&'static str, &'static str)> {
    include_str!("../../../terminfo/cooked.ti")
        .lines()
        .filter(|line| line.starts_with('\t'))
        .map(|line| {
            let field = line.trim().trim_end_matches(',');
            field.split_once('=').unwrap_or((field, ""))
        })
        .collect()
}

/// A terminfo string with no `%` parameters, decoded to the bytes it sends.
fn terminfo_decode(value: &str) -> Vec<u8> {
    assert!(!value.contains('%'), "{value:?} is parametrised");
    let mut out = Vec::new();
    let mut chars = value.chars();
    while let Some(c) = chars.next() {
        match c {
            '\\' => match chars.next() {
                Some('E' | 'e') => out.push(0x1b),
                Some(escaped) => out.push(escaped as u8),
                None => panic!("{value:?} ends in a backslash"),
            },
            '^' => out.push(chars.next().expect("^ ends the string") as u8 & 0x1f),
            _ => out.push(c as u8),
        }
    }
    out
}

/// The modes a terminfo string sets or resets, as `(private, mode, sets)`.
///
/// A mode is a run of digits and semicolons after `\E[` or `\E[?`, ended by `h` or
/// `l`. A private run ended by `%` is a mode too -- that is how `XM` and `Sync` choose
/// between the two at run time, so it counts as setting -- but an ANSI one is not,
/// being `sgr`'s `\E[0%?...m`. Anything else ending the run (`\E[6n`, `\E[3g`) is
/// some other control.
fn terminfo_modes(value: &str) -> Vec<(bool, u16, bool)> {
    let mut modes = Vec::new();
    for (at, _) in value.match_indices("\\E[") {
        let rest = &value[at + 3..];
        let (private, rest) = match rest.strip_prefix('?') {
            Some(rest) => (true, rest),
            None => (false, rest),
        };
        let digits = rest
            .find(|c: char| !c.is_ascii_digit() && c != ';')
            .unwrap_or(rest.len());
        let sets = match rest[digits..].chars().next() {
            Some('h') => true,
            Some('%') if private => true,
            Some('l') => false,
            _ => continue,
        };
        for mode in rest[..digits].split(';').filter(|m| !m.is_empty()) {
            modes.push((private, mode.parse().unwrap(), sets));
        }
    }
    modes
}

/// One element of a POSIX extended regular expression, as `terminfo_ere` parses it.
enum Ere {
    Byte(u8),
    Any,
    /// A bracket expression: its ranges, and whether it was negated with `^`.
    Class(Vec<(u8, u8)>, bool),
    Group(Vec<(Ere, Repeat)>),
}

#[derive(Clone, Copy)]
enum Repeat {
    One,
    Optional,
    Star,
    Plus,
}

/// A response pattern such as `rv` or `xr`, decoded from terminfo's escapes and then
/// parsed as the POSIX ERE that `tset` and tmux hand to `regcomp`.
///
/// This is the subset those patterns use -- literals, backslash-escaped literals, `.`,
/// bracket expressions, groups and the `* + ?` quantifiers -- and not a regex engine.
/// Alternation and `{m,n}` panic rather than being read as literals, so a pattern that
/// outgrows the parser fails the audit loudly instead of matching the wrong thing.
fn terminfo_ere(value: &str) -> Vec<(Ere, Repeat)> {
    fn sequence(bytes: &[u8], at: &mut usize, nested: bool) -> Vec<(Ere, Repeat)> {
        let mut out = Vec::new();
        while let Some(&b) = bytes.get(*at) {
            *at += 1;
            let atom = match b {
                b')' if nested => return out,
                b'(' => Ere::Group(sequence(bytes, at, true)),
                b'.' => Ere::Any,
                b'\\' => {
                    *at += 1;
                    Ere::Byte(*bytes.get(*at - 1).expect("pattern ends in a backslash"))
                }
                b'[' => {
                    let negated = bytes.get(*at) == Some(&b'^');
                    *at += usize::from(negated);
                    let mut ranges = Vec::new();
                    // A `]` straight after the opening bracket is a member, not the end.
                    let first = *at;
                    while bytes[*at] != b']' || *at == first {
                        let lo = bytes[*at];
                        if bytes[*at + 1] == b'-' && bytes[*at + 2] != b']' {
                            ranges.push((lo, bytes[*at + 2]));
                            *at += 3;
                        } else {
                            ranges.push((lo, lo));
                            *at += 1;
                        }
                    }
                    *at += 1;
                    Ere::Class(ranges, negated)
                }
                b'|' | b'{' | b'^' | b'$' => {
                    panic!("`{}' is ERE syntax the audit does not parse", b as char)
                }
                _ => Ere::Byte(b),
            };
            let repeat = match bytes.get(*at) {
                Some(b'?') => Repeat::Optional,
                Some(b'*') => Repeat::Star,
                Some(b'+') => Repeat::Plus,
                _ => Repeat::One,
            };
            *at += usize::from(!matches!(repeat, Repeat::One));
            out.push((atom, repeat));
        }
        assert!(!nested, "unclosed group");
        out
    }
    sequence(&terminfo_decode(value), &mut 0, false)
}

/// Whether `pattern` matches all of `input`, anchored at both ends: a reply with
/// anything before or after the pattern is not the reply the entry describes.
///
/// Matching tracks the set of offsets a prefix of the pattern can end at, so a `.*`
/// costs a pass over the input rather than a backtrack per byte.
fn ere_matches_whole(pattern: &[(Ere, Repeat)], input: &[u8]) -> bool {
    fn atom(e: &Ere, input: &[u8], from: usize) -> Vec<usize> {
        match e {
            Ere::Group(inner) => sequence(inner, input, vec![from]),
            _ => match input.get(from) {
                Some(&b)
                    if match e {
                        Ere::Byte(want) => b == *want,
                        Ere::Any => true,
                        Ere::Class(ranges, negated) => {
                            ranges.iter().any(|&(lo, hi)| (lo..=hi).contains(&b)) != *negated
                        }
                        Ere::Group(_) => unreachable!(),
                    } =>
                {
                    vec![from + 1]
                }
                _ => Vec::new(),
            },
        }
    }
    fn sequence(pattern: &[(Ere, Repeat)], input: &[u8], mut ends: Vec<usize>) -> Vec<usize> {
        for (e, repeat) in pattern {
            let step = |from: &[usize]| {
                let mut next: Vec<usize> = from.iter().flat_map(|&f| atom(e, input, f)).collect();
                next.sort_unstable();
                next.dedup();
                next
            };
            let once = step(&ends);
            ends = match repeat {
                Repeat::One => once,
                Repeat::Optional => [ends, once].concat(),
                Repeat::Star | Repeat::Plus => {
                    let mut all = if matches!(repeat, Repeat::Star) {
                        ends
                    } else {
                        Vec::new()
                    };
                    let mut frontier = once;
                    while !frontier.is_empty() {
                        all.extend(&frontier);
                        all.sort_unstable();
                        all.dedup();
                        frontier = step(&frontier);
                        frontier.retain(|end| !all.contains(end));
                    }
                    all
                }
            };
            ends.sort_unstable();
            ends.dedup();
        }
        ends
    }
    sequence(pattern, input, vec![0]).contains(&input.len())
}

/// The matcher the audit relies on, held to the two patterns the entry used to carry.
/// Both were xterm's and neither matches what cooked sends, so a matcher that accepted
/// either would make the `rv`/`xr` half of the audit vacuous.
#[test]
fn the_audit_ere_matcher_tells_old_patterns_from_new() {
    let da2 = b"\x1b[>0;0;0c";
    let xtversion = b"\x1bP>|cooked(1.0.0)\x1b\\";
    assert!(ere_matches_whole(&terminfo_ere(r"\E\\[>0;0;0c"), da2));
    assert!(!ere_matches_whole(
        &terminfo_ere(r"\E\\[>41;[1-6][0-9][0-9];0c"),
        da2
    ));
    assert!(ere_matches_whole(
        &terminfo_ere(r"\E\\[>41;[1-6][0-9][0-9];0c"),
        b"\x1b[>41;390;0c"
    ));
    assert!(ere_matches_whole(
        &terminfo_ere(r"\EP>\\|cooked\\((.*)\\)\E\\\\"),
        xtversion
    ));
    assert!(!ere_matches_whole(
        &terminfo_ere(r"\EP>\\|XTerm\\((.*)\\)\E\\\\"),
        xtversion
    ));
    // Anchored: a trailing byte is not the reply the pattern describes.
    assert!(!ere_matches_whole(
        &terminfo_ere(r"\E\\[>0;0;0c"),
        b"\x1b[>0;0;0cx"
    ));
}

/// The header of `cooked.ti` argues that every capability has been checked against
/// the code. This is that check, so that the argument is no longer a person reading.
///
/// Three things are held together. A mode a capability names answers DECRQM with 1
/// or 2 -- never 0, which would mean the entry claims what the core has never heard
/// of. A mode on the `# declined-modes:` line answers 4, and no capability may set
/// one: re-adding `flash` without DECSCNM is the case in point. And a query the
/// entry declares gets a reply, since a query claimed and not answered is a child
/// waiting out its timeout. For `RV` and `XR` that reply must also match the entry's
/// own `rv` and `xr`, which is what the child compares it against.
#[test]
fn terminfo_entry_matches_what_decrqm_says() {
    let source = include_str!("../../../terminfo/cooked.ti");
    let declined: Vec<u16> = source
        .lines()
        .find_map(|line| line.strip_prefix("# declined-modes:"))
        .expect("cooked.ti has lost its declined-modes line")
        .split_whitespace()
        .map(|mode| mode.parse().unwrap())
        .collect();
    let decrqm = |private: bool, mode: u16| -> u8 {
        let q = if private { "?" } else { "" };
        let mut t = term(4, 8, b"");
        t.feed(format!("\x1b[{q}{mode}$p").as_bytes());
        let prefix = format!("\x1b[{q}{mode};");
        t.drain()
            .events
            .iter()
            .find_map(|event| match event {
                Event::Reply(bytes) => bytes
                    .strip_prefix(prefix.as_bytes())
                    .and_then(|rest| rest.strip_suffix(b"$y"))
                    .map(|status| status[0] - b'0'),
                _ => None,
            })
            .unwrap_or_else(|| panic!("no DECRQM reply for mode {q}{mode}"))
    };

    for &mode in &declined {
        assert_eq!(
            decrqm(true, mode),
            4,
            "declined mode ?{mode} is not answered 4"
        );
    }

    let capabilities = terminfo_capabilities();
    for &(name, value) in &capabilities {
        for (private, mode, sets) in terminfo_modes(value) {
            let q = if private { "?" } else { "" };
            if private && declined.contains(&mode) {
                assert!(!sets, "`{name}' sets ?{mode}, which is declined");
                continue;
            }
            let status = decrqm(private, mode);
            assert!(
                status == 1 || status == 2,
                "`{name}' names mode {q}{mode}, and DECRQM answers {status}"
            );
        }
    }

    for query in ["u7", "u9", "RV", "XR"] {
        let (_, value) = capabilities
            .iter()
            .find(|(name, _)| *name == query)
            .unwrap_or_else(|| panic!("cooked.ti no longer declares `{query}'"));
        let mut t = term(4, 8, &terminfo_decode(value));
        assert!(
            t.drain()
                .events
                .iter()
                .any(|event| matches!(event, Event::Reply(_))),
            "`{query}' ({value}) gets no reply"
        );
    }

    // `tset` and tmux do not stop at a reply arriving: they match it against the
    // entry's own pattern, so a reply that drifts from `rv` or `xr` is as good as none.
    for (query, pattern) in [("RV", "rv"), ("XR", "xr")] {
        let value = |name: &str| {
            capabilities
                .iter()
                .find(|(n, _)| *n == name)
                .unwrap_or_else(|| panic!("cooked.ti no longer declares `{name}'"))
                .1
        };
        let mut t = term(4, 8, &terminfo_decode(value(query)));
        let replies: Vec<Vec<u8>> = t
            .drain()
            .events
            .into_iter()
            .filter_map(|event| match event {
                Event::Reply(bytes) => Some(bytes),
                _ => None,
            })
            .collect();
        let ere = terminfo_ere(value(pattern));
        assert!(
            replies.iter().any(|reply| ere_matches_whole(&ere, reply)),
            "`{query}' is answered {:?}, which `{pattern}' ({}) does not match",
            replies
                .iter()
                .map(|reply| String::from_utf8_lossy(reply))
                .collect::<Vec<_>>(),
            value(pattern)
        );
    }
}

/// The extended names tmux reads do what tmux will use them for.
///
/// The DECRQM check above already covers `Enfcs`, whose mode it can see. It cannot
/// see these two: modifyOtherKeys is not a mode, and OSC 8 is not a control sequence
/// at all. `Hls` is parametrised, so its value is pinned to tmux's own spelling in
/// `tty-features.c` and the two expansions tmux sends are fed by hand -- an open with
/// an `id=`, and the empty close it writes before every reset. `ol` is an SGR, which
/// no mode check sees either.
#[test]
fn the_extended_names_tmux_reads_do_what_they_say() {
    let capabilities = terminfo_capabilities();
    let value = |name: &str| {
        capabilities
            .iter()
            .find(|(n, _)| *n == name)
            .unwrap_or_else(|| panic!("cooked.ti does not declare `{name}'"))
            .1
    };

    let mut t = term(2, 20, &terminfo_decode(value("Eneks")));
    assert_eq!(
        t.keys(),
        KeyEncoding::ModifyOtherKeys(ModifyOtherKeys::Level2),
        "`Eneks'"
    );
    t.feed(&terminfo_decode(value("Dseks")));
    assert_eq!(t.keys(), KeyEncoding::Legacy, "`Dseks'");

    assert_eq!(value("Hls"), r"\E]8;%?%p1%l%tid=%p1%s%;;%p2%s\E\\");
    let t = term(
        2,
        30,
        b"\x1b]8;id=7;https://example.com/\x1b\\in\x1b]8;;\x1b\\out",
    );
    let runs = links(&t, 0);
    assert_eq!(runs.len(), 2, "{runs:?}");
    assert!(runs[0].1.is_some(), "an open with an id= links");
    assert_eq!(runs[1].1, None, "the empty close unlinks");

    // `ol' is tmux's name for SGR 59 and not ncurses', which has no `ol' at all, so
    // nothing but tmux's own `usstyle' check says what it should be. tmux sends it to
    // take a cell's underline colour back to the default.
    let mut reset = b"\x1b[4m\x1b[58;5;196m".to_vec();
    reset.extend(terminfo_decode(value("ol")));
    reset.push(b'x');
    let t = term(2, 8, &reset);
    assert_eq!(
        t.screen().row(0).unwrap().runs()[0].underline,
        Color::Default,
        "`ol'"
    );
}

#[test]
fn alternate_scroll_needs_the_alt_screen() {
    let mut t = term(2, 8, b"\x1b[?1007h");
    assert!(!t.alt_scroll(), "not while the primary screen is up");
    t.feed(b"\x1b[?1049h");
    assert!(t.alt_scroll());
}

#[test]
fn mouse_reporting_outranks_alternate_scroll() {
    // xterm's precedence: a program that asked for the wheel receives the wheel.
    let mut t = term(2, 8, b"\x1b[?1007h\x1b[?1049h\x1b[?1000h");
    assert!(!t.alt_scroll());
    t.feed(b"\x1b[?1000l");
    assert!(t.alt_scroll());
}

#[test]
fn focus_reporting_is_off_until_asked_for() {
    let mut t = term(2, 8, b"");
    assert!(!t.focus_events());
    t.feed(b"\x1b[?1004h");
    assert!(t.focus_events());
    t.feed(b"\x1b[?1004l");
    assert!(!t.focus_events());
}

/// DECSCNM reaches Emacs as a level on every drain, not as an event: it is how the
/// screen is drawn, so the drain after the set says `true' and the one after the reset
/// says `false', with no row damaged in between.
#[test]
fn reverse_screen_rides_the_drain() {
    let mut t = term(2, 8, b"ab");
    assert!(!t.drain().levels.reverse_screen);
    assert!(t.feed(b"\x1b[?5h"), "setting it is an update of its own");
    let delta = t.drain();
    assert!(delta.levels.reverse_screen);
    assert!(delta.rows.is_empty(), "no cell changed");
    assert!(t.feed(b"\x1b[?5l"), "and so is clearing it");
    assert!(!t.drain().levels.reverse_screen);
}

/// `flash' from our terminfo, and the reset `reset' sends: both have to leave the screen
/// the right way round.
#[test]
fn a_reset_puts_the_screen_the_right_way_round() {
    let mut t = term(2, 8, b"\x1b[?5h");
    assert!(t.drain().levels.reverse_screen);
    t.feed(b"\x1bc");
    assert!(!t.drain().levels.reverse_screen);
    t.feed(b"\x1b[?5$p");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?5;2$y".to_vec()))
    );
}

#[test]
fn a_soft_reset_stops_focus_reporting() {
    let t = term(2, 8, b"\x1b[?1004h\x1b[!p");
    assert!(!t.focus_events());
}

#[test]
fn decscusr_names_a_shape() {
    for (input, want) in [
        (&b"\x1b[ q"[..], CursorShape::Block),
        (&b"\x1b[2 q"[..], CursorShape::Block),
        (&b"\x1b[3 q"[..], CursorShape::Underline),
        (&b"\x1b[4 q"[..], CursorShape::Underline),
        (&b"\x1b[5 q"[..], CursorShape::Bar),
        (&b"\x1b[6 q"[..], CursorShape::Bar),
    ] {
        let mut t = term(2, 8, input);
        assert_eq!(t.drain().levels.cursor_shape, want, "{input:?}");
    }
}

#[test]
fn an_unknown_cursor_shape_is_left_alone() {
    let mut t = term(2, 8, b"\x1b[5 q\x1b[9 q");
    assert_eq!(t.drain().levels.cursor_shape, CursorShape::Bar);
}

#[test]
fn a_soft_reset_returns_the_cursor_to_a_block() {
    let mut t = term(2, 8, b"\x1b[5 q\x1b[!p");
    assert_eq!(t.drain().levels.cursor_shape, CursorShape::Block);
}

#[test]
fn xtwinops_reports_the_text_area_in_cells() {
    let mut t = term(24, 80, b"\x1b[18t");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[8;24;80t".to_vec()))
    );
}

#[test]
fn xtversion_names_cooked_and_its_own_version() {
    // terminfo declares `XR=\E[>0q`, so this has to answer or the claim is a hang. The
    // name is ours: the whole use of the query is telling terminals apart.
    let mut t = term(2, 10, b"\x1b[>0q");
    let want = format!("\x1bP>|cooked({})\x1b\\", env!("CARGO_PKG_VERSION"));
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(want.clone().into_bytes())),
        "expected {want:?}"
    );
}

#[test]
fn xtsmgraphics_answers_the_questions_a_sixel_producer_asks() {
    // Colour registers: the palette the decoder really allocates, for both the read and
    // the read-maximum actions.
    let mut t = term(24, 80, b"\x1b[?1;1S\x1b[?1;4S");
    let events = t.drain().events;
    let want = format!("\x1b[?1;0;{}S", crate::emu::sixel::PALETTE_SIZE).into_bytes();
    assert_eq!(
        events
            .iter()
            .filter(|e| **e == Event::Reply(want.clone()))
            .count(),
        2,
        "{events:?}"
    );

    // Geometry, once Emacs has said how big a cell is: the same product `14t` reports.
    let mut t = Term::new(24, 80);
    t.set_cell_metrics(CellMetrics {
        width: 10,
        height: 20,
    });
    t.feed(b"\x1b[?2;1S");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?2;0;800;480S".to_vec()))
    );
}

#[test]
fn xtsmgraphics_declines_out_loud_rather_than_leaving_a_producer_waiting() {
    // No cell size reported, so there is no geometry to give -- but the protocol has a
    // status for that, unlike `14t`, and a child that asked is owed an answer.
    let mut t = term(24, 80, b"\x1b[?2;1S");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?2;3S".to_vec()))
    );

    // Setting either item is refused: the palette is a compile-time array and the window
    // is Emacs'. ReGIS is an item we do not have at all, which is status 1.
    let mut t = term(24, 80, b"\x1b[?1;3S\x1b[?3;1S");
    let events = t.drain().events;
    let registers = format!("\x1b[?1;3;{}S", crate::emu::sixel::PALETTE_SIZE).into_bytes();
    assert!(events.contains(&Event::Reply(registers)), "{events:?}");
    assert!(
        events.contains(&Event::Reply(b"\x1b[?3;1S".to_vec())),
        "{events:?}"
    );
}

#[test]
fn xtwinops_pushes_and_pops_the_title() {
    let mut t = term(2, 10, b"\x1b[22;0;0t\x1b[23;0;0t");
    let events = t.drain().events;
    assert!(events.contains(&Event::TitleStack(true)));
    assert!(events.contains(&Event::TitleStack(false)));
}

#[test]
fn xtwinops_refuses_to_report_the_title_or_move_the_window() {
    // `21t` would put the child's own title back on its input stream. `3t`/`4t` are
    // Emacs' geometry, and so are iconify (`2t`), raise (`5t`), maximise (`9t`) and
    // full-screen (`10t`). All answer with silence, and none of them asks Lisp either.
    let mut t = term(
        2,
        10,
        b"\x1b[21t\x1b[3;0;0t\x1b[4;0;0t\x1b[2t\x1b[5t\x1b[9;1t\x1b[10;1t\x1b[13t",
    );
    let events = t.drain().events;
    assert!(events.is_empty(), "{events:?}");
}

#[test]
fn xtwinops_passes_a_resize_on_as_a_request_and_never_answers_it() {
    // `resize -s 30 100`. Honouring it is Lisp's to decide, and the child learns the
    // outcome from its own `18t`, so the grid neither resizes nor replies.
    let mut t = term(2, 10, b"\x1b[8;30;100t");
    let events = t.drain().events;
    assert_eq!(events, vec![Event::ResizeRequest(Some(30), Some(100))]);
    assert_eq!((t.screen().height(), t.screen().width()), (2, 10));
}

#[test]
fn xtwinops_resize_leaves_a_zero_dimension_alone() {
    let mut t = term(2, 10, b"\x1b[8;0;100t\x1b[8;30t\x1b[8;;0t\x1b[8t");
    assert_eq!(
        t.drain().events,
        vec![
            Event::ResizeRequest(None, Some(100)),
            Event::ResizeRequest(Some(30), None),
        ],
        "a request that leaves both dimensions alone is no request"
    );
}

#[test]
fn decslpp_asks_for_rows_alone() {
    // 24 is the smallest DECSLPP; below it the number is some other XTWINOPS.
    let mut t = term(2, 10, b"\x1b[24t\x1b[48t");
    assert_eq!(
        t.drain().events,
        vec![
            Event::ResizeRequest(Some(24), None),
            Event::ResizeRequest(Some(48), None),
        ]
    );
}

#[test]
fn xtwinops_reports_not_iconified_and_asks_lisp_for_the_frame() {
    let mut t = term(2, 10, b"\x1b[11t\x1b[19t\x1b[15t");
    assert_eq!(
        t.drain().events,
        vec![
            Event::Reply(b"\x1b[1t".to_vec()),
            Event::FrameSize(false),
            Event::FrameSize(true),
        ],
        "the order is the order asked, since a reply from Lisp rides the same list"
    );
}

#[test]
fn rep_repeats_the_last_graphic_character() {
    let t = term(2, 10, b"-\x1b[4b");
    assert_eq!(text(&t, 0), "-----");
}

#[test]
fn rep_repeats_what_dec_graphics_drew() {
    // `q` in the DEC graphics set is a horizontal rule; REP must repeat the rule,
    // not the letter that was on the wire.
    let t = term(2, 10, b"\x1b(0q\x1b[2b");
    assert_eq!(text(&t, 0), "───");
}

#[test]
fn rep_without_a_preceding_print_does_nothing() {
    let t = term(2, 10, b"\x1b[5b");
    assert_eq!(text(&t, 0), "");
}

#[test]
fn rep_ignores_a_combining_mark() {
    // The mark folds onto the `e`; REP then repeats the `e`, not the accent.
    //
    // Compared as text rather than counted: a REP that repeated the mark would fold both
    // copies back onto the same first cell, for `e` plus three accents -- four characters
    // either way, so a count cannot tell the two apart and this passed with `last_print`
    // capturing zero-width marks.
    let t = term(2, 10, b"e\xcc\x81\x1b[2b");
    assert_eq!(t.screen().row(0).unwrap().to_text(), "e\u{301}ee");
}

#[test]
fn rep_is_bounded_by_the_screen() {
    let mut t = term(2, 10, b"x\x1b[65535b");
    // Twenty cells exist; the count is capped rather than looped 65535 times.
    assert!(t.drain().scrolled.len() <= 2);
}

#[test]
fn a_tab_count_is_bounded_by_the_width() {
    // `CSI 65535 I` and `CSI 65535 Z`, the two repeat counts that were missed when REP
    // was bounded by the screen and SU/SD by the region. Both saturate long before the
    // count runs out, so the work past `cols` was provably nothing -- measured at 158x
    // slower than plain text on a 24x200 grid.
    let t = term(2, 24, b"\x1b[65535I");
    assert_eq!(t.screen().cursor.col, 23);
    let t = term(2, 24, b"\x1b[20G\x1b[65535Z");
    assert_eq!(t.screen().cursor.col, 0);
}

#[test]
fn back_tab_walks_to_the_previous_stop() {
    let t = term(2, 24, b"\x1b[20G\x1b[Z");
    assert_eq!(t.screen().cursor.col, 16);
    let t = term(2, 24, b"\x1b[20G\x1b[3Z");
    assert_eq!(t.screen().cursor.col, 0, "floors at column zero");
}

#[test]
fn autowrap_off_pins_the_cursor_to_the_last_column() {
    let t = term(2, 5, b"\x1b[?7labcdefgh");
    assert_eq!(text(&t, 0), "abcdh", "the last column keeps overwriting");
    assert_eq!(text(&t, 1), "", "and nothing wrapped below");
}

#[test]
fn autowrap_back_on_resumes_wrapping() {
    let t = term(2, 5, b"\x1b[?7labcde\x1b[?7hfg");
    assert_eq!(text(&t, 0), "abcdf");
    assert_eq!(text(&t, 1), "g");
}

#[test]
fn turning_autowrap_off_disarms_a_pending_wrap() {
    // "abcde" leaves the cursor on the last column with a wrap already decided on.
    // Clearing DECAWM has to withdraw that decision, not honour it on the next write.
    let t = term(2, 5, b"abcde\x1b[?7lX");
    assert_eq!(text(&t, 0), "abcdX");
    assert_eq!(text(&t, 1), "");
}

#[test]
fn insert_mode_shifts_the_rest_of_the_row() {
    let t = term(2, 10, b"abcd\x1b[3G\x1b[4hXY");
    assert_eq!(text(&t, 0), "abXYcd");
}

#[test]
fn insert_mode_shifts_by_a_wide_characters_full_width() {
    let t = term(2, 10, b"abcd\x1b[3G\x1b[4h\xe5\xb9\xb8");
    assert_eq!(text(&t, 0), "ab\u{5e78}cd");
}

#[test]
fn soft_reset_keeps_the_screen_but_clears_the_modes() {
    let mut t = term(2, 10, b"hello\x1b[?7l\x1b[4h\x1b[31m\x1b[?25l\x1b[!p");
    assert_eq!(text(&t, 0), "hello", "DECSTR is not RIS");
    assert!(t.drain().levels.cursor_visible, "mode 25 is back on");

    // Autowrap and insert mode are back to their power-on values.
    t.feed(b"\x1b[6Gabcdefg");
    assert_eq!(text(&t, 1), "fg", "autowrap was restored");
}

#[test]
fn the_init_string_is_understood_end_to_end() {
    // `is2`/`rs2` verbatim: DECSTR, private 3 and 4 off, ANSI 4 off, normal keypad.
    let mut t = term(2, 10, b"\x1b[4h\x1b=");
    t.feed(b"\x1b[!p\x1b[?3;4l\x1b[4l\x1b>");
    t.feed(b"ab\x1b[1GX");
    assert_eq!(text(&t, 0), "Xb", "insert mode is off, so X overwrites");
}

#[test]
fn device_attributes_name_only_what_we_implement() {
    let mut t = term(2, 10, b"\x1b[c\x1b[>c");
    let events = t.drain().events;
    assert!(events.contains(&Event::Reply(b"\x1b[?62;4;22c".to_vec())));
    assert!(events.contains(&Event::Reply(b"\x1b[>0;0;0c".to_vec())));
}

#[test]
fn tertiary_device_attributes_answer_a_zero_unit_id() {
    let mut t = term(2, 10, b"\x1b[=c\x1b[=0c\x1b[=1c");
    let replies: Vec<_> = t
        .drain()
        .events
        .into_iter()
        .filter(|event| matches!(event, Event::Reply(_)))
        .collect();
    // `=1c` is not DA3, and answering it would put a reply where no child waits.
    assert_eq!(
        replies,
        vec![Event::Reply(b"\x1bP!|00000000\x1b\\".to_vec()); 2]
    );
}

#[test]
fn meta_sending_escape_is_permanently_set() {
    // Both before and after a child tries to turn it off: Lisp spells Meta as ESC
    // whatever the core is told, so the answer must not follow the request.
    let mut t = term(2, 10, b"\x1b[?1036$p\x1b[?1036l\x1b[?1036$p");
    let replies = t.drain().events;
    let set = Event::Reply(b"\x1b[?1036;3$y".to_vec());
    assert_eq!(replies.iter().filter(|event| **event == set).count(), 2);
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

#[test]
fn scrolled_rows_are_handed_over_exactly_once() {
    let mut t = term(2, 8, b"one\r\ntwo\r\nthree");
    let delta = t.drain();
    assert_eq!(delta.scrolled.len(), 1);
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
    assert!(t.drain().scrolled.is_empty());
}

#[test]
fn scrolled_lines_carry_their_wrap_provenance() {
    // Eight columns, so "abcdefghij" is one logical line spread over two rows.
    let mut t = term(2, 8, b"abcdefghij\r\nsecond\r\nthird");
    let delta = t.drain();

    assert_eq!(delta.scrolled.len(), 2);
    assert!(
        delta.scrolled[0].wrapped,
        "the overflowing row continues below"
    );
    assert_eq!(runs_text(&delta.scrolled[0]), "abcdefgh");
    assert!(!delta.scrolled[1].wrapped, "a real newline ends the line");
    assert_eq!(runs_text(&delta.scrolled[1]), "ij");
}

/// A continuation row's trailing blanks are interior to the line, not the end of it.
/// Emacs rejoins a wrapped row onto the line above without a newline, so cutting them
/// pulls the continuation forward — and column-aligned output like `ps` is padded with
/// spaces at every boundary, so a wrap landing inside a run of them is the common case.
#[test]
fn a_wrapped_row_keeps_the_blanks_that_are_interior_to_its_line() {
    // Eight columns. "abc     def" wraps with the row boundary inside the spaces.
    let mut t = term(2, 8, b"abc     def\r\nsecond\r\nthird");
    let delta = t.drain();

    assert_eq!(delta.scrolled.len(), 2);
    assert!(delta.scrolled[0].wrapped);
    assert_eq!(
        runs_text(&delta.scrolled[0]),
        "abc     ",
        "all eight columns, or the line reassembles as `abcdef`"
    );
    assert_eq!(runs_text(&delta.scrolled[1]), "def");
}

/// The invariant [`Screen::carried`] rests on: every row that leaves for Emacs while
/// its line continues is exactly `cols` characters, so `carried * cols` measures the
/// head. A rewrap blank-pads its chunks out to the full width, so this is what keeps
/// the seam from drifting once a resize has evicted padded rows.
#[test]
fn every_wrapped_row_handed_over_is_exactly_a_full_row_wide() {
    let mut t = Term::new(4, 10);
    // Four space-padded lines, each reaching the right edge, filling the grid.
    for _ in 0..4 {
        t.feed(b"aa   bb   \r\n");
    }
    t.drain();
    t.resize(2, 4);
    let delta = t.drain();

    for line in &delta.scrolled {
        if line.wrapped {
            assert_eq!(
                runs_text(line).chars().count(),
                4,
                "a continuation row must fill its width: {:?}",
                runs_text(line)
            );
        }
    }
}

#[test]
fn alt_screen_output_never_reaches_scrollback() {
    let mut t = term(2, 8, b"keep\r\n");
    t.drain();
    t.feed(b"\x1b[?1049h");
    t.feed(b"a\r\nb\r\nc\r\nd\r\n");
    let delta = t.drain();
    assert!(
        delta.scrolled.is_empty(),
        "alt screen must not pollute history"
    );
    assert!(delta.levels.alt);

    t.feed(b"\x1b[?1049l");
    let back = t.drain();
    assert!(!back.levels.alt);
    assert_eq!(text(&t, 0), "keep");
}

#[test]
fn osc_133_becomes_semantic_events() {
    let mut t = term(
        4,
        20,
        b"\x1b]133;A\x07$ \x1b]133;B\x07ls\x1b]133;C\x07out\x1b]133;D;3\x07",
    );
    let events = t.drain().events;
    let at = |row, col| Anchor { row, col };
    assert_eq!(
        events,
        vec![
            // Anchored where each mark actually fell on the one row this writes:
            // column 0, then after "$ ", then after "ls", then after "out".
            // The ids are the order the marks were parsed in, which is what pairs
            // each one back up with the marker Emacs makes for it.
            Event::PromptStart(at(0, 0), MarkId(0)),
            Event::PromptEnd(at(0, 2), MarkId(1)),
            Event::CommandStart(None, at(0, 4), MarkId(2)),
            Event::CommandEnd(Some(3), at(0, 7), MarkId(3)),
        ]
    );
}

/// PS2. The mark the shell puts on a continuation prompt has to reach Emacs as
/// something other than a fresh prompt, or the command record for a multi-line
/// construct begins at its last line instead of at the prompt it was typed at.
#[test]
fn osc_133_marks_a_continuation_prompt() {
    let mut t = term(4, 20, b"\x1b]133;A\x07> \x1b]133;A;k=s\x07\x1b]133;B\x07");
    let events = t.drain().events;
    let at = |row, col| Anchor { row, col };
    assert_eq!(
        events,
        vec![
            Event::PromptStart(at(0, 0), MarkId(0)),
            Event::PromptContinuation(at(0, 2), MarkId(1)),
            Event::PromptEnd(at(0, 2), MarkId(2)),
        ]
    );
}

/// The proposal hangs `k=` off `P` and calls `A` shorthand for `P;k=i`, and Ghostty
/// emits `P` from its prompt strings to dodge `A`'s implied fresh line. cooked has no
/// fresh-line behaviour, so `P` would be the same mark under a second name -- and
/// nothing that sends it can reach this parser, since the shipped snippets are gated on
/// `TERM_PROGRAM=cooked` and write `A`, as does a fish 4 marking its own prompts. So a
/// `P` is a kind this parser has never heard of, and is dropped whole like any other:
/// no event, no mark id spent, and in particular no prompt start, which is the one
/// outcome that would move state on a mark nobody here meant to send.
#[test]
fn osc_133_ignores_the_other_spelling_of_the_prompt_mark() {
    let mut t = term(4, 20, b"\x1b]133;P;k=s\x07\x1b]133;P\x07\x1b]133;A\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::PromptStart(Anchor { row: 0, col: 0 }, MarkId(0))]
    );
}

/// The bug this cost: `k=r` is the prompt drawn to the *right* of the input line, not
/// a continuation of anything. No `B` follows one, so reading it as a `PS2` left Emacs
/// in `prompt` for the rest of the session with the input line gone for good.
///
/// A kind nobody here has heard of joins it: the safe answer for an unknown mark is to
/// move no state, and both of the other answers move some.
#[test]
fn osc_133_drops_a_prompt_kind_that_is_neither_initial_nor_a_continuation() {
    for kind in [&b"r"[..], b"z", b"unheard-of"] {
        let mut t = Term::new(4, 20);
        t.feed(b"\x1b]133;A\x07");
        t.feed(format!("\x1b]133;A;k={}\x07", String::from_utf8_lossy(kind)).as_bytes());
        assert_eq!(
            t.drain().events,
            vec![Event::PromptStart(Anchor { row: 0, col: 0 }, MarkId(0))],
            "k={} should have been dropped whole",
            String::from_utf8_lossy(kind)
        );
    }
}

/// `c` is the proposal's spelling of the same thing kitty calls `s`.
#[test]
fn osc_133_reads_both_spellings_of_a_continuation() {
    let mut t = term(4, 20, b"\x1b]133;A;k=c\x07\x1b]133;A;k=s\x07");
    let at = |row, col| Anchor { row, col };
    assert_eq!(
        t.drain().events,
        vec![
            Event::PromptContinuation(at(0, 0), MarkId(0)),
            Event::PromptContinuation(at(0, 0), MarkId(1)),
        ]
    );
}

/// The proposal gives the kind a default of `i`, so `k=` with nothing after it is an
/// emitter saying nothing rather than an emitter naming a kind we have never heard of.
#[test]
fn osc_133_treats_an_empty_prompt_kind_as_initial() {
    let mut t = term(4, 20, b"\x1b]133;A;k=\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::PromptStart(Anchor { row: 0, col: 0 }, MarkId(0))]
    );
}

/// The options real terminals actually send, none of which is a `k=`: kitty's
/// `click_events=` (which is what fish 4 emits), Ghostty's `redraw=` and `cl=`, and
/// ble.sh's `aid=`. Every one of them is an ordinary prompt start.
#[test]
fn osc_133_ignores_the_options_that_are_not_a_prompt_kind() {
    for opts in [
        &b"click_events=1"[..],
        b"redraw=last;cl=line;aid=123",
        b"cl=line",
    ] {
        let mut t = Term::new(4, 20);
        t.feed(&[b"\x1b]133;A;", opts, b"\x07"].concat());
        assert_eq!(
            t.drain().events,
            vec![Event::PromptStart(Anchor { row: 0, col: 0 }, MarkId(0))],
            "{} should have been an initial prompt",
            String::from_utf8_lossy(opts)
        );
    }
}

/// The kind field is matched whole. Reading only its first byte had `Dfoo` agreeing to
/// be a `D`, which is the parser inventing consent from a sender that meant something
/// else. The examples are spelled with kinds this parser *does* accept, because those
/// are the ones a prefix match would wrongly swallow -- a suffix on a kind nobody reads
/// is dropped either way and would prove nothing.
#[test]
fn osc_133_matches_the_kind_field_exactly() {
    let mut t = term(4, 20, b"\x1b]133;Dfoo\x07\x1b]133;Az\x07\x1b]133;\x07");
    assert!(t.drain().events.is_empty());
}

/// `clear_to_prompt` cuts at the prompt the construct began at, so a continuation
/// must leave that anchor alone -- the whole reason `k=` is parsed rather than dropped.
#[test]
fn a_continuation_prompt_does_not_move_the_clear_anchor() {
    let mut t = Term::new(6, 20);
    t.feed(b"noise\r\n\x1b]133;A\x07$ for x in 1 2; do\r\n");
    t.feed(b"\x1b]133;A;k=s\x07> echo $x\r\n");
    t.drain();
    // Two rows kept: the prompt row and the continuation under it. Had the
    // continuation moved the anchor, only the second would have survived.
    assert_eq!(t.clear_to_prompt(), 1);
    assert_eq!(text(&t, 0), "$ for x in 1 2; do");
}

#[test]
fn osc_133_d_without_a_status() {
    let mut t = term(4, 20, b"\x1b]133;D\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::CommandEnd(
            None,
            Anchor { row: 0, col: 0 },
            MarkId(0)
        )]
    );
}

#[test]
fn unhandled_osc_is_passed_through_verbatim() {
    let mut t = term(4, 20, b"\x1b]0;hi\x07\x1b]7;file://h/tmp\x07");
    assert_eq!(
        t.drain().events,
        vec![
            Event::Osc(0, vec!["hi".into()], true),
            Event::Osc(7, vec!["file://h/tmp".into()], true),
        ]
    );
}

#[test]
fn osc_payloads_keep_their_internal_separators() {
    // vterm's eval protocol embeds quoted arguments that may contain ';'.
    let mut t = term(4, 20, b"\x1b]51;E\"find-file\" \"/tmp/a;b\"\x1b\\");
    assert_eq!(
        t.drain().events,
        vec![Event::Osc(
            51,
            vec!["E\"find-file\" \"/tmp/a".into(), "b\"".into()],
            false
        )]
    );
}

#[test]
fn osc_52_clipboard_is_passed_through() {
    let mut t = term(4, 20, b"\x1b]52;c;aGVsbG8=\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::Osc(52, vec!["c".into(), "aGVsbG8=".into()], true)]
    );
}

#[test]
fn osc_133_stays_typed() {
    let mut t = term(4, 20, b"\x1b]133;A\x07");
    assert_eq!(
        t.drain().events,
        vec![Event::PromptStart(Anchor { row: 0, col: 0 }, MarkId(0))]
    );
}

/// The bug anchors exist for: two commands inside one drain must not collapse onto
/// the end-of-drain cursor, which is where the *second* one ended.
#[test]
fn marks_in_one_drain_keep_their_own_positions() {
    let mut t = term(
        8,
        20,
        b"\x1b]133;C\x07one\r\n\x1b]133;D;0\x07\x1b]133;C\x07two\r\n\x1b]133;D;0\x07",
    );
    let starts: Vec<Anchor> = t
        .drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::CommandStart(_, at, _) => Some(at),
            _ => None,
        })
        .collect();
    assert_eq!(
        starts,
        vec![Anchor { row: 0, col: 0 }, Anchor { row: 1, col: 0 }]
    );
}

/// The exception in `Row::retire`, and the whole reason marks can be moved at all:
/// `OSC 133;A` arrives before the shell prints its prompt, so the very first
/// character of that prompt is written over the cell the mark landed on.
#[test]
fn a_mark_survives_the_prompt_printed_over_it() {
    let t = term(4, 20, b"\x1b]133;A\x07$ ");
    let marks: Vec<_> = t.screen().row(0).unwrap().marks().collect();
    assert_eq!(marks, vec![(0, MarkId(0))], "the mark is still on column 0");
    assert_eq!(text(&t, 0), "$", "and the prompt is still drawn");
}

/// The reported bug: a resize rewraps the grid, Emacs rebuilds every live row from
/// it, and the buffer markers it took from the original anchors are left pointing at
/// text that has moved. The mark comes through the rewrap on the cell it went in on,
/// so the drain can say where that cell is now.
#[test]
fn a_rewrap_reports_where_each_mark_moved_to() {
    // Twelve cells of one logical line at ten columns: row 0 wrapped, row 1 holding
    // "ab", and the mark on the cell after them.
    let mut t = term(4, 10, b"0123456789ab\x1b]133;A\x07");
    t.drain();
    assert!(
        t.screen().row(1).unwrap().marks().any(|(col, _)| col == 2),
        "the mark starts on row 1, column 2"
    );

    t.resize(4, 7);
    let delta = t.drain();
    // Offset 12 into the line, re-chunked at seven columns: row 1, column 5.
    assert_eq!(delta.marks, vec![(MarkId(0), Anchor { row: 1, col: 5 })]);
}

/// The other half of the same drain: a rewrap narrow enough pushes rows off the top,
/// and a mark on one of them is in text Emacs is about to *insert* rather than on a
/// row it is about to rewrite. Both spellings are what `anchor_to_lisp` exists for.
#[test]
fn a_mark_evicted_by_a_rewrap_is_reported_in_the_batch() {
    // Two rows of one logical line at ten columns, with the mark at the top of it.
    // Re-chunked at four columns that line needs five rows, and the grid has four.
    let mut t = term(4, 10, b"\x1b]133;A\x070123456789abcdefghij");
    t.drain();
    t.resize(4, 4);
    let delta = t.drain();
    let (_, at) = delta
        .marks
        .iter()
        .find(|(id, _)| *id == MarkId(0))
        .expect("the mark is still accounted for");
    assert!(
        at.row < delta.scrolled_base + delta.scrolled.len(),
        "its row is in this drain's scrollback batch, not on the grid: {at:?}"
    );
}

/// A scroll re-anchors too, and the difference from a rewrap is only one of degree.
/// Emacs rebuilds its live text around every row that leaves -- the row goes in above
/// as scrollback while the rows below move up a slot -- and the two renderings of that
/// row are not the same length, because `cooked-rejoin-wrapped-lines' withholds the
/// newline from a continuation row. One character per wrapped row that leaves is
/// enough for a long-running command's marker to walk off its own prompt.
#[test]
fn a_scroll_reports_the_marks_it_moved() {
    let mut t = term(3, 10, b"\x1b]133;A\x07one\r\n");
    t.drain();
    t.feed(b"two\r\nthree\r\nfour\r\n");
    let delta = t.drain();
    let (id, at) = delta
        .marks
        .first()
        .copied()
        .expect("the mark is accounted for");
    assert_eq!(id, MarkId(0));
    assert!(
        at.row < delta.scrolled_base + delta.scrolled.len(),
        "it left with its row, so it is spelled into the batch: {at:?}"
    );
}

/// And a drain that moved nothing says nothing, which is what keeps this off the
/// ordinary path: a screen with room left scrolls no rows and re-anchors no marks.
#[test]
fn a_drain_that_moves_nothing_reports_no_marks() {
    let mut t = term(8, 10, b"\x1b]133;A\x07one\r\n");
    t.drain();
    t.feed(b"two\r\n");
    assert!(t.drain().marks.is_empty());
}

/// An anchor outlives the row it was taken from: once the marked row has scrolled
/// away, its absolute row is below the base of the batch still on the grid.
#[test]
fn an_anchor_survives_the_row_scrolling_off() {
    let mut t = term(3, 20, b"\x1b]133;C\x07start\r\n");
    t.feed(b"a\r\nb\r\nc\r\nd\r\n");
    let delta = t.drain();
    let Some(Event::CommandStart(_, at, _)) = delta.events.first() else {
        panic!("no command-start: {:?}", delta.events);
    };
    assert_eq!(at.row, 0, "the mark fell on the first row written");
    assert!(
        at.row < delta.scrolled_base + delta.scrolled.len(),
        "the marked row is in this batch of scrollback, not on the grid"
    );
    assert_eq!(delta.scrolled_base, 0, "nothing scrolled before this drain");
}

#[test]
fn mouse_modes_accumulate_and_report() {
    let mut t = term(4, 20, b"\x1b[?1002h\x1b[?1006h");
    let mouse = t.mouse();
    assert!(mouse.click && mouse.drag && mouse.sgr());
    assert!(
        t.drain()
            .events
            .iter()
            .any(|e| matches!(e, Event::Mouse(_)))
    );

    t.feed(b"\x1b[?1002l\x1b[?1006l");
    assert!(!t.mouse().enabled());
}

/// 1006 and 1016 are one choice, not two flags: xterm makes the extended coordinate
/// modes mutually exclusive, a set replacing whatever was in force and a reset effective
/// only against its own mode.
#[test]
fn mouse_coordinate_modes_replace_each_other() {
    let rqm = |t: &mut Term, mode: u16| {
        t.feed(format!("\x1b[?{mode}$p").as_bytes());
        let events = t.drain().events;
        [1u8, 2]
            .into_iter()
            .find(|v| events.contains(&Event::Reply(format!("\x1b[?{mode};{v}$y").into_bytes())))
    };

    let mut t = term(4, 20, b"\x1b[?1000h\x1b[?1006h\x1b[?1016h");
    assert_eq!(t.mouse().format, MouseFormat::SgrPixels);
    assert!(t.mouse().sgr() && t.mouse().pixels());
    assert_eq!((rqm(&mut t, 1006), rqm(&mut t, 1016)), (Some(2), Some(1)));

    // Resetting the mode that is not in force changes nothing...
    t.feed(b"\x1b[?1006l");
    assert_eq!(t.mouse().format, MouseFormat::SgrPixels);
    // ...and resetting the one that is falls back to X10, not to the SGR it replaced.
    t.feed(b"\x1b[?1016l");
    assert_eq!(t.mouse().format, MouseFormat::X10);

    // The report goes out on every change, pixels included, and a soft reset clears it.
    t.feed(b"\x1b[?1016h");
    assert!(
        t.drain()
            .events
            .iter()
            .any(|e| matches!(e, Event::Mouse(m) if m.pixels()))
    );
    t.feed(b"\x1b[!p");
    assert_eq!(t.mouse(), Mouse::default());
    assert_eq!(rqm(&mut t, 1016), Some(2));
}

#[test]
fn cursor_position_report_is_answered() {
    let mut t = term(4, 20, b"\x1b[3;5H\x1b[6n");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[3;5R".to_vec()))
    );
}

#[test]
fn status_report_is_answered() {
    let mut t = term(4, 20, b"\x1b[5n");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[0n".to_vec()))
    );
}

#[test]
fn the_colour_scheme_is_unanswered_until_emacs_has_said() {
    // The protocol has a value for dark and one for light and none for "not yet", so the
    // only honest answer here is none at all.
    let mut t = term(4, 20, b"\x1b[?996n");
    assert!(
        t.drain()
            .events
            .iter()
            .all(|e| !matches!(e, Event::Reply(_)))
    );
}

#[test]
fn the_colour_scheme_is_answered_once_reported() {
    for (scheme, want) in [
        (ColorScheme::Dark, &b"\x1b[?997;1n"[..]),
        (ColorScheme::Light, &b"\x1b[?997;2n"[..]),
    ] {
        let mut t = term(4, 20, b"");
        t.set_color_scheme(scheme);
        t.feed(b"\x1b[?996n");
        assert!(
            t.drain().events.contains(&Event::Reply(want.to_vec())),
            "{scheme:?}"
        );
    }
}

#[test]
fn only_a_subscriber_is_pushed_the_colour_scheme() {
    let mut t = term(4, 20, b"");
    assert_eq!(t.set_color_scheme(ColorScheme::Dark), None);

    t.feed(b"\x1b[?2031h");
    // The same scheme again is not an event, however often Emacs reloads the theme.
    assert_eq!(t.set_color_scheme(ColorScheme::Dark), None);
    assert_eq!(
        t.set_color_scheme(ColorScheme::Light),
        Some(b"\x1b[?997;2n".to_vec())
    );

    t.feed(b"\x1b[?2031l");
    assert_eq!(t.set_color_scheme(ColorScheme::Dark), None);
    // Unsubscribing ends the push and nothing else: the pull is not a negotiation.
    t.feed(b"\x1b[?996n");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?997;1n".to_vec()))
    );
}

#[test]
fn a_soft_reset_ends_the_subscription_and_keeps_the_scheme() {
    // This is what the field placement buys, and the only test that pins it: the
    // subscription is a mode the child negotiated and lives on `Modes`, so DECSTR clears
    // it; the scheme is Emacs' report about its own theme and lives on `State`, so DECSTR
    // must not, or a child that queried after one would be told nothing about a theme
    // that had not changed.
    let mut t = term(4, 20, b"");
    t.set_color_scheme(ColorScheme::Light);
    t.feed(b"\x1b[?2031h\x1b[!p");
    assert_eq!(t.set_color_scheme(ColorScheme::Dark), None);

    t.feed(b"\x1b[?996n");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?997;1n".to_vec()))
    );
}

#[test]
fn a_private_status_report_we_do_not_implement_is_not_answered() {
    // The `996` guard rather than a bare `(Some(b'?'), 'n')` arm: an unimplemented
    // private DSR must stay unimplemented rather than be silently swallowed.
    let mut t = term(4, 20, b"");
    t.set_color_scheme(ColorScheme::Dark);
    t.feed(b"\x1b[?15n\x1b[?6n");
    assert!(
        t.drain()
            .events
            .iter()
            .all(|e| !matches!(e, Event::Reply(_)))
    );
}

/// The terminator has to survive the trip to Lisp: a client that queried with BEL
/// will not recognise an ST-terminated answer, and vice versa.
#[test]
fn osc_terminator_travels_with_the_event() {
    let mut t = term(4, 20, b"\x1b]11;?\x07\x1b]11;?\x1b\\");
    assert_eq!(
        t.drain().events,
        vec![
            Event::Osc(11, vec!["?".into()], true),
            Event::Osc(11, vec!["?".into()], false),
        ]
    );
}

#[test]
fn osc_reply_echoes_the_terminator_it_was_asked_with() {
    assert_eq!(
        osc_reply(11, "rgb:0000/0000/0000", true).unwrap(),
        b"\x1b]11;rgb:0000/0000/0000\x07"
    );
    assert_eq!(
        osc_reply(11, "rgb:ffff/ffff/ffff", false).unwrap(),
        b"\x1b]11;rgb:ffff/ffff/ffff\x1b\\"
    );
}

/// A colour name can arrive from the child in a set request and come straight back
/// out in the echo, so the payload is not ours to trust.
#[test]
fn osc_reply_refuses_a_payload_that_could_close_the_sequence() {
    assert_eq!(osc_reply(11, "red\x07\x1b]0;pwned", true), None);
    assert_eq!(osc_reply(11, "red\x1b\\", false), None);
    assert_eq!(osc_reply(11, "red\x7f", true), None);
}

#[test]
fn erase_display_clears_below() {
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.feed(b"\x1b[2;1H\x1b[J");
    assert_eq!(text(&t, 0), "aaa");
    assert_eq!(text(&t, 1), "");
    assert_eq!(text(&t, 2), "");
}

#[test]
fn erase_scrollback_is_flagged_as_an_event_and_leaves_the_screen_alone() {
    // Unlike `CSI 2 J`, real xterm's `3 J` never touches the visible screen — only
    // the scrollback, which the grid does not hold, so it does nothing at all here.
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.drain();
    t.feed(b"\x1b[3J");
    let delta = t.drain();
    assert_eq!(delta.events, vec![Event::EraseScrollback]);
    assert!(delta.rows.is_empty(), "nothing on the grid changed");
    assert_eq!(text(&t, 0), "aaa");
    assert_eq!(text(&t, 1), "bbb");
    assert_eq!(text(&t, 2), "ccc");
}

#[test]
fn a_partial_erase_raises_neither_clearing_event() {
    // `0 J` and `1 J` are a child rewriting part of a screen it is still drawing on,
    // not finishing with one: no scrollback goes, and no viewport moves.
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.drain();
    t.feed(b"\x1b[0J\x1b[1J");
    assert!(t.drain().events.is_empty());
}

#[test]
fn clearing_the_display_asks_emacs_to_show_the_blank_screen() {
    // The rows are archived rather than lost, so nothing scrolls out of view on its
    // own: `2 J` looks like nothing happened unless Emacs moves the window, and this
    // event is what tells it to.
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.drain();
    t.feed(b"\x1b[2J");
    assert_eq!(t.drain().events, vec![Event::DisplayCleared]);
}

#[test]
fn a_reset_clears_the_display_like_any_other() {
    let mut t = term(3, 8, b"aaa\r\nbbb\r\nccc");
    t.drain();
    t.feed(b"\x1bc");
    assert!(t.drain().events.contains(&Event::DisplayCleared));
}

#[test]
fn a_reset_says_so_where_a_soft_reset_does_not() {
    // The event Emacs needs in order to drop the state it holds on the emulator's
    // behalf, which is why the distinction below is load-bearing rather than pedantic:
    // every `rs2` and `is2` sends DECSTR, so a soft reset firing this would clear a
    // running build's progress every time a full-screen program tidied up after itself.
    let mut t = term(3, 8, b"aaa");
    t.drain();
    t.feed(b"\x1b[!p");
    assert!(
        !t.drain().events.contains(&Event::Reset),
        "DECSTR is not RIS"
    );
    t.feed(b"\x1bc");
    assert!(t.drain().events.contains(&Event::Reset));
}

/// `reset` from a shell whose full-screen program died without its `rmcup`: RIS has to
/// bring the user back to the primary screen, and say so on the drain's `alt` level,
/// which is the only way Lisp hears of any alt switch.
#[test]
fn a_reset_leaves_the_alternate_screen() {
    let mut t = term(3, 8, b"keep\r\n");
    t.feed(b"\x1b[?1049hfull");
    assert!(t.drain().levels.alt);
    t.feed(b"\x1bc");
    let delta = t.drain();
    assert!(!delta.levels.alt, "the drain carries the switch back");
    assert!(delta.events.contains(&Event::Reset));
    assert!(
        delta.events.contains(&Event::DisplayCleared),
        "the erase ran on the primary, where clearing is worth announcing"
    );
    assert!(
        delta.scrolled.iter().any(|line| runs_text(line) == "keep"),
        "the primary's text was archived by the erase, as on any RIS"
    );
    assert!(
        !delta.scrolled.iter().any(|line| runs_text(line) == "full"),
        "nothing from the alternate screen reached scrollback"
    );
    assert_eq!(text(&t, 0), "");
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (0, 0));
    t.feed(b"\x1b[?1049$p");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?1049;2$y".to_vec()))
    );
    // Nothing the program saved on the way in survives to be restored on a stray
    // `rmcup` afterwards.
    t.feed(b"ab\x1b[?1049l");
    assert_eq!(text(&t, 0), "ab");
    assert_eq!(t.screen().cursor.col, 2);
}

/// RIS puts the stops back on both screens; DECSTR, like xterm's, leaves them alone.
#[test]
fn a_reset_restores_the_tab_stops_on_both_screens() {
    let mut t = term(2, 30, b"\x1b[3g\x1b[?1049h\x1b[3g\x1b[?1049l\x1b[!p\tx");
    assert_eq!(
        t.screen().cursor.col,
        29,
        "a soft reset kept the cleared stops"
    );
    t.feed(b"\x1bc\tx");
    assert_eq!(text(&t, 0), "        x");
    t.feed(b"\x1b[?1049h\t\ty");
    assert_eq!(
        text(&t, 0),
        "                y",
        "the alternate screen's stops are back too"
    );
}

#[test]
fn the_alt_screen_never_reports_a_cleared_display() {
    // It archives nothing and is pinned to the top of the window already, so there is
    // no transcript for a window to scroll away from.
    let mut t = term(3, 8, b"aaa\r\nbbb");
    t.feed(b"\x1b[?1049h");
    t.drain();
    t.feed(b"\x1b[2J");
    assert!(t.drain().events.is_empty());
}

#[test]
fn clearing_to_the_prompt_keeps_the_prompt_and_drops_what_is_above_it() {
    let mut t = term(4, 8, b"one\r\ntwo\r\n\x1b]133;A\x1b\\$ ls");
    t.drain();
    assert_eq!(t.clear_to_prompt(), 2);
    assert_eq!(text(&t, 0), "$ ls");
    assert_eq!(text(&t, 1), "");
    assert_eq!(t.screen().cursor.row, 0, "the cursor rides up with its row");
}

#[test]
fn clearing_to_the_prompt_falls_back_to_the_cursor_row() {
    // No OSC 133 to go on: whatever the child is on now is the line being looked at.
    let mut t = term(4, 8, b"one\r\ntwo\r\nthree");
    t.drain();
    assert_eq!(t.clear_to_prompt(), 2);
    assert_eq!(text(&t, 0), "three");
}

#[test]
fn clearing_to_the_prompt_twice_still_knows_where_the_prompt_is() {
    // The mark is absolute, and rows removed this way are discarded rather than
    // archived, so the count they are absolute against does not move: the anchor has
    // to come down instead, or the second call cuts at the cursor and eats the prompt.
    let mut t = term(4, 8, b"one\r\ntwo\r\n\x1b]133;A\x1b\\$ ls");
    t.drain();
    t.clear_to_prompt();
    t.feed(b"\r\nout");
    t.drain();
    assert_eq!(t.clear_to_prompt(), 0, "the prompt is already on row 0");
    assert_eq!(text(&t, 0), "$ ls");
    assert_eq!(text(&t, 1), "out");
}

#[test]
fn removing_rows_brings_the_prompt_mark_down_with_them() {
    // `cooked-delete-output' removes a finished command's rows, which sit above the
    // prompt. The mark is absolute and these rows are discarded rather than archived,
    // so nothing else moves it: left alone it names a row past the cursor, fails
    // `clear_to_prompt's own sanity filter, and silently falls back to cutting at the
    // cursor -- eating the first line of a two-line prompt.
    let mut t = term(6, 8, b"out1\r\nout2\r\n\x1b]133;A\x1b\\user\r\n$ ");
    t.drain();
    // The two output rows above the prompt.
    t.remove_rows(0, 2);
    assert_eq!(text(&t, 0), "user");
    assert_eq!(text(&t, 1), "$");
    // The prompt is two rows tall and now starts at row 0, so there is nothing above
    // it left to clear. Without the rebase this cuts one row, taking `user' with it.
    assert_eq!(t.clear_to_prompt(), 0);
    assert_eq!(text(&t, 0), "user", "the prompt's first line must survive");
    assert_eq!(text(&t, 1), "$");
}

#[test]
fn removing_the_prompts_own_row_clamps_the_mark_rather_than_losing_it() {
    let mut t = term(6, 8, b"out\r\n\x1b]133;A\x1b\\$ ls");
    t.drain();
    // Takes the output row and the prompt row with it.
    t.remove_rows(0, 2);
    // The mark clamps to the row that closed the gap, exactly as the cursor does, so
    // it stays a row on the grid rather than one past the end of it.
    assert_eq!(t.clear_to_prompt(), 0);
}

#[test]
fn removing_rows_below_the_prompt_leaves_the_mark_where_it_is() {
    let mut t = term(6, 8, b"\x1b]133;A\x1b\\$ ls\r\nout1\r\nout2\r\ntail");
    t.drain();
    t.remove_rows(2, 1);
    assert_eq!(text(&t, 0), "$ ls");
    assert_eq!(text(&t, 1), "out1");
    assert_eq!(text(&t, 2), "tail");
    assert_eq!(t.clear_to_prompt(), 0, "the prompt is still on row 0");
}

#[test]
fn removing_alt_screen_rows_does_not_move_the_primarys_prompt_mark() {
    let mut t = term(6, 8, b"out\r\n\x1b]133;A\x1b\\$ ls");
    t.drain();
    t.feed(b"\x1b[?1049h\x1b[1;1Haaa\r\nbbb");
    t.drain();
    t.remove_rows(0, 1);
    t.feed(b"\x1b[?1049l");
    t.drain();
    // The primary's rows never moved, so the mark must still name row 1.
    assert_eq!(t.clear_to_prompt(), 1);
    assert_eq!(text(&t, 0), "$ ls");
}

#[test]
fn leaving_the_alt_screen_restores_the_cursor_the_primary_saved() {
    // `save_restore' acts on whichever screen is showing, so the restore has to run
    // after the switch back. Run before it, it reads the alt screen's saved cursor
    // and leaves the primary's -- the one `1049h' saved -- untouched.
    // The saved position has to be one something later moves, or a restore that never
    // ran is indistinguishable from one that did. A rewrap is that something: it is
    // the one thing which relocates the primary's cursor while the alt screen is up.
    // So the line here is wrapped, and the resize below re-chunks it.
    let mut t = term(6, 4, b"aaaabb");
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (1, 2));
    t.feed(b"\x1b[?1049h");
    t.feed(b"\x1b[1;1Hframe");
    // Widening rejoins the two rows into one, putting the primary's cursor at (0, 6).
    t.resize(6, 8);
    t.feed(b"\x1b[?1049l");
    assert_eq!(
        (t.screen().cursor.row, t.screen().cursor.col),
        (1, 2),
        "the primary's saved cursor is the one 1049 restores"
    );
}

#[test]
fn clearing_to_the_prompt_leaves_the_alt_screen_alone() {
    let mut t = term(3, 8, b"aaa");
    t.feed(b"\x1b[?1049h\x1b[2;1Hbbb");
    t.drain();
    assert_eq!(t.clear_to_prompt(), 0);
    assert_eq!(text(&t, 1), "bbb");
}

#[test]
fn dec_graphics_draws_boxes() {
    let t = term(2, 8, b"\x1b(0lqk\x1b(B");
    assert_eq!(text(&t, 0), "┌─┐");
}

/// vttest's VT100 character-set screen, as a table: each set it names, designated into
/// G0 and invoked by SI, then into G1 and invoked by SO, drawing the same row of GL.
///
/// vttest is not installed here, so this stands in for its screen. The row it prints is
/// the one that tells the sets apart -- `#` is where UK differs, `` ` `` through `~` is
/// where graphics differ -- and each set has to come out the same from either slot, which
/// is exactly what a single graphics flag could not manage.
#[test]
fn every_designated_set_draws_the_same_from_g0_and_g1() {
    let probe = "#`jklmnqx~";
    let cases = [
        (b'B', "#`jklmnqx~"),
        (b'1', "#`jklmnqx~"),
        (b'A', "£`jklmnqx~"),
        (b'0', "#◆┘┐┌└┼─│·"),
        (b'2', "#◆┘┐┌└┼─│·"),
    ];
    for (set, drawn) in cases {
        for (slot, shift) in [(b'(', b'\x0f'), (b')', b'\x0e')] {
            let mut input = vec![0x1b, slot, set, shift];
            input.extend_from_slice(probe.as_bytes());
            let t = term(2, 20, &input);
            assert_eq!(
                text(&t, 0),
                drawn,
                "ESC {} {} then {}",
                slot as char,
                set as char,
                if shift == 0x0e { "SO" } else { "SI" }
            );
        }
    }
}

#[test]
fn shifts_choose_a_slot_and_designations_fill_one() {
    // Graphics in G1, ASCII in G0: SO and SI flip between them.
    let t = term(2, 10, b"\x1b)0q\x0eq\x0fq");
    assert_eq!(text(&t, 0), "q─q");
    // G1 powers on ASCII, so a bare SO draws letters, not boxes.
    let t = term(2, 10, b"\x0eq");
    assert_eq!(text(&t, 0), "q");
    // SI does not undo a G0 designation: the old flag cleared it here.
    let t = term(2, 10, b"\x1b(0\x0e\x0fq");
    assert_eq!(text(&t, 0), "─");
    // Redesignating the slot that is not in GL changes nothing on screen.
    let t = term(2, 10, b"\x1b(0\x1b)Bq");
    assert_eq!(text(&t, 0), "─");
}

#[test]
fn g2_and_g3_lock_and_single_shift() {
    // LS2 and LS3 lock; SI puts G0 back.
    let t = term(2, 10, b"\x1b*0\x1b+A\x1bnq\x1bo#\x0fq");
    assert_eq!(text(&t, 0), "─£q");
    // SS2 is spent on the next character only, whatever that character is.
    let t = term(2, 10, b"\x1b*0\x1bNqq");
    assert_eq!(text(&t, 0), "─q");
    let t = term(2, 10, "\x1b*0\x1bN\u{e9}q".as_bytes());
    assert_eq!(text(&t, 0), "\u{e9}q");
}

#[test]
fn charsets_are_reset_by_decstr_and_restored_by_decrc() {
    let t = term(2, 10, b"\x1b)0\x0e\x1b[!pq");
    assert_eq!(text(&t, 0), "q", "DECSTR puts G0 back in GL, holding ASCII");
    // DECSC saves the designation and the shift with the position.
    let t = term(2, 10, b"\x1b(0\x1b7\x1b(B\x1b)A\x0e\x1b8q");
    assert_eq!(text(&t, 0), "─");
    // And per screen: the primary's save is not the alternate screen's.
    let t = term(2, 10, b"\x1b(0\x1b[?1049h\x1b(B\x1b7\x1b[?1049lq");
    assert_eq!(text(&t, 0), "─", "1049 restores the primary's graphics set");
}

/// vttest's first screen draws its border onto DECALN's pattern, inside margins it has
/// set; the pattern has to fill every cell, reset those margins, home the cursor and
/// leave the pen out of it.
#[test]
fn decaln_fills_the_screen_with_e() {
    let mut t = term(4, 6, b"hi\r\nthere\x1b[3;4H\x1b[31;44m\x1b#8");
    for row in 0..4 {
        assert_eq!(text(&t, row), "EEEEEE");
        assert!(
            t.screen()
                .row(row)
                .unwrap()
                .cells()
                .iter()
                .all(|c| c.style == Style::default()),
            "row {row} is in the default rendition"
        );
    }
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (0, 0));
    let delta = t.drain();
    let scrolled: Vec<_> = delta.scrolled.iter().map(runs_text).collect();
    assert_eq!(
        scrolled.iter().map(|s| s.trim_end()).collect::<Vec<_>>(),
        ["hi", "there"],
        "the screen went to history, as a clear would send it"
    );
    // vttest's frame, drawn over it: the pattern stays wherever the frame is not.
    t.feed(b"\x1b[2;2H*\x1b[3;5H+");
    assert_eq!(text(&t, 1), "E*EEEE");
    assert_eq!(text(&t, 2), "EEEE+E");

    // Margins go back to the whole screen. The erase still happens under the margins the
    // child set, exactly as `CSI 2J` would, so a partitioned screen archives nothing.
    let mut t = term(4, 6, b"hi\x1b[2;3r\x1b#8");
    assert_eq!((t.screen().region.top, t.screen().region.bottom), (0, 3));
    assert!(t.drain().scrolled.is_empty());
}

#[test]
fn decst8c_puts_the_stops_back_every_eight_columns() {
    let mut t = term(2, 30, b"\x1b[3g\x1b[?5W\tx");
    assert_eq!(text(&t, 0), "        x");
    t.feed(b"\r\x1b[3g\x1b[4G\x1bH\r\x1b[?5W\t\ty");
    assert_eq!(
        text(&t, 0),
        "        x       y",
        "the stop set at column 4 is gone"
    );
    // `CSI 5 W` without the `?` is CTC, which is not this.
    let t = term(2, 30, b"\x1b[3g\x1b[5W\tx");
    assert_eq!(
        t.screen().cursor.col,
        29,
        "no stops: the tab ran to the margin"
    );
    assert_eq!(text(&t, 0).trim_start(), "x");
}

#[test]
fn scroll_region_then_linefeed_stays_off_scrollback() {
    let mut t = term(4, 8, b"a\r\nb\r\nc\r\nd");
    t.drain();
    t.feed(b"\x1b[2;3r\x1b[3;1H\n");
    assert!(t.drain().scrolled.is_empty());
}

#[test]
fn application_cursor_keys_are_tracked() {
    // ncurses sends this via smkx; without it, arrow keys reach the app in the
    // wrong encoding and simply do nothing.
    let mut t = term(4, 20, b"\x1b[?1h");
    assert!(t.app_cursor());
    assert!(t.drain().levels.app_cursor);

    t.feed(b"\x1b[?1l");
    assert!(!t.app_cursor());
    assert!(!t.drain().levels.app_cursor);
}

#[test]
fn modify_other_keys_is_negotiated() {
    let mut t = term(4, 20, b"");
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "nothing is on until the child asks"
    );

    t.feed(b"\x1b[>4;2m");
    let level2 = KeyEncoding::ModifyOtherKeys(ModifyOtherKeys::Level2);
    assert_eq!(t.keys(), level2);
    assert_eq!(t.drain().levels.keys, level2);

    // Level 1 is the protocol too, with fewer keys; the level says which, and a change
    // in the level alone is something to tell Lisp.
    assert!(t.feed(b"\x1b[>4;1m"), "a level change alone is an update");
    let level1 = KeyEncoding::ModifyOtherKeys(ModifyOtherKeys::Level1);
    assert_eq!(t.keys(), level1);
    assert_eq!(t.drain().levels.keys.modify_other_keys_level(), 1);

    // Level 3 also sends unmodified keys, which cooked does not, so it is not claimed.
    t.feed(b"\x1b[>4;3m");
    assert_eq!(t.keys(), KeyEncoding::Legacy);

    t.feed(b"\x1b[>4;2m\x1b[>4m");
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "a bare reset turns it back off"
    );
}

#[test]
fn kitty_wins_over_modify_other_keys_but_the_level_survives_it() {
    let mut t = term(4, 20, b"\x1b[>4;1m\x1b[>1u");
    assert_eq!(t.keys(), KeyEncoding::Kitty(KittyFlags::DISAMBIGUATE));
    t.feed(b"\x1b[<u");
    assert_eq!(
        t.keys(),
        KeyEncoding::ModifyOtherKeys(ModifyOtherKeys::Level1),
        "popping kitty uncovers level 1"
    );
}

#[test]
fn kitty_keyboard_flags_stack() {
    let mut t = term(4, 20, b"\x1b[>1u");
    assert_eq!(t.keys(), KeyEncoding::Kitty(KittyFlags::DISAMBIGUATE));

    t.feed(b"\x1b[>0u");
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "the pushed level is what counts"
    );

    t.feed(b"\x1b[<u");
    assert_eq!(
        t.keys(),
        KeyEncoding::Kitty(KittyFlags::DISAMBIGUATE),
        "popping restores what was underneath"
    );

    t.feed(b"\x1b[=0u");
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "set replaces the top of the stack"
    );
}

/// The spec keeps a stack per screen, so a full-screen program that pushes on the
/// alternate screen and dies without popping leaves nothing behind for the shell.
#[test]
fn each_screen_keeps_its_own_kitty_stack() {
    let mut t = term(4, 20, b"\x1b[>1u\x1b[?1049h");
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "the alternate screen starts from its own, empty stack"
    );

    t.feed(b"\x1b[>8u");
    assert_eq!(t.kitty_flags().bits(), 8);
    t.feed(b"\x1b[?1049l");
    assert_eq!(
        t.kitty_flags().bits(),
        1,
        "the push on the alternate screen is gone, the primary's is back"
    );

    t.feed(b"\x1b[<u");
    assert_eq!(t.kitty_flags().bits(), 0);
    t.feed(b"\x1b[?1049h");
    assert_eq!(
        t.kitty_flags().bits(),
        8,
        "a pop on the primary screen does not reach the alternate one"
    );

    t.feed(b"\x1bc");
    assert_eq!(t.kitty_flags().bits(), 0, "RIS empties both stacks");
    t.feed(b"\x1b[?1049l");
    assert_eq!(t.kitty_flags().bits(), 0);
}

/// A push onto a full stack evicts the oldest entry instead of being dropped, so every
/// pop still undoes its own push.
#[test]
fn a_push_onto_a_full_kitty_stack_evicts_the_oldest() {
    let mut t = term(4, 20, b"");
    for flags in 1..=17 {
        t.feed(format!("\x1b[>{flags}u").as_bytes());
    }
    assert_eq!(
        t.state.kitty_stack().top().bits(),
        17,
        "the 17th push is on top"
    );

    t.feed(b"\x1b[<15u");
    assert_eq!(
        t.state.kitty_stack().top().bits(),
        2,
        "the first push was evicted, so fifteen pops land on the second"
    );
    t.feed(b"\x1b[<u");
    assert!(
        t.state.kitty_stack().top().is_empty(),
        "one more pop empties it"
    );
    t.feed(b"\x1b[<5u");
    assert!(
        t.kitty_flags().is_empty(),
        "popping past the bottom is harmless"
    );
}

#[test]
fn a_kitty_query_is_answered_with_what_is_honoured() {
    // A child that probes and hears nothing back may sit there waiting -- but the
    // answer is a claim about this terminal, not an echo of the question.
    let reply = |input: &[u8]| {
        term(4, 20, input)
            .drain()
            .events
            .into_iter()
            .find_map(|e| match e {
                Event::Reply(r) => Some(r),
                _ => None,
            })
    };

    // Bits 1, 4, 8 and 16 are honoured and come back as asked.
    assert_eq!(reply(b"\x1b[>5u\x1b[?u"), Some(b"\x1b[?5u".to_vec()));
    assert_eq!(reply(b"\x1b[>29u\x1b[?u"), Some(b"\x1b[?29u".to_vec()));

    // Bit 2, report event types, is not: Emacs delivers no releases, and a child told
    // it would get them waits for events that never come. Told no, it falls back to a
    // spelling that works -- answering less than was asked is the recoverable failure.
    assert_eq!(reply(b"\x1b[>3u\x1b[?u"), Some(b"\x1b[?1u".to_vec()));
    assert_eq!(reply(b"\x1b[>31u\x1b[?u"), Some(b"\x1b[?29u".to_vec()));

    // The reply is exactly the constant's mask, so widening one widens the other.
    assert_eq!(
        reply(b"\x1b[>255u\x1b[?u"),
        Some(format!("\x1b[?{}u", KittyFlags::HONOURED).into_bytes())
    );

    // The stack still carries what the child asked for: a pop has to restore exactly
    // what its matching push put there, which is the child's business and not ours.
    assert_eq!(
        reply(b"\x1b[>7u\x1b[>1u\x1b[<1u\x1b[?u"),
        Some(b"\x1b[?5u".to_vec())
    );
}

/// The style and underline colour of the run on row 0 whose text is TEXT.
fn run_style(t: &Term, text: &str) -> (Style, Color) {
    let runs = t.screen().row(0).unwrap().runs();
    let run = runs.iter().find(|r| r.text == text).unwrap();
    (run.style, run.underline)
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

#[test]
fn xtsave_restores_a_private_mode() {
    let mut t = term(2, 8, b"\x1b[?1006h\x1b[?1006s\x1b[?1006l");
    assert!(!t.mouse().sgr());
    t.feed(b"\x1b[?1006r\x1b[?1006$p");
    assert!(t.mouse().sgr());
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?1006;1$y".to_vec()))
    );

    // And the other direction: saved off, turned on, restored off.
    let mut t = term(2, 8, b"\x1b[?2004s\x1b[?2004h\x1b[?2004r");
    assert!(!t.bracketed_paste());
    // The slot outlives a restore, as xterm's does.
    t.feed(b"\x1b[?2004h\x1b[?2004r");
    assert!(!t.bracketed_paste());
}

/// The case XTSAVE exists for: turn mouse reporting on, and put back exactly what was
/// there -- which, with the tracking modes overlapping, flag-by-flag replay gets wrong.
#[test]
fn xtsave_restores_mouse_tracking_as_one_choice() {
    let mut t = term(2, 8, b"\x1b[?1002h");
    t.drain();
    t.feed(b"\x1b[?1000;1002;1003;1006s\x1b[?1003;1006h\x1b[?1000;1002;1003;1006r");
    let mouse = t.mouse();
    assert!(mouse.click && mouse.drag && !mouse.motion && !mouse.sgr());
    assert!(
        t.drain().events.contains(&Event::Mouse(mouse)),
        "Lisp is told the restored tracking"
    );

    let mut t = term(
        2,
        8,
        b"\x1b[?1000;1002;1003s\x1b[?1003h\x1b[?1000;1002;1003r",
    );
    assert!(!t.mouse().enabled());
    t.drain();
    // A restore to the state already standing announces nothing.
    t.feed(b"\x1b[?1000;1002;1003r");
    assert!(
        !t.drain()
            .events
            .iter()
            .any(|e| matches!(e, Event::Mouse(_)))
    );
}

/// A restore that changes nothing does nothing -- DECOM's `h`/`l` homes the cursor, and
/// a restore is not a replay.
#[test]
fn xtrestore_of_an_unchanged_mode_does_not_move_the_cursor() {
    let t = term(4, 8, b"\x1b[?6s\x1b[3;3H\x1b[?6r");
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (2, 2));
}

/// `CSI ? s` and `CSI ? r` are not SCOSC and DECSTBM, which have no private byte.
#[test]
fn xtsave_is_not_save_cursor_and_xtrestore_is_not_decstbm() {
    let t = term(4, 8, b"\x1b[2;3H\x1b[?25s\x1b[4;4H\x1b[u");
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (3, 3));

    let t = term(4, 8, b"\x1b[2;3r\x1b[3;3H\x1b[?25r");
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (2, 2));
    assert_eq!((t.screen().region.top, t.screen().region.bottom), (1, 2));
}

/// Both stacks are negotiated state, and RIS is the child starting over.
#[test]
fn reset_clears_the_pen_stack_and_saved_modes() {
    let mut t = term(2, 8, b"\x1b[31m\x1b[#{\x1b[?1006h\x1b[?1006s\x1bc");
    t.feed(b"\x1b[32m\x1b[#}a\x1b[?1006r");
    assert_eq!(run_style(&t, "a").0.fg, Color::Indexed(2));
    assert!(!t.mouse().sgr(), "no slot survives to restore");

    let mut t = term(2, 8, b"\x1b[?1006s\x1b[?1006h");
    t.feed(b"\x1bc\x1b[?1006h\x1b[?1006r");
    assert!(t.mouse().sgr());
}

#[test]
fn kitty_flags_reach_the_drain() {
    // The encoder is Lisp's, so the flags have to cross with the drain -- and a change
    // of flags alone, with the encoding still kitty either side, is still a change.
    let mut t = term(4, 20, b"\x1b[>1u");
    assert_eq!(t.drain().levels.keys.kitty_flags().bits(), 1);
    assert!(t.feed(b"\x1b[=29u"), "a flag change alone is an update");
    let d = t.drain();
    assert_eq!(
        d.levels.keys,
        KeyEncoding::Kitty(KittyFlags::from_bits_retain(29))
    );
    // Masked on the way out, as the query reply is.
    t.feed(b"\x1b[=2;2u");
    assert_eq!(t.kitty_flags().bits(), 29);
}

#[test]
fn kitty_report_all_keys_turns_kitty_on_by_itself() {
    // Reporting every key as an escape code disambiguates by construction, so bit 8
    // needs no bit 1 beside it.
    assert_eq!(
        term(4, 20, b"\x1b[>8u").keys(),
        KeyEncoding::Kitty(KittyFlags::REPORT_ALL_KEYS)
    );
    // Alternate keys and associated text only add fields to an escape code something
    // else chose to send; alone, nothing is sent as one, and the spelling is legacy.
    assert_eq!(term(4, 20, b"\x1b[>4u").keys(), KeyEncoding::Legacy);
    assert_eq!(term(4, 20, b"\x1b[>16u").keys(), KeyEncoding::Legacy);
    assert_eq!(term(4, 20, b"\x1b[>20u").kitty_flags().bits(), 20);
}

#[test]
fn kitty_set_honours_its_mode() {
    // `CSI = FLAGS ; MODE u`: 1 replaces, 2 sets bits, 3 clears them.
    let mut t = term(4, 20, b"\x1b[>1u");
    t.feed(b"\x1b[=16;2u");
    assert_eq!(t.kitty_flags().bits(), 17, "mode 2 adds to what was there");
    t.feed(b"\x1b[=1;3u");
    assert_eq!(
        t.kitty_flags().bits(),
        16,
        "mode 3 takes away only what it names"
    );
    t.feed(b"\x1b[=4u");
    assert_eq!(t.kitty_flags().bits(), 4, "mode 1, the default, replaces");
    t.feed(b"\x1b[=9;1u");
    assert_eq!(t.kitty_flags().bits(), 9);
}

#[test]
fn reset_clears_negotiated_keyboard_modes() {
    let mut t = term(4, 20, b"\x1b[>4;2m\x1b[>1u");
    assert_eq!(t.keys(), KeyEncoding::Kitty(KittyFlags::DISAMBIGUATE));
    t.feed(b"\x1bc");
    assert_eq!(t.keys(), KeyEncoding::Legacy);
}

/// Queried, never announced: the state is read as a submission is framed, which is
/// later — and so more accurate — than any drain that preceded it.
#[test]
fn bracketed_paste_toggles() {
    let mut t = term(2, 8, b"\x1b[?2004h");
    assert!(t.bracketed_paste());
    assert!(t.drain().events.is_empty());
    t.feed(b"\x1b[?2004l");
    assert!(!t.bracketed_paste());
}

#[test]
fn trailing_text_finds_a_password_prompt() {
    let t = term(4, 30, b"Warming up\r\nPassword: ");
    assert_eq!(t.trailing_text().as_deref(), Some("Password:"));
}

#[test]
fn damage_covers_only_touched_rows() {
    let mut t = term(4, 8, b"a\r\nb");
    t.drain();
    t.feed(b"\x1b[1;1Hz");
    let rows = t.drain().rows;
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].index, 0);
}

#[test]
fn resize_preserves_the_tail() {
    let mut t = term(3, 10, b"one\r\ntwo\r\nthree");
    t.drain();
    t.resize(2, 10);
    let delta = t.drain();
    assert_eq!(delta.scrolled.len(), 1);
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
    assert_eq!(text(&t, 0), "two");
}

#[test]
fn box_drawing_bytes_produce_glyphs_in_the_drained_delta() {
    let mut t = term(2, 10, "\u{250C}\u{2500}\u{2500}\u{2510}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    assert_eq!(runs.len(), 1);
    let glyphs = runs[0].deco.as_ref().expect("box-glyph run").glyphs();
    assert_eq!(glyphs.len(), 4, "one descriptor per character");
    assert_eq!(runs[0].text, "\u{250C}\u{2500}\u{2500}\u{2510}");
}

#[test]
fn diagonal_and_stub_bytes_also_produce_glyphs() {
    let mut t = term(2, 10, "\u{2571}\u{2572}\u{2573}\u{2574}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    assert_eq!(runs.len(), 1);
    let glyphs = runs[0].deco.as_ref().expect("box-glyph run").glyphs();
    assert_eq!(glyphs.len(), 4);
    assert!(glyphs[0].is_diagonal());
    assert!(
        !glyphs[3].is_diagonal(),
        "the stub is edge-based, not a diagonal"
    );
}

/// The wire format's whole reason to exist: a border row is one decision repeated, and
/// saying so once is what lets `cooked--apply-glyph-deco' look the image spec up once
/// and hang one shared record over the run instead of doing both per character.
#[test]
fn a_run_of_identical_glyphs_packs_into_a_single_run_length_record() {
    let mut t = term(2, 10, "\u{2500}\u{2500}\u{2500}\u{2500}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    let packed = runs[0].deco.as_ref().expect("box-glyph run").packed();
    assert_eq!(
        packed.len(),
        4,
        "four identical shapes, one record: {packed:?}"
    );
    // U+2500 ─ is a light horizontal: left and right edges at weight 1, 0x0050.
    assert_eq!(packed, vec![0x50, 0x00, 4, 0], "{packed:?}");
}

/// The other half of the same claim: only *adjacent equal* shapes collapse, so a run
/// whose shapes differ still arrives with every character accounted for. A corner, a
/// stretch of horizontal and the other corner is what a real border row looks like.
#[test]
fn a_run_of_differing_glyphs_packs_one_record_per_distinct_shape() {
    let mut t = term(2, 10, "\u{250C}\u{2500}\u{2500}\u{2510}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    let deco = runs[0].deco.as_ref().expect("box-glyph run");
    let packed = deco.packed();
    assert_eq!(packed.len(), 12, "three records: {packed:?}");
    let counts: Vec<u16> = packed
        .chunks_exact(4)
        .map(|record| u16::from_le_bytes([record[2], record[3]]))
        .collect();
    assert_eq!(counts, vec![1, 2, 1]);
    assert_eq!(
        counts.iter().sum::<u16>() as usize,
        deco.glyphs().len(),
        "the counts must cover every character of the run"
    );
    // The middle record is the pair of horizontals, and it carries their bits.
    assert_eq!(
        u16::from_le_bytes([packed[4], packed[5]]),
        deco.glyphs()[1].bits()
    );
}

/// A shade dithers, so its phase depends on the column it lands in and Lisp has to
/// rebuild the `display' value per cell however the wire arrived. That is deliberately
/// *not* said in the record: the shapes are identical, so they collapse like any other
/// repeat, and `cooked--box-shade-p' asks once per record rather than once per cell.
/// Adding a flag bit would have saved one `logand' per run — see [`Deco::packed`].
#[test]
fn a_run_of_shades_collapses_like_any_other_repeat_and_is_not_flagged() {
    let mut t = term(2, 10, "\u{2592}\u{2592}\u{2592}".as_bytes());
    let delta = t.drain();
    let runs = &delta
        .rows
        .iter()
        .find(|r| r.index == 0)
        .expect("row 0 is damaged")
        .runs;
    let deco = runs[0].deco.as_ref().expect("box-glyph run");
    let packed = deco.packed();
    // ▒ U+2592, medium shade: block kind, direction `Shade', density 2 -- 0x8015, the
    // same literal `cooked-box-glyph-bits-match-the-rust-side-encoding' mirrors.
    assert_eq!(packed, vec![0x15, 0x80, 3, 0], "{packed:?}");
    // Nothing in the count field but the count: no bit is reserved to say "dithers".
    assert_eq!(u16::from_le_bytes([packed[2], packed[3]]), 3);
}

/// Image cells keep one record each, and this is the pin on that staying true: every
/// cell of a picture displays its own slice, named by the row and column *in that
/// record*, so a run-length record would hand three cells one start column and draw the
/// same slice three times. See `cooked--apply-image-deco'.
#[test]
fn image_placements_still_pack_one_record_per_character() {
    let mut t = with_metrics(10, 20);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(30, 20));
    let runs = t.screen().row(0).unwrap().runs();
    let deco = runs[0]
        .deco
        .as_ref()
        .expect("an image placement decorates row 0");
    let packed = deco.packed();
    assert_eq!(deco.len(), 3);
    assert_eq!(packed.len(), 12 * 3, "one record per cell: {packed:?}");
    // Every cell names its own column within the picture, which is exactly what a
    // record shared across the run could not do.
    let columns: Vec<u16> = packed
        .chunks_exact(12)
        .map(|record| u16::from_le_bytes([record[6], record[7]]))
        .collect();
    assert_eq!(columns, vec![0, 1, 2]);
}

/// The alt screen produces no history of its own, but the primary's rows are still
/// history — a resize while a full-screen program is up must not discard them.
#[test]
fn resize_on_the_alt_screen_still_archives_primary_rows() {
    let mut t = term(3, 10, b"one\r\ntwo\r\nthree");
    t.feed(b"\x1b[?1049h");
    t.drain();

    t.resize(2, 10);
    let delta = t.drain();

    assert_eq!(delta.scrolled.len(), 1, "primary history lost during alt");
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
}

/// `clear` and the shell's `C-l` both end up here, and the screen they wipe is
/// transcript Emacs is holding — the grid does not get to drop it on their behalf.
#[test]
fn clearing_the_display_keeps_the_screen_as_history() {
    let mut t = term(4, 10, b"one\r\ntwo");
    t.drain();

    t.feed(b"\x1b[2J");
    let delta = t.drain();

    assert_eq!(delta.scrolled.len(), 2);
    assert_eq!(runs_text(&delta.scrolled[0]), "one");
    assert_eq!(runs_text(&delta.scrolled[1]), "two");
    assert_eq!(text(&t, 0), "");
}

#[test]
fn clearing_the_alt_screen_archives_nothing() {
    let mut t = term(4, 10, b"\x1b[?1049hframe");
    t.drain();

    t.feed(b"\x1b[2J");

    assert!(
        t.drain().scrolled.is_empty(),
        "the alt screen has no history to keep"
    );
}

#[test]
fn a_partial_erase_is_not_a_finished_screen() {
    let mut t = term(4, 10, b"one\r\ntwo");
    t.drain();

    t.feed(b"\x1b[J");

    assert!(
        t.drain().scrolled.is_empty(),
        "a partial erase is a redraw, not a screen being finished with"
    );
}

/// The primary is rewrapped even while a full-screen program is up, because its rows
/// are the transcript that program will hand back on exit.
#[test]
fn narrowing_mid_alt_rewraps_the_primary_underneath() {
    let mut t = term(4, 10, b"abcdefghijklmno");
    t.feed(b"\x1b[?1049h");
    t.drain();

    t.resize(4, 5);
    t.feed(b"\x1b[?1049l");
    let delta = t.drain();

    assert!(delta.scrolled.is_empty());
    assert_eq!(text(&t, 0), "abcde");
    assert_eq!(text(&t, 1), "fghij");
    assert_eq!(text(&t, 2), "klmno");
}

#[test]
fn backlog_counts_pending_events_as_well_as_scrollback() {
    let mut t = term(4, 10, b"");
    assert_eq!(t.backlog(), 0);

    t.feed(b"\x1b]0;a\x07\x1b]0;b\x07\x1b]0;c\x07");
    assert_eq!(
        t.backlog(),
        3,
        "OSC-only output scrolls nothing, so a scrollback-only measure misses it"
    );

    t.drain();
    assert_eq!(t.backlog(), 0, "draining clears the measure");
}

/// The batched print path must be indistinguishable from the per-character one.
///
/// The reference side sets `force_per_character_print`, which is the only way to make a
/// `Term` take the old path. Feeding a byte at a time does *not* do it -- `print_str`
/// still runs, with runs of length one -- so a test built that way compares the fast path
/// against itself; the first version of this test did exactly that and survived
/// deliberately breaking `write_run` twice.
///
/// The cases land on the seams: the last column, where `write_run` stops one short so the
/// deferred wrap is decided in one place; wide characters and combining marks, which it
/// declines; DEL, which is not a C0 control and so reaches `print_str` while having no
/// width; insert mode and a designated set or single shift, which disable it; and a scroll, so eviction is
/// compared too.
#[test]
fn batched_and_per_character_printing_agree() {
    let cases: &[(&str, &[u8])] = &[
        ("plain text", b"hello world"),
        ("exactly one row", b"0123456789"),
        ("one past the row", b"0123456789x"),
        ("two rows and a bit", b"0123456789abcdefghijQR"),
        ("wrap then newline", b"0123456789abc\r\ndef"),
        ("wide characters", "ab\u{6f22}\u{5b57}cd".as_bytes()),
        (
            "wide character across the margin",
            "012345678\u{6f22}z".as_bytes(),
        ),
        ("combining mark", "abe\u{301}f".as_bytes()),
        ("DEL is not a control", b"ab\x7fcd"),
        ("styled runs", b"a\x1b[31mred\x1b[0mb"),
        ("insert mode", b"abcdef\x1b[4D\x1b[4hXY"),
        ("dec graphics", b"\x1b(0qqq\x1b(Babc"),
        ("graphics shifted out of G1", b"a\x1b)0\x0eqqq\x0fqqq"),
        ("single shift spent on a run", b"\x1b*0\x1bNqqq"),
        (
            "hyperlink attaches per cell",
            b"a\x1b]8;;http://x\x07bcd\x1b]8;;\x07e",
        ),
        ("tabs and returns", b"ab\tcd\rZ"),
        (
            "scrolls off the top",
            b"aaa\r\nbbb\r\nccc\r\nddd\r\neee\r\nfff",
        ),
        ("REP after a run", b"abc\x1b[4b"),
        ("erase then refill", b"0123456789\x1b[H\x1b[2Jxy"),
    ];

    // The text on the grid, the runs it reduces to (which carry style, so a pen dropped
    // mid-run would show), the cursor, and what left for scrollback.
    /// Everything the two printing paths could disagree about.
    type Snapshot = (Vec<String>, Vec<Vec<Run>>, (usize, usize), Vec<String>);

    fn rendered(t: &mut Term) -> Snapshot {
        let scrolled = t
            .drain()
            .scrolled
            .iter()
            .map(|line| line.runs.iter().map(|r| r.text.as_str()).collect())
            .collect();
        let screen = (0..4)
            .map(|i| t.screen().row(i).map(Row::to_text).unwrap_or_default())
            .collect();
        let runs = (0..4)
            .map(|i| t.screen().row(i).map(Row::runs).unwrap_or_default())
            .collect();
        let cursor = (t.screen().cursor.row, t.screen().cursor.col);
        (screen, runs, cursor, scrolled)
    }

    for (name, input) in cases {
        let mut batched = Term::new(4, 10);
        batched.feed(input);

        let mut reference = Term::new(4, 10);
        reference.force_per_character_print();
        reference.feed(input);

        assert_eq!(
            rendered(&mut batched),
            rendered(&mut reference),
            "batched and per-character printing disagree on {name}"
        );
    }
}

/// A picture the child sizes in pixels rather than in cells is measured into a cell
/// rectangle at every transmission, against the cell as it is at that moment. So a font
/// change needs no repair: the next frame the child draws is laid at the rectangle the
/// new cell implies, while the bytes -- which have not changed -- do not cross again.
///
/// This is the flip a gif used to show after a zoom. The measurement was taken once and
/// kept against the id; ids are content-addressed, so frames Emacs still held were
/// recognised and re-laid at the *old* rectangle while frames it had evicted were
/// retransmitted and measured against the new one, and the two populations interleaved
/// for as long as the animation looped. The store was dropped whole on a cell change to
/// collapse them, at the cost of retransmitting every picture in the session.
#[test]
fn a_replayed_picture_is_measured_against_the_cell_it_is_replayed_at() {
    let mut t = with_metrics(10, 20);
    // 20x40 pixels: two cells by two at a 10x20 cell, one by one once the cell doubles.
    let pixels = vec![0u8; 20 * 40 * 3];
    let apc = format!("\x1b_Ga=T,f=24,s=20,v=40,i=1;{}\x1b\\", b64(&pixels));
    t.feed(apc.as_bytes());
    let first = t.drain().images;
    assert_eq!(first.len(), 1);
    assert_eq!(placements(&t, 0)[0].cols, 2);
    assert_eq!(placements(&t, 0)[0].rows, 2);
    let first_id = first[0].id;

    // The font doubles. Rows and columns arrive by the same route and are unchanged.
    t.set_cell_metrics(CellMetrics {
        width: 20,
        height: 40,
    });
    t.feed(b"\x1b[H");
    t.feed(apc.as_bytes());
    let again = t.drain();
    assert!(
        again.images.is_empty(),
        "the same bytes are the same picture, whatever the font: {:?}",
        again.images
    );

    // ...and the grid says the new rectangle, under the id it already had.
    let placed = placements(&t, 0);
    assert_eq!(placed[0].id, first_id, "no retransmission, so no new id");
    assert_eq!(
        (placed[0].cols, placed[0].rows),
        (1, 1),
        "measured against the cell it was replayed at"
    );
    // The old picture was two cells wide and the new one is one, so the cell beside it
    // still holds the placement the larger picture put there. That is the case the
    // rectangle moved onto the placement for: both are on the grid, both name the one
    // content-addressed id, and each carries the size it was laid at, so Emacs cuts the
    // right slice for each. A rectangle held against the *image* is a single field
    // answering for both, and the older cells are drawn at the newer one's size.
    assert_eq!(
        (placed[1].cols, placed[1].rows),
        (2, 2),
        "the leftover cell keeps the rectangle it was laid at: {placed:?}"
    );
    assert_eq!(placed[1].id, first_id, "and it is the same picture");
}

/// The other half of the guard above: a resize that leaves the font alone reports the
/// same cell size, and must not spend a retransmission per picture to do it.
#[test]
fn a_reshape_that_does_not_move_the_cell_keeps_every_picture() {
    let mut t = with_metrics(10, 20);
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(20, 40));
    let first = t.drain().images[0].id;

    t.resize(20, 40);
    t.set_cell_metrics(CellMetrics {
        width: 10,
        height: 20,
    });
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(20, 40));
    let delta = t.drain();
    assert!(
        delta.images.is_empty(),
        "still recognised: {:?}",
        delta.images
    );
    assert_eq!(placements(&t, 2)[0].id, first);
}

/// A client's own name for a picture survives a cell change, and the picture it names is
/// laid at the rectangle the *new* cell implies.
///
/// Both halves used to go: the store was dropped whole when the font moved, so this
/// `a=p` was answered `ENOENT:image` and the child -- which has no way to know the font
/// changed, and every reason to think a picture it transmitted is still there -- lost it.
/// The measurement is redone per placement now (see [`ImageStore::cells`]), so there is
/// nothing stale to protect anyone from and the name can be kept.
#[test]
fn a_client_name_survives_a_cell_change_and_is_replaced_at_the_new_size() {
    let mut t = with_metrics(10, 20);
    // 10x20 pixels: exactly one cell at a 10x20 cell, and a quarter of one once the
    // cell doubles -- which still rounds up to one, so the *rectangle* is the thing to
    // watch rather than the count.
    let pixels = vec![0u8; 40 * 60 * 3];
    t.feed(format!("\x1b_Ga=t,f=24,s=40,v=60,i=7;{}\x1b\\", b64(&pixels)).as_bytes());
    t.drain();

    t.set_cell_metrics(CellMetrics {
        width: 20,
        height: 40,
    });
    t.feed(b"\x1b_Ga=p,i=7\x1b\\");
    let delta = t.drain();
    let replies: Vec<_> = delta
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect();
    assert_eq!(
        replies,
        vec!["\x1b_Gi=7;OK\x1b\\"],
        "the name still resolves, where it used to be ENOENT:image"
    );

    // 40x60 against a 20x40 cell is two cells by two, where it was four by three.
    let placed = placements(&t, 0);
    assert!(!placed.is_empty(), "the picture is placed, not refused");
    assert_eq!(
        (placed[0].cols, placed[0].rows),
        (2, 2),
        "measured against the cell it was placed at, not the one it arrived at"
    );
}

/// The reader thread wakes Emacs on what [`Term::feed`] reports, so a read that changed
/// nothing must say so -- and a cursor move with no damage must not, which is the half
/// that is easy to get wrong and the half the flicker was made of.
#[test]
fn a_read_that_changes_nothing_reports_nothing() {
    let mut t = Term::new(4, 20);
    assert!(t.feed(b"hi"), "printed text is a change");
    t.drain();

    assert!(t.feed(b"\x1b[2;3H"), "a cursor move is a change on its own");
    t.drain();

    // A pen change: real, and invisible until something is printed with it.
    assert!(!t.feed(b"\x1b[1;31m"));
    // The middle of a kitty transfer, which is where a gif player spends nearly all of
    // its bytes: an APC string that will not touch the grid until its terminator.
    assert!(!t.feed(b"\x1b_Ga=T,f=100,i=1;iVBORw0KGgoAAAANSUhEU"));
    assert!(!t.feed(b"gAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR4"));

    let delta = t.drain();
    assert!(delta.rows.is_empty(), "nothing was drawn on");
    assert!(delta.events.is_empty() && delta.images.is_empty());
    assert!(delta.scrolled.is_empty() && delta.marks.is_empty());
}

/// `viu`'s window reshape, which is what sent us looking. It never rescales the pixels:
/// every frame goes out at full resolution and the *terminal* is asked to fit it, so a
/// reshape changes `c=`/`r=` and nothing else. Ids are content-addressed, so once the
/// animation loops every frame is bytes the module already knows -- 270 transmissions of
/// 61 distinct payloads, measured -- and none of them crosses the boundary again.
///
/// So the new rectangle can only reach Emacs on the placement. Held against the image it
/// reached nothing at all: the module laid the smaller rectangle while Emacs went on
/// building the spec at the size it had been told once, and the animation drew at its
/// original size, cropped, for the rest of the session.
#[test]
fn a_reshape_relays_a_known_picture_at_the_new_rectangle() {
    let mut t = with_metrics(24, 80);
    let pixels = vec![7u8; 20 * 40 * 3];
    let frame = |cols: u16, rows: u16| {
        format!(
            "\x1b_Ga=T,f=24,s=20,v=40,c={cols},r={rows};{}\x1b\\",
            b64(&pixels)
        )
    };

    t.feed(b"\x1b[H");
    t.feed(frame(61, 23).as_bytes());
    let first = t.drain().images;
    assert_eq!(first.len(), 1, "the payload crosses once");
    let id = first[0].id;
    assert_eq!(
        (placements(&t, 0)[0].cols, placements(&t, 0)[0].rows),
        (61, 23)
    );

    // The window narrows. Same bytes, new `c=`/`r=`, and the cell has not moved.
    t.resize(24, 40);
    t.feed(b"\x1b[H");
    t.feed(frame(40, 15).as_bytes());
    let again = t.drain();
    assert!(
        again.images.is_empty(),
        "the same bytes are the same picture: {:?}",
        again.images
    );

    let placed = placements(&t, 0);
    assert_eq!(placed[0].id, id, "and it is still that picture");
    assert_eq!(
        (placed[0].cols, placed[0].rows),
        (40, 15),
        "the placement carries the rectangle it was laid at, so Emacs can size the spec"
    );
}

/// A frame drawn over before Emacs ever drained is a frame nobody could have seen, and
/// its bytes do not cross. This is the whole of the pacing story: no timer and no
/// configured rate, just the observation that a transmission is not a placement.
#[test]
fn a_frame_overdrawn_before_the_drain_does_not_cross() {
    let mut t = with_metrics(24, 80);
    let frame = |n: u8| {
        let pixels = vec![n; 20 * 40 * 3];
        format!("\x1b_Ga=T,f=24,s=20,v=40,c=2,r=2;{}\x1b\\", b64(&pixels))
    };

    // Three frames between drains, each drawn over the last from the same corner.
    for n in 0..3 {
        t.feed(b"\x1b[H");
        t.feed(frame(n).as_bytes());
    }
    let delta = t.drain();
    assert_eq!(
        delta.images.len(),
        1,
        "only the frame still on the grid crosses: {:?}",
        delta.images.iter().map(|i| i.id).collect::<Vec<_>>()
    );
    assert_eq!(delta.images[0].id, placements(&t, 0)[0].id);
}

/// Shedding a frame has to tell the store, or it re-creates the fault it was written to
/// avoid. The store's invariant is that an id is tracked iff Emacs holds its bytes; a
/// shed frame left tracked would be answered "you already have this one" the next time
/// round the loop, and the placement would name a picture Emacs was never given.
#[test]
fn a_shed_frame_crosses_again_when_it_is_next_drawn() {
    let mut t = with_metrics(24, 80);
    let pixels = vec![9u8; 20 * 40 * 3];
    let frame = format!("\x1b_Ga=T,f=24,s=20,v=40,c=2,r=2;{}\x1b\\", b64(&pixels));
    let other = {
        let bytes = vec![1u8; 20 * 40 * 3];
        format!("\x1b_Ga=T,f=24,s=20,v=40,c=2,r=2;{}\x1b\\", b64(&bytes))
    };

    // The frame under test is drawn over by another before the drain, so it is shed.
    t.feed(b"\x1b[H");
    t.feed(frame.as_bytes());
    t.feed(b"\x1b[H");
    t.feed(other.as_bytes());
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1, "the overdrawn frame was shed");

    // The loop comes round. Those bytes must arrive as a picture Emacs has not got.
    t.feed(b"\x1b[H");
    t.feed(frame.as_bytes());
    let again = t.drain();
    assert_eq!(
        again.images.len(),
        1,
        "a shed frame is not still claimed: {:?}",
        again.images
    );
    assert_eq!(again.images[0].id, placements(&t, 0)[0].id);
}

/// The exception to shedding: a picture bound to an `i=` can be placed later by a bare
/// `a=p`, which carries no bytes of its own, so the transmission that bound it is the
/// only chance those bytes have to reach Emacs. `a=t` transmits without placing, so
/// nothing on the grid vouches for it and the grid scan alone would shed every one.
#[test]
fn a_transmission_the_client_can_still_name_is_not_shed() {
    let mut t = with_metrics(24, 80);
    let pixels = vec![3u8; 10 * 20 * 3];
    t.feed(format!("\x1b_Ga=t,f=24,s=10,v=20,i=7;{}\x1b\\", b64(&pixels)).as_bytes());
    let delta = t.drain();
    assert_eq!(
        delta.images.len(),
        1,
        "transmitted but not placed, and still owed to Emacs"
    );

    // ...which is what makes the later placement drawable.
    t.feed(b"\x1b_Ga=p,i=7\x1b\\");
    t.drain();
    assert_eq!(placements(&t, 0)[0].id, delta.images[0].id);
}

/// A picture is one item and several megabytes, so the backlog has to weigh it rather
/// than count it. Counted, a child could hold a gigabyte of undrained frames without
/// reaching a limit written for rows -- and did: `viu` scrolls nothing and raises no
/// events, so its backlog was flatly zero however far behind Emacs got.
#[test]
fn a_pending_picture_weighs_on_the_backlog() {
    let mut t = with_metrics(24, 80);
    assert_eq!(t.backlog(), 0);

    // 100x100 RGB is 30_000 bytes, which is 29 whole units of 1KB.
    let pixels = vec![4u8; 100 * 100 * 3];
    t.feed(format!("\x1b_Ga=T,f=24,s=100,v=100,c=2,r=2;{}\x1b\\", b64(&pixels)).as_bytes());
    assert_eq!(
        t.backlog(),
        pixels.len() / IMAGE_BACKLOG_UNIT,
        "the payload is weighed, not counted as one item"
    );

    // And it is the drain that clears it, which is what stops backpressure deadlocking:
    // the queue empties on Emacs' say-so and needs nothing from the child.
    t.drain();
    assert_eq!(t.backlog(), 0);
}

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
    let replies: Vec<_> = t
        .drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect();
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
    assert_eq!(t.screen().cursor.col, 2);
}

#[test]
fn a_declared_width_lays_down_continuation_cells_like_any_wide_character() {
    let t = term(2, 20, b"\x1b]66;w=3;x\x07y");
    assert_eq!(t.screen().cursor.col, 4);
    let cells = t.screen().row(0).unwrap().cells();
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
    assert_eq!(t.screen().cursor.col, 0);
}

#[test]
fn a_block_that_does_not_fit_the_line_wraps_whole_under_decawm() {
    let t = term(3, 6, b"abcde\x1b]66;w=2;x\x07");
    assert_eq!(text(&t, 0), "abcde", "the block did not straddle the edge");
    assert_eq!(text(&t, 1), "x");
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (1, 2));
}

#[test]
fn with_wrapping_off_a_block_backs_up_far_enough_to_land_whole() {
    // DECAWM off: the cursor never leaves the row, so the block is moved back to the
    // last position where all of it fits and overwrites what was there.
    let t = term(3, 6, b"\x1b[?7labcde\x1b]66;w=2;x\x07");
    assert_eq!(text(&t, 0), "abcdx");
    assert_eq!((t.screen().cursor.row, t.screen().cursor.col), (0, 5));
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
    assert_eq!(t.screen().cursor.col, 1);
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
    assert_eq!(t.screen().cursor.col, 2);
}

#[test]
fn the_keys_this_declines_are_parsed_and_then_ignored() {
    // Fractional scale and alignment change nothing about how many cells the text takes,
    // by the spec's own definition, so accepting and dropping them is not a divergence.
    let t = term(2, 20, b"\x1b]66;n=1:d=2:v=2:h=1:w=1;ab\x07");
    assert_eq!(t.screen().cursor.col, 1);
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
    assert_eq!(t.screen().cursor.col, 4);
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
    assert_eq!(t.screen().cursor.col, 3);
    let cells = t.screen().row(0).unwrap().cells();
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
                t.screen().cursor.col,
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
        assert_eq!(t.screen().cursor.col, 3, "after {setup:?}");
    }
}

#[test]
fn a_variation_selector_resizes_the_cell_it_lands_on() {
    // U+2714 is one column bare. VS16 promotes it to emoji presentation, which is two —
    // retroactively, since the cell was written a code point ago.
    let bare = term(2, 20, "\u{2714}|".as_bytes());
    assert_eq!(bare.screen().cursor.col, 2);
    let wide = term(2, 20, "\u{2714}\u{FE0F}|".as_bytes());
    assert_eq!(wide.screen().cursor.col, 3);
    let cells = wide.screen().row(0).unwrap().cells();
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
    assert_eq!(t.screen().cursor.col, 3);
}

#[test]
fn a_mark_after_a_declared_block_joins_the_block() {
    // The block was declared three cells wide, so the cell it occupies starts three
    // columns back — not one, and not wherever a width table would put it.
    let t = term(2, 20, "\x1b]66;w=3;x\x07\u{301}".as_bytes());
    assert_eq!(t.screen().cursor.col, 3);
    let runs = t.screen().row(0).unwrap().runs();
    assert_eq!(runs[0].text, "x\u{301}");
    assert_eq!(runs[0].cols, 3);
}

/// The DCS replies in T's pending events, drained, as strings.
fn dcs_replies(t: &mut Term) -> Vec<String> {
    t.drain()
        .events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) if bytes.starts_with(b"\x1bP") => {
                Some(String::from_utf8(bytes).unwrap())
            }
            _ => None,
        })
        .collect()
}

/// Ask T about NAME and return the single answer.
fn decrqss(t: &mut Term, name: &str) -> String {
    dcs_replies(t); // Whatever was pending belongs to someone else.
    t.feed(format!("\x1bP$q{name}\x1b\\").as_bytes());
    let mut replies = dcs_replies(t);
    assert_eq!(replies.len(), 1, "{name:?}: {replies:?}");
    replies.remove(0)
}

/// Set with SET, ask about NAME, and play the answer back into a fresh terminal: the
/// reply is only a description of the setting if it recreates it. Returns the sequence
/// the reply carried, for the caller to hold to a spelling.
fn decrqss_round_trip(rows: usize, cols: usize, set: &[u8], name: &str) -> String {
    let mut first = term(rows, cols, set);
    let reply = decrqss(&mut first, name);
    let body = reply
        .strip_prefix("\x1bP1$r")
        .and_then(|r| r.strip_suffix("\x1b\\"))
        .unwrap_or_else(|| panic!("{name:?} was refused: {reply:?}"));
    // Played back as the CSI it names, into a terminal that has seen nothing else.
    let mut second = term(rows, cols, format!("\x1b[{body}").as_bytes());
    assert_eq!(
        decrqss(&mut second, name),
        reply,
        "{set:?} did not survive replay"
    );
    assert_eq!(second.state.pen, first.state.pen, "{set:?}");
    assert_eq!(second.state.underline, first.state.underline, "{set:?}");
    assert_eq!(second.state.modes, first.state.modes, "{set:?}");
    assert_eq!(
        second.screen().region.top,
        first.screen().region.top,
        "{set:?}"
    );
    assert_eq!(
        second.screen().region.bottom,
        first.screen().region.bottom,
        "{set:?}"
    );
    body.to_owned()
}

#[test]
fn decrqss_answers_the_pen_as_the_sgr_that_recreates_it() {
    for (set, want) in [
        (&b""[..], "0m"),
        (b"\x1b[1;3m", "0;1;3m"),
        (b"\x1b[1;2;5;7;8;9m", "0;1;2;5;7;8;9m"),
        (b"\x1b[53;3m", "0;3;53m"),
        // Underline styles keep their colon form; single is plain `4`.
        (b"\x1b[4m", "0;4m"),
        (b"\x1b[4:3m", "0;4:3m"),
        (b"\x1b[4:5m", "0;4:5m"),
        // The palette answers in its shortest spelling, whichever one set it.
        (b"\x1b[31;42m", "0;31;42m"),
        (b"\x1b[38;5;1;48:5:9m", "0;31;101m"),
        (b"\x1b[97;100m", "0;97;100m"),
        (b"\x1b[38;5;200m", "0;38:5:200m"),
        // Direct colour, from either spelling, in the one colon form.
        (b"\x1b[38;2;10;20;30m", "0;38:2::10:20:30m"),
        (b"\x1b[48:2::1:2:3m", "0;48:2::1:2:3m"),
        (b"\x1b[48:2:1:2:3m", "0;48:2::1:2:3m"),
        // The underline colour has no short form to fall back on.
        (b"\x1b[4:3;58:5:3m", "0;4:3;58:5:3m"),
        (b"\x1b[58:2::255:0:0m", "0;58:2::255:0:0m"),
        // Everything at once, in the order the reply writes it.
        (
            b"\x1b[48;5;17;1;4:2;38:2::1:2:3;9;58;5;196m",
            "0;1;4:2;9;38:2::1:2:3;48:5:17;58:5:196m",
        ),
        // And what `SGR 0` and the off codes leave: nothing.
        (b"\x1b[1;4;31;58:5:3m\x1b[22;24;39;59m", "0m"),
    ] {
        assert_eq!(decrqss_round_trip(2, 8, set, "m"), want, "{set:?}");
    }
}

#[test]
fn decrqss_passes_neovims_truecolour_probe() {
    // Byte for byte what neovim sends when XTGETTCAP has not told it about `RGB`, and
    // the reply its pattern `^\eP1%$r([%d;:]+)m$` then accepts: a leading `0` and then
    // `48:2:` followed by an empty colour space and the three components.
    let mut t = Term::new(2, 8);
    t.feed(b"\x1b[0m\x1b[48;2;1;2;3m\x1bP$qm\x1b\\");
    assert_eq!(dcs_replies(&mut t), vec!["\x1bP1$r0;48:2::1:2:3m\x1b\\"]);
}

#[test]
fn decrqss_answers_the_scroll_region_one_based() {
    assert_eq!(decrqss_round_trip(24, 8, b"", "r"), "1;24r");
    assert_eq!(decrqss_round_trip(24, 8, b"\x1b[5;20r", "r"), "5;20r");
    // A bottom past the screen is clamped when set, so the answer is the clamp.
    assert_eq!(decrqss_round_trip(24, 8, b"\x1b[3;99r", "r"), "3;24r");
    // Each screen has its own region, and the question is about the one in use.
    let mut t = term(24, 8, b"\x1b[5;20r\x1b[?1049h\x1b[2;10r");
    assert_eq!(decrqss(&mut t, "r"), "\x1bP1$r2;10r\x1b\\");
    t.feed(b"\x1b[?1049l");
    assert_eq!(decrqss(&mut t, "r"), "\x1bP1$r5;20r\x1b\\");
}

#[test]
fn decrqss_answers_the_cursor_style_the_child_set() {
    // Blink is never rendered, but it is the child's setting and comes back as set.
    for (set, want) in [
        (&b""[..], "1 q"),
        (b"\x1b[0 q", "1 q"),
        (b"\x1b[1 q", "1 q"),
        (b"\x1b[2 q", "2 q"),
        (b"\x1b[3 q", "3 q"),
        (b"\x1b[4 q", "4 q"),
        (b"\x1b[5 q", "5 q"),
        (b"\x1b[6 q", "6 q"),
        // An unknown style changes nothing, blink included.
        (b"\x1b[4 q\x1b[9 q", "4 q"),
        // A soft reset puts both halves back.
        (b"\x1b[6 q\x1b[!p", "1 q"),
    ] {
        assert_eq!(decrqss_round_trip(2, 8, set, " q"), want, "{set:?}");
    }
}

#[test]
fn decrqss_answers_the_conformance_level_da1_claims() {
    // Not round-tripped: cooked does not act on DECSCL, so there is no setting for the
    // replay to recreate -- only the claim, which must agree with the primary DA.
    let mut t = Term::new(2, 8);
    assert_eq!(decrqss(&mut t, "\"p"), "\x1bP1$r62;1\"p\x1b\\");
    t.feed(b"\x1b[c");
    let da1 = t.drain().events;
    assert!(da1.contains(&Event::Reply(b"\x1b[?62;4;22c".to_vec())));
}

#[test]
fn decrqss_refuses_what_it_does_not_answer_out_loud() {
    let mut t = Term::new(2, 8);
    // DECSLRM is declined, so its margins are not answered either; the rest are names
    // nothing here sets, or no name at all, or a valid name buried in a longer one.
    for name in ["s", "t", "$}", "", "mm", "rrrrrrrr"] {
        assert_eq!(decrqss(&mut t, name), "\x1bP0$r\x1b\\", "{name:?}");
    }
}

#[test]
fn decrqss_is_not_mistaken_for_a_sixel() {
    // Both end in `q`; only the intermediate says which. A status request collected as
    // a picture would decode to nothing, and a sixel answered as a status request would
    // put a refusal on the child's input.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1bP$qm\x1b\\");
    let delta = t.drain();
    assert!(delta.images.is_empty());
    assert_eq!(delta.events.len(), 1);
    t.feed(b"\x1bP0;0;0q#0;2;100;0;0~\x1b\\");
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1);
    assert!(!delta.events.iter().any(|e| matches!(e, Event::Reply(_))));
}

#[test]
fn a_decrqss_split_across_writes_is_one_request() {
    let mut t = Term::new(2, 8);
    t.feed(b"\x1b[5 q\x1bP$");
    t.feed(b"q ");
    t.feed(b"q\x1b");
    t.feed(b"\\");
    assert_eq!(dcs_replies(&mut t), vec!["\x1bP1$r5 q\x1b\\"]);
}
