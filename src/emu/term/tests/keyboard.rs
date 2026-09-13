//! Negotiated keyboard protocols: DECCKM, modifyOtherKeys and the kitty flag stacks.

use super::*;

#[test]
fn meta_sending_escape_is_permanently_set() {
    // Both before and after a child tries to turn it off: Lisp spells Meta as ESC
    // whatever the core is told, so the answer must not follow the request.
    let mut t = term(2, 10, b"\x1b[?1036$p\x1b[?1036l\x1b[?1036$p");
    let replies = t.drain().events;
    let set = Event::Reply(b"\x1b[?1036;3$y".to_vec());
    assert_eq!(replies.iter().filter(|event| **event == set).count(), 2);
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
    assert_eq!(
        t.keys(),
        KeyEncoding::kitty(KittyFlags::DISAMBIGUATE).unwrap()
    );
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
    assert_eq!(
        t.keys(),
        KeyEncoding::kitty(KittyFlags::DISAMBIGUATE).unwrap()
    );

    t.feed(b"\x1b[>0u");
    assert_eq!(
        t.keys(),
        KeyEncoding::Legacy,
        "the pushed level is what counts"
    );

    t.feed(b"\x1b[<u");
    assert_eq!(
        t.keys(),
        KeyEncoding::kitty(KittyFlags::DISAMBIGUATE).unwrap(),
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
        KeyEncoding::kitty(KittyFlags::from_bits_retain(29)).unwrap()
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
        KeyEncoding::kitty(KittyFlags::REPORT_ALL_KEYS).unwrap()
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
    assert_eq!(
        t.keys(),
        KeyEncoding::kitty(KittyFlags::DISAMBIGUATE).unwrap()
    );
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
