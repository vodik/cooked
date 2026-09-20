//! DEC and ANSI modes: DECRQM, the flag modes, the mouse, XTSAVE and XTRESTORE.

use super::*;

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
        let want = Reply::answer(format!("\x1b[?{mode};{want}$y").into_bytes()).into();
        assert!(
            t.drain().events.contains(&want),
            "mode {mode} after {setup:?}"
        );
    }
}

/// Every one-flag mode must set, report itself set, and come back reset by DECSTR.
///
/// The guard on `dec_flags!` staying one table for set, query and reset, so a mode cannot
/// be settable while reporting itself unrecognised, or survive a soft reset.
#[test]
fn every_flag_mode_sets_reports_and_soft_resets() {
    for mode in [1u16, 5, 25, 66, 1004, 1007, 2004, 2031, 2048] {
        let mut t = term(4, 8, b"");

        // Whatever it powers on as, DECRQM must not answer "never heard of it".
        t.feed(format!("\x1b[?{mode}$p").as_bytes());
        let powered_on = t.drain().events;
        assert!(
            !powered_on.contains(&Reply::answer(format!("\x1b[?{mode};0$y").into_bytes()).into()),
            "mode {mode} reports itself unrecognised"
        );

        // Set it, and it must say so.
        t.feed(format!("\x1b[?{mode}h\x1b[?{mode}$p").as_bytes());
        assert!(
            t.drain()
                .events
                .contains(&Reply::answer(format!("\x1b[?{mode};1$y").into_bytes()).into()),
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
                .contains(&Reply::answer(format!("\x1b[?{mode};{want}$y").into_bytes()).into()),
            "mode {mode} survives a soft reset"
        );
    }
}

#[test]
fn decrqm_answers_for_ansi_modes_too() {
    for (setup, mode, want) in [
        (&b"\x1b[4h"[..], 4u16, 1u8),
        (&b""[..], 4, 2),
        (&b"\x1b[20h"[..], 20, 1),
        // KAM: nothing locks the keyboard, and a set does not either.
        (&b""[..], 2, 4),
        (&b"\x1b[2h"[..], 2, 4),
        // SRM: there is never local echo, so it is set and stays set.
        (&b""[..], 12, 3),
        (&b"\x1b[12l"[..], 12, 3),
        // The ECMA-48 block-mode modes xterm also answers 4.
        (&b""[..], 1, 4),
        (&b""[..], 3, 4),
        (&b""[..], 19, 4),
        // Never heard of it.
        (&b""[..], 6, 0),
        (&b""[..], 21, 0),
    ] {
        let mut t = term(2, 8, setup);
        t.feed(format!("\x1b[{mode}$p").as_bytes());
        let want = Reply::answer(format!("\x1b[{mode};{want}$y").into_bytes()).into();
        assert!(
            t.drain().events.contains(&want),
            "ANSI mode {mode} after {setup:?}"
        );
    }
}

/// A mode number past what a parameter holds saturates at 65535, which names no mode,
/// rather than wrapping onto one that does: `67540` is 2004 plus 65536.
#[test]
fn decrqm_for_a_mode_past_the_parameter_range_is_unknown() {
    let mut t = term(2, 8, b"\x1b[?2004h\x1b[?67540$p\x1b[67540$p");
    let replies: Vec<_> = t
        .drain()
        .events
        .into_iter()
        .filter(|event| matches!(event, Event::Reply(reply) if reply.kind == ReplyKind::Answer))
        .collect();
    assert_eq!(
        replies,
        vec![
            Reply::answer(b"\x1b[?65535;0$y".to_vec()).into(),
            Reply::answer(b"\x1b[65535;0$y".to_vec()).into(),
        ]
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
fn a_focus_notification_is_owed_only_to_a_child_that_subscribed() {
    let mut t = term(2, 8, b"");
    // Nothing at all before 1004, rather than the sequence with nobody to read it:
    // a program that never asked reads `ESC [ I' as an escape sequence.
    assert_eq!(t.focus_report(true), None);
    assert_eq!(t.focus_report(false), None);
    t.feed(b"\x1b[?1004h");
    assert_eq!(t.focus_report(true), Some(&b"\x1b[I"[..]));
    assert_eq!(t.focus_report(false), Some(&b"\x1b[O"[..]));
    t.feed(b"\x1b[?1004l");
    assert_eq!(t.focus_report(true), None);
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

/// A `flash` whose set and reset land in one read still reaches the drain: the level is
/// back where it was, but the count says it moved twice. A set that changes nothing is
/// not counted.
#[test]
fn a_flash_inside_one_drain_is_counted() {
    let mut t = term(2, 8, b"ab");
    assert_eq!(t.drain().levels.reverse_screen_toggles, 0);
    assert!(t.feed(b"\x1b[?5h\x1b[?5l"), "the flash is an update");
    let levels = t.drain().levels;
    assert!(!levels.reverse_screen);
    assert_eq!(levels.reverse_screen_toggles, 2);
    t.feed(b"\x1b[?5l\x1b[?5h\x1b[?5h\x1bc");
    let levels = t.drain().levels;
    assert!(!levels.reverse_screen);
    assert_eq!(
        levels.reverse_screen_toggles, 3,
        "the repeat and RIS are not toggles"
    );
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
            .contains(&Reply::answer(b"\x1b[?5;2$y".to_vec()).into())
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
fn mouse_modes_accumulate_and_report() {
    let mut t = term(4, 20, b"\x1b[?1002h\x1b[?1006h");
    let mouse = t.mouse();
    assert!(mouse.drag() && !mouse.motion() && mouse.sgr());
    assert!(
        t.drain()
            .events
            .iter()
            .any(|e| matches!(e, Event::Mouse(_)))
    );

    t.feed(b"\x1b[?1002l\x1b[?1006l");
    assert!(!t.mouse().enabled());
}

/// Resetting any tracking mode turns tracking off, whichever one was set, as xterm's
/// single `send_mouse_pos` does. Flag by flag, `1002 h` then `1000 l` left drag reporting
/// on with click reporting off, which is a report no terminal sends.
#[test]
fn resetting_any_tracking_mode_turns_tracking_off() {
    for reset in [1000, 1002, 1003] {
        let mut t = term(4, 20, b"\x1b[?1002h");
        t.feed(format!("\x1b[?{reset}l").as_bytes());
        assert_eq!(t.mouse().tracking, MouseTracking::Off, "?{reset}l");
        t.feed(b"\x1b[?1002$p");
        assert!(
            t.drain()
                .events
                .contains(&Reply::answer(b"\x1b[?1002;2$y".to_vec()).into()),
            "?{reset}l leaves 1002 reporting reset"
        );
    }

    // A set replaces rather than accumulates, so DECRQM names exactly one mode.
    let mut t = term(4, 20, b"\x1b[?1002h\x1b[?1003h\x1b[?1000h");
    assert_eq!(t.mouse().tracking, MouseTracking::Click);
    t.feed(b"\x1b[?1000$p\x1b[?1002$p\x1b[?1003$p");
    let events = t.drain().events;
    for (mode, answer) in [(1000, 1), (1002, 2), (1003, 2)] {
        let reply = format!("\x1b[?{mode};{answer}$y").into_bytes();
        assert!(
            events.contains(&Reply::answer(reply).into()),
            "{mode}: {events:?}"
        );
    }
}

/// 1006 and 1016 are one choice, not two flags: xterm makes the extended coordinate
/// modes mutually exclusive, a set replacing whatever was in force and a reset effective
/// only against its own mode.
#[test]
fn mouse_coordinate_modes_replace_each_other() {
    let rqm = |t: &mut Term, mode: u16| {
        t.feed(format!("\x1b[?{mode}$p").as_bytes());
        let events = t.drain().events;
        [1u8, 2].into_iter().find(|v| {
            events.contains(&Reply::answer(format!("\x1b[?{mode};{v}$y").into_bytes()).into())
        })
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
fn xtsave_restores_a_private_mode() {
    let mut t = term(2, 8, b"\x1b[?1006h\x1b[?1006s\x1b[?1006l");
    assert!(!t.mouse().sgr());
    t.feed(b"\x1b[?1006r\x1b[?1006$p");
    assert!(t.mouse().sgr());
    assert!(
        t.drain()
            .events
            .contains(&Reply::answer(b"\x1b[?1006;1$y".to_vec()).into())
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
    assert_eq!(mouse.tracking, MouseTracking::Drag);
    assert!(!mouse.sgr());
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

/// xterm keeps one XTSAVE slot for the tracking modes and one for the coordinate
/// encodings, because each group is one choice: what was saved under one number is
/// restored under any other number in the same group.
#[test]
fn xtsave_slots_are_shared_within_each_mouse_group() {
    let mut t = term(2, 8, b"\x1b[?1000s\x1b[?1003h\x1b[?1002r");
    assert_eq!(
        t.mouse().tracking,
        MouseTracking::Off,
        "saved under 1000, restored under 1002"
    );

    // Saved while X10 was in force, then SGR set: restoring under 1016 puts X10 back,
    // which a flag saved for 1016 alone -- off before and off after -- never would.
    t.feed(b"\x1b[?1016s\x1b[?1006h\x1b[?1016r");
    assert_eq!(t.mouse().format, MouseFormat::X10);
}

/// 47, 1047 and 1049 share one slot, as in xterm, and a restore only switches screens:
/// saved under 47 and restored under 1049 goes back to the primary screen without the
/// cursor restore a `1049 l` would do, and the primary's cursor is its own.
#[test]
fn xtsave_shares_one_slot_across_the_alternate_screen_modes() {
    let mut t = term(4, 8, b"\x1b[2;2H\x1b7\x1b[3;3H\x1b[?47s\x1b[?47h");
    assert!(t.drain().levels.alt);
    t.feed(b"\x1b[?1049r");
    assert!(!t.drain().levels.alt, "saved under 47, restored under 1049");
    assert_eq!(
        (t.screen().cursor().row, t.screen().cursor().col),
        (2, 2),
        "no DECRC of the save 47 never made"
    );

    // And the other way: saved on the alternate screen under 1049, restored under 47.
    t.feed(b"\x1b[?1049h\x1b[?1049s\x1b[?1049l\x1b[?47r");
    assert!(t.drain().levels.alt);
}

/// A restore that changes nothing does nothing -- DECOM's `h`/`l` homes the cursor, and
/// a restore is not a replay.
#[test]
fn xtrestore_of_an_unchanged_mode_does_not_move_the_cursor() {
    let t = term(4, 8, b"\x1b[?6s\x1b[3;3H\x1b[?6r");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (2, 2));
}

/// `CSI ? s` and `CSI ? r` are not SCOSC and DECSTBM, which have no private byte.
#[test]
fn xtsave_is_not_save_cursor_and_xtrestore_is_not_decstbm() {
    // Had `?25s` saved the cursor, `CSI u` would go back to 2;3. With no save it homes.
    let t = term(4, 8, b"\x1b[2;3H\x1b[?25s\x1b[4;4H\x1b[u");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (0, 0));

    let t = term(4, 8, b"\x1b[2;3r\x1b[3;3H\x1b[?25r");
    assert_eq!((t.screen().cursor().row, t.screen().cursor().col), (2, 2));
    assert_eq!(
        (t.screen().region().top, t.screen().region().bottom),
        (1, 2)
    );
}

/// Both stacks are negotiated state, and RIS is the child starting over.
#[test]
fn reset_clears_the_pen_stack_and_saved_modes() {
    let mut t = term(2, 8, b"\x1b[31m\x1b[#{\x1b[?1006h\x1b[?1006s\x1bc");
    t.feed(b"\x1b[32m\x1b[#}a\x1b[?1006r");
    assert_eq!(run_style(&t, "a").fg, Color::Indexed(2));
    assert!(!t.mouse().sgr(), "no slot survives to restore");

    let mut t = term(2, 8, b"\x1b[?1006s\x1b[?1006h");
    t.feed(b"\x1bc\x1b[?1006h\x1b[?1006r");
    assert!(t.mouse().sgr());
}
