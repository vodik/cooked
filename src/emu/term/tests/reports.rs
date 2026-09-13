//! Answers owed to the child: device attributes, XTWINOPS, mode 2048, XTSMGRAPHICS and DSR.

use super::*;

#[test]
fn xtwinops_reports_pixel_geometry_once_emacs_has_reported_a_cell_size() {
    let mut t = with_metrics(24, 80);
    t.feed(b"\x1b[14t\x1b[16t");
    let replies = reply_strings(&mut t);
    // 24 rows x 20px and 80 cols x 10px; then the cell itself.
    assert_eq!(replies, vec!["\x1b[4;480;800t", "\x1b[6;20;10t"]);
}

fn size_reports(events: &[Event]) -> Vec<String> {
    events
        .iter()
        .filter_map(|e| match e {
            Event::SizeReport(bytes) => Some(String::from_utf8(bytes.clone()).unwrap()),
            _ => None,
        })
        .collect()
}

const CELL: Option<CellMetrics> = CellMetrics::new(10, 20);

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
    let zoomed = CellMetrics::new(12, 24);
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
        t.set_size(10, 40, None).as_deref(),
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
    t.set_cell_metrics(CellMetrics::new(10, 20));
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
    assert!(events.contains(&Event::TitleStack(StackOp::Push)));
    assert!(events.contains(&Event::TitleStack(StackOp::Pop)));
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
            Event::FrameSize(Unit::Cells),
            Event::FrameSize(Unit::Pixels),
        ],
        "the order is the order asked, since a reply from Lisp rides the same list"
    );
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
fn cursor_position_report_is_answered() {
    let mut t = term(4, 20, b"\x1b[3;5H\x1b[6n");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[3;5R".to_vec()))
    );
}

#[test]
fn extended_cursor_position_report_is_answered() {
    let mut t = term(4, 20, b"\x1b[3;5H\x1b[?6n");
    assert!(
        t.drain()
            .events
            .contains(&Event::Reply(b"\x1b[?3;5R".to_vec()))
    );
}

#[test]
fn cursor_position_reports_count_from_the_region_under_origin_mode() {
    // DECOM puts `CSI 1;1H` at the top of the region, so row 1 is what the report says
    // there: a child that sends back what it was told lands where it was.
    let mut t = term(6, 20, b"\x1b[3;5r\x1b[?6h\x1b[2;4H\x1b[6n\x1b[?6n");
    let replies: Vec<_> = t
        .drain()
        .events
        .into_iter()
        .filter(|event| matches!(event, Event::Reply(_)))
        .collect();
    assert_eq!(
        replies,
        vec![
            Event::Reply(b"\x1b[2;4R".to_vec()),
            Event::Reply(b"\x1b[?2;4R".to_vec()),
        ]
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
    t.feed(b"\x1b[?15n\x1b[?25n");
    assert!(
        t.drain()
            .events
            .iter()
            .all(|e| !matches!(e, Event::Reply(_)))
    );
}
