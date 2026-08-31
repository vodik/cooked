//! The VT front end, end to end.

use super::*;

/// An RGBA buffer encoded the way the emulator would encode it.
fn rgba_png(w: u32, h: u32, rgba: &[u8]) -> Vec<u8> {
    use crate::emu::image::{PixelFormat, PixelSize, Pixels};
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
    let runs = &delta.rows.iter().find(|(i, _)| *i == 0).unwrap().1;
    assert_eq!(runs[0].text, "red");
    assert_eq!(runs[0].style.fg, Color::Indexed(1));
    assert!(runs[0].style.attrs.contains(Attrs::BOLD));
    assert_eq!(runs[1].text, ".");
    assert_eq!(runs[1].style, Style::default());
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
fn b64(bytes: &[u8]) -> String {
    const SET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let mut n = 0u32;
        for (i, b) in chunk.iter().enumerate() {
            n |= u32::from(*b) << (16 - 8 * i);
        }
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(SET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

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
        delta.images[0].cells.rows, MAX_IMAGE_CELL_SPAN,
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
    // DECRQSS and the rest are unimplemented, and collecting a payload only to throw
    // it away is worse than not collecting it.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1bP$qm\x1b\\");
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
        (&b"\x1b[?1004h"[..], 1004, 1),
        (&b"\x1b[?1049h"[..], 1049, 1),
        // Deliberately not implemented — the drop list, machine readable.
        (&b""[..], 12, 4),
        (&b""[..], 69, 4),
        (&b""[..], 1034, 4),
        // Never heard of it.
        (&b""[..], 9999, 0),
        // Implemented, and must not answer "never heard of it".
        (&b""[..], 1048, 1),
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
    for mode in [1u16, 25, 66, 1004, 1007, 2004] {
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
        assert_eq!(t.drain().cursor_shape, want, "{input:?}");
    }
}

#[test]
fn an_unknown_cursor_shape_is_left_alone() {
    let mut t = term(2, 8, b"\x1b[5 q\x1b[9 q");
    assert_eq!(t.drain().cursor_shape, CursorShape::Bar);
}

#[test]
fn a_soft_reset_returns_the_cursor_to_a_block() {
    let mut t = term(2, 8, b"\x1b[5 q\x1b[!p");
    assert_eq!(t.drain().cursor_shape, CursorShape::Block);
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
fn xtwinops_pushes_and_pops_the_title() {
    let mut t = term(2, 10, b"\x1b[22;0;0t\x1b[23;0;0t");
    let events = t.drain().events;
    assert!(events.contains(&Event::TitleStack(true)));
    assert!(events.contains(&Event::TitleStack(false)));
}

#[test]
fn xtwinops_refuses_to_report_the_title_or_move_the_window() {
    // `21t` would put the child's own title back on its input stream. `3t`/`4t`/`8t`
    // are Emacs' geometry. All four answer with silence, not with a reply.
    let mut t = term(2, 10, b"\x1b[21t\x1b[3;0;0t\x1b[4;0;0t\x1b[8;9;9t");
    assert!(
        t.drain()
            .events
            .iter()
            .all(|e| !matches!(e, Event::Reply(_))),
        "no window operation may answer the child"
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
    assert!(t.drain().cursor_visible, "mode 25 is back on");

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
    assert!(delta.alt);

    t.feed(b"\x1b[?1049l");
    let back = t.drain();
    assert!(!back.alt);
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
    let mut t = term(
        4,
        20,
        b"\x1b]133;A\x07> \x1b]133;A;k=s\x07\x1b]133;B\x07",
    );
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
    assert!(mouse.click && mouse.drag && mouse.sgr);
    assert!(
        t.drain()
            .events
            .iter()
            .any(|e| matches!(e, Event::Mouse(_)))
    );

    t.feed(b"\x1b[?1002l\x1b[?1006l");
    assert!(!t.mouse().enabled());
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
    assert!(t.drain().app_cursor);

    t.feed(b"\x1b[?1l");
    assert!(!t.app_cursor());
    assert!(!t.drain().app_cursor);
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
    assert_eq!(t.keys(), KeyEncoding::ModifyOtherKeys);
    assert_eq!(t.drain().keys, KeyEncoding::ModifyOtherKeys);

    // Level 1 does not cover Return and friends, so it is not enough for us.
    t.feed(b"\x1b[>4;1m");
    assert_eq!(t.keys(), KeyEncoding::Legacy);

    t.feed(b"\x1b[>4;2m\x1b[>4m");
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "a bare reset turns it back off"
    );
}

#[test]
fn kitty_keyboard_flags_stack() {
    let mut t = term(4, 20, b"\x1b[>1u");
    assert_eq!(t.keys(), KeyEncoding::Kitty);

    t.feed(b"\x1b[>0u");
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "the pushed level is what counts"
    );

    t.feed(b"\x1b[<u");
    assert_eq!(
        t.keys(),
        KeyEncoding::Kitty,
        "popping restores what was underneath"
    );

    t.feed(b"\x1b[=0u");
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "set replaces the top of the stack"
    );
}

#[test]
fn a_kitty_query_is_answered() {
    // A child that probes and hears nothing back may sit there waiting.
    let mut t = term(4, 20, b"\x1b[>5u\x1b[?u");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?5u".to_vec()))
    );
}

#[test]
fn reset_clears_negotiated_keyboard_modes() {
    let mut t = term(4, 20, b"\x1b[>4;2m\x1b[>1u");
    assert_eq!(t.keys(), KeyEncoding::Kitty);
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
    assert_eq!(rows[0].0, 0);
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
    let (_, runs) = delta
        .rows
        .iter()
        .find(|(i, _)| *i == 0)
        .expect("row 0 is damaged");
    assert_eq!(runs.len(), 1);
    let glyphs = runs[0].deco.as_ref().expect("box-glyph run").glyphs();
    assert_eq!(glyphs.len(), 4, "one descriptor per character");
    assert_eq!(runs[0].text, "\u{250C}\u{2500}\u{2500}\u{2510}");
}

#[test]
fn diagonal_and_stub_bytes_also_produce_glyphs() {
    let mut t = term(2, 10, "\u{2571}\u{2572}\u{2573}\u{2574}".as_bytes());
    let delta = t.drain();
    let (_, runs) = delta
        .rows
        .iter()
        .find(|(i, _)| *i == 0)
        .expect("row 0 is damaged");
    assert_eq!(runs.len(), 1);
    let glyphs = runs[0].deco.as_ref().expect("box-glyph run").glyphs();
    assert_eq!(glyphs.len(), 4);
    assert!(glyphs[0].is_diagonal());
    assert!(
        !glyphs[3].is_diagonal(),
        "the stub is edge-based, not a diagonal"
    );
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
