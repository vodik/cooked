//! Pictures: kitty graphics, sixel and iTerm2 inline images, and how they are placed and shed.

use super::*;
use crate::emu::ShownFormats;

/// An RGBA buffer encoded the way the emulator would encode it.
fn rgba_png(w: u32, h: u32, rgba: &[u8]) -> Vec<u8> {
    use crate::emu::image::PixelSize;
    use crate::emu::png::{PixelFormat, Pixels};
    Pixels::new(PixelSize::new(w, h), PixelFormat::Rgba, rgba.to_vec())
        .encode()
        .1
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
    let replies = reply_strings(&mut t);
    assert_eq!(replies, vec!["\x1b[?62;4;22c"]);
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

    t.set_graphics_shown(ShownFormats::NONE);
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

    t.set_graphics_shown(ShownFormats::ALL);
    t.feed(probes);
    assert_eq!(reply_strings(&mut t), shown);
}

#[test]
fn a_build_without_png_refuses_what_would_reach_emacs_as_one() {
    // An Emacs with images but no libpng still decodes binary P6, so a kitty `f=24` probe
    // is told OK. `f=100` and `f=32` would reach Emacs as a PNG, and so would a sixel, so
    // those probes are refused and DA1 loses its `4`.
    let mut t = with_metrics(24, 80);
    t.set_graphics_shown(ShownFormats::of([
        ImageFormat::Jpeg,
        ImageFormat::Gif,
        ImageFormat::Ppm,
    ]));
    t.feed(b"\x1b[c\x1b[?1;1S");
    t.feed(b"\x1b_Gi=1,s=1,v=1,a=q,t=d,f=24;AAAA\x1b\\");
    t.feed(b"\x1b_Gi=2,s=1,v=1,a=q,t=d,f=32;AAAAAA==\x1b\\");
    t.feed(b"\x1b_Gi=3,a=q,t=d,f=100;AAAA\x1b\\");
    assert_eq!(
        reply_strings(&mut t),
        vec![
            "\x1b[?62;22c",
            "\x1b[?1;3S",
            "\x1b_Gi=1;OK\x1b\\",
            "\x1b_Gi=2;ENOTSUPPORTED:format\x1b\\",
            "\x1b_Gi=3;ENOTSUPPORTED:format\x1b\\",
        ]
    );
}

#[test]
fn hidden_graphics_survive_a_reset() {
    // What Emacs can display is not something the child negotiated, so neither DECSTR
    // nor RIS may put the `4` back.
    let mut t = with_metrics(10, 20);
    t.set_graphics_shown(ShownFormats::NONE);
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
    t.set_graphics_shown(ShownFormats::NONE);
    t.feed(format!("\x1b_Ga=T,f=100,i=7,m=1;{head}\x1b\\").as_bytes());
    t.feed(b"\x1b_Ga=q,i=8,s=1,v=1,f=24;AAAA\x1b\\");
    t.feed(format!("\x1b_Gm=0;{tail}\x1b\\").as_bytes());
    let delta = t.drain();
    assert_eq!(delta.images.len(), 1, "the picture still arrives");
    let replies = replies(delta.events);
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
    t.set_graphics_shown(ShownFormats::NONE);
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
    let cursor = t.screen().cursor();
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
    let replies = reply_strings(&mut t);
    assert_eq!(replies, vec!["\x1b_Gi=31;OK\x1b\\"]);
}

#[test]
fn an_unsupported_capability_is_declined_out_loud() {
    // A client told ENOTSUPPORTED can fall back; one whose transmission vanishes
    // shows the user nothing and cannot find out why. Transmission by file is the
    // remaining one: reading a path a child names is a decision about trust.
    let mut t = with_metrics(10, 20);
    t.feed(b"\x1b_Ga=T,f=100,t=f,i=4;AAAA\x1b\\");
    let replies = reply_strings(&mut t);
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
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (1, 3));
}

#[test]
fn a_sixel_leaves_the_cursor_on_the_line_below() {
    let mut t = with_metrics(24, 80);
    // The same 3x2-cell picture by the route sixel and iTerm2 take. xterm scrolls a
    // sixel to the next line, so the disposition genuinely differs from kitty's.
    t.place_image(ImageFormat::Png, b"pixels", PixelSize::new(30, 40));
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (2, 0));
}

#[test]
fn a_kitty_picture_reaching_the_right_edge_wraps_to_the_next_line() {
    let mut t = with_metrics(24, 4);
    kitty_image(&mut t, "a=T,f=100,c=4,r=1,i=1");
    // Column 4 is off a four-column screen, so there is nowhere on this row for the
    // cursor to rest -- which is the one case kitty's clients expect the move for.
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (1, 0));
}

#[test]
fn an_animation_redrawn_in_place_does_not_walk_down_the_screen() {
    // What viu does per frame: draw, print a newline, and come back up by the picture's
    // height. An extra linefeed after the last row makes that arithmetic wrong by one
    // row a frame, and the picture crawls off the bottom.
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[6;1H");
    let top = t.screen().cursor().row;
    for _ in 0..4 {
        kitty_image(&mut t, "a=T,f=100,c=3,r=2,i=1");
        t.feed(b"\r\n\x1b[2A");
        assert_eq!(t.screen().cursor().row, top, "the frame drifted");
    }
}

#[test]
fn an_echo_inside_a_frame_does_not_leave_the_shell_to_erase_the_picture() {
    // Ctrl-C during an animation. `ECHOCTL` writes `^C` into the pty's output the moment
    // the key is pressed, which for a child blocked part-way through a four-megabyte
    // frame is between two pieces of that write — so the echo lands inside the payload.
    //
    // Refusing the frame over two bytes nobody sent would cost the whole picture: the
    // cursor stays at the picture's top left, where viu parks it between frames, and the
    // shell's `ED` on the way to a new prompt erases everything below the first row.
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[6;1H");
    let top = t.screen().cursor().row;
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
    assert_eq!(
        (t.screen().cursor().row, t.screen().cursor().col),
        (top + 1, 3)
    );

    // So the newline and the prompt land below the picture, and both its rows survive.
    t.feed(b"\r\n\x1b[J");
    assert_eq!(placements(&t, top).len(), 3);
    assert_eq!(placements(&t, top + 1).len(), 3);
}

#[test]
fn kitty_c_leaves_the_cursor_exactly_where_it_was() {
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[3;6H");
    let entry = t.screen().cursor();
    kitty_image(&mut t, "a=T,f=100,c=3,r=2,i=1,C=1");
    assert_eq!(t.screen().cursor(), entry);
    // The picture was still drawn, from the cursor as usual.
    assert_eq!(placements(&t, 2).len(), 3);
}

/// With the cursor staying put, a picture that ends at the right edge of the bottom row
/// has no reason to scroll: the line feed that would take the cursor past the edge is
/// never needed.
#[test]
fn kitty_c_at_the_bottom_right_scrolls_nothing() {
    let mut t = with_metrics(3, 6);
    t.feed(b"top[3;4H");
    t.drain();
    let entry = t.screen().cursor();
    kitty_image(&mut t, "a=T,f=100,c=3,r=1,i=1,C=1");
    assert_eq!(t.screen().cursor(), entry);
    assert!(t.drain().scrolled.is_empty(), "nothing left the screen");
    assert_eq!(text(&t, 0), "top");
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
/// not as a reference to one nobody holds. Ids are content-addressed, so without
/// `forget_image` the second transmission would get the first id and no bytes.
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
    let replies = replies(delta.events);
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

/// A picture the child sizes in pixels rather than in cells is measured into a cell
/// rectangle at every transmission, against the cell as it is at that moment. So a font
/// change needs no repair: the next frame the child draws is laid at the rectangle the
/// new cell implies, while the bytes -- which have not changed -- do not cross again.
///
/// A measurement kept against the id would make a gif flip between two sizes after a
/// zoom: frames Emacs still held re-laid at the old rectangle, evicted ones measured
/// against the new one.
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
    t.set_cell_metrics(CellMetrics::new(20, 40));
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
    t.set_cell_metrics(CellMetrics::new(10, 20));
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
/// The child cannot know the font changed and has every reason to think its picture is
/// still there. The measurement is redone per placement (see [`ImageStore::cells`]), so
/// there is nothing stale to protect against and the name is kept.
#[test]
fn a_client_name_survives_a_cell_change_and_is_replaced_at_the_new_size() {
    let mut t = with_metrics(10, 20);
    // 10x20 pixels: exactly one cell at a 10x20 cell, and a quarter of one once the
    // cell doubles -- which still rounds up to one, so the *rectangle* is the thing to
    // watch rather than the count.
    let pixels = vec![0u8; 40 * 60 * 3];
    t.feed(format!("\x1b_Ga=t,f=24,s=40,v=60,i=7;{}\x1b\\", b64(&pixels)).as_bytes());
    t.drain();

    t.set_cell_metrics(CellMetrics::new(20, 40));
    t.feed(b"\x1b_Ga=p,i=7\x1b\\");
    let delta = t.drain();
    let replies = replies(delta.events);
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

/// `viu`'s window reshape. It never rescales the pixels -- the *terminal* is asked to fit
/// each frame -- so a reshape changes `c=`/`r=` and nothing else. Once the animation
/// loops, every frame is bytes the module already knows (270 transmissions of 61 distinct
/// payloads) and none crosses the boundary again, so the new rectangle can only reach
/// Emacs on the placement.
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

#[test]
fn a_picture_over_half_a_wide_character_blanks_the_other_half() {
    let mut t = with_metrics(2, 6);
    let png = rgba_png(1, 1, &[0, 0, 0, 255]);
    t.feed("a日b\x1b[1;3H".as_bytes());
    t.feed(format!("\x1b_Ga=T,f=100,c=1,r=1,i=1;{}\x1b\\", b64(&png)).as_bytes());
    let row = t.screen().row(0).unwrap();
    assert!(row.cells().iter().all(|cell| !cell.is_continuation()));
    assert_eq!(row.to_text(), "a  b");
    assert_eq!(placements(&t, 0).len(), 1);
}
