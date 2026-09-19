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
fn modify_other_keys_is_disabled_and_queried_as_xterm_does() {
    // `CSI > 4 n` is xterm's way to switch the resource off, and was ignored: a child
    // that turned modifyOtherKeys off that way went on receiving `ESC [ 27 ; ...`.
    let mut t = term(4, 20, b"\x1b[>4;2m");
    t.feed(b"\x1b[>4n");
    assert_eq!(t.keys(), KeyEncoding::Legacy);

    // Another resource's switch leaves this one alone, and so does a bare `CSI > n`,
    // which names modifyFunctionKeys.
    t.feed(b"\x1b[>4;1m\x1b[>1n\x1b[>n");
    assert_eq!(
        t.keys(),
        KeyEncoding::ModifyOtherKeys(ModifyOtherKeys::Level1)
    );

    // XTQMODKEYS reports the level the encoder honours, and 0 once there is none.
    t.drain();
    t.feed(b"\x1b[?4m\x1b[>4;3m\x1b[?4m\x1b[?1m");
    assert_eq!(reply_strings(&mut t), ["\x1b[>4;1m", "\x1b[>4;0m"]);
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
        reply(b"\x1b[>31u\x1b[?u"),
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

/// `CSI = FLAGS ; MODE u` on the alternate screen changes that screen's stack and only
/// that one, in each of the modes that combine with what is there.
#[test]
fn kitty_set_adds_and_removes_on_the_alternate_stack() {
    let mut t = term(4, 20, b"\x1b[>4u\x1b[?1049h\x1b[>1u");
    t.feed(b"\x1b[=8;2u");
    assert_eq!(
        t.kitty_flags().bits(),
        9,
        "mode 2 adds to the alternate top"
    );
    t.feed(b"\x1b[=1;3u");
    assert_eq!(
        t.kitty_flags().bits(),
        8,
        "mode 3 clears on the alternate top"
    );
    t.feed(b"\x1b[?1049l");
    assert_eq!(
        t.kitty_flags().bits(),
        4,
        "the primary's top is as it was pushed"
    );
}

/// A set with nothing pushed creates the entry it changes, so the flags take effect,
/// and a pop takes them away again.
#[test]
fn kitty_set_on_an_empty_stack_takes_effect() {
    let mut t = term(4, 20, b"\x1b[=1u");
    assert_eq!(t.kitty_flags().bits(), 1);
    t.feed(b"\x1b[<u\x1b[=8;2u");
    assert_eq!(
        t.kitty_flags().bits(),
        8,
        "mode 2 adds to the empty default"
    );
    t.feed(b"\x1b[<u\x1b[=8;3u");
    assert!(
        t.kitty_flags().is_empty(),
        "mode 3 on nothing leaves nothing"
    );
}

/// A flag value past the five bits the protocol defines is ignored, not truncated:
/// read as a byte, 257 would push 1 and turn disambiguation on. 31 is the widest value
/// accepted and 32 the first refused, as in ghostty.
#[test]
fn kitty_flags_out_of_range_are_ignored() {
    let mut t = term(4, 20, b"\x1b[>4u\x1b[>257u");
    assert_eq!(t.kitty_flags().bits(), 4, "the push of 257 did nothing");
    t.feed(b"\x1b[<u");
    assert!(
        t.kitty_flags().is_empty(),
        "one pop undoes the one push that happened"
    );

    t.feed(b"\x1b[>32u");
    assert!(t.kitty_flags().is_empty(), "32 is past the defined bits");
    t.feed(b"\x1b[>31u");
    assert_eq!(t.state.kitty_stack().top().bits(), 31);

    t.feed(b"\x1b[=256u\x1b[=65535;2u");
    assert_eq!(
        t.state.kitty_stack().top().bits(),
        31,
        "a set out of range leaves the top alone"
    );
}

/// A set mode the protocol does not define is ignored, where reading it as a replace
/// would throw away every flag it did not name.
#[test]
fn kitty_set_with_an_unknown_mode_is_ignored() {
    let mut t = term(4, 20, b"\x1b[>9u\x1b[=1;4u");
    assert_eq!(t.kitty_flags().bits(), 9);
    t.feed(b"\x1b[=4;0u");
    assert_eq!(
        t.kitty_flags().bits(),
        4,
        "0 is the default mode, replace, like an empty parameter"
    );
}

/// `CSI < 0 u` pops one, like `CSI < u`. The parser hands both over as a single 0, so
/// ghostty's pop of nothing for a written 0 cannot be told apart from the bare form.
#[test]
fn kitty_pop_of_zero_pops_one() {
    let t = term(4, 20, b"\x1b[>1u\x1b[>8u\x1b[<0u");
    assert_eq!(t.kitty_flags().bits(), 1);
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

// Spelling a key press. The cases are xterm's and kitty's own tables, and they are the
// cases the ERT key suite asserted while the encoder lived in Lisp; what is checked here
// is the bytes, and what is left to that suite is the Emacs half -- which event names
// which key.

const NONE: Modifiers = Modifiers::NONE;
const SHIFT: Modifiers = Modifiers::SHIFT;
const META: Modifiers = Modifiers::META;
const CONTROL: Modifiers = Modifiers::CONTROL;
const SUPER: Modifiers = Modifiers::SUPER;
const HYPER: Modifiers = Modifiers::HYPER;

/// The text key CHAR, as `event-basic-type` names one.
fn ch(c: char) -> Key {
    Key::parse_char(c as i64).expect("a character is a key")
}

/// The table row NAME, as Lisp spells the symbol.
fn named(name: &str) -> Key {
    Key::parse_name(name).unwrap_or_else(|| panic!("{name} is a key cooked speaks for"))
}

/// What the child receives for KEY held with MODS, against the negotiation as it stands.
fn spell(t: &Term, key: Key, mods: Modifiers) -> String {
    guessing(t, key, mods, None).expect("this key has a spelling")
}

/// [`spell`] for a program Lisp guesses a protocol for; see `Assumed`.
fn guessing(t: &Term, key: Key, mods: Modifiers, assumed: Option<Assumed>) -> Option<String> {
    t.key_report(key, mods, assumed)
        .map(|bytes| String::from_utf8(bytes).expect("a key is spelled in UTF-8"))
}

#[test]
fn a_key_is_spelled_against_the_flags_the_child_pushed_a_moment_ago() {
    // The whole point of spelling here: no drain sits between the child asking for the
    // kitty protocol and the next key being spelled in it. While Lisp held the
    // negotiation, this Shift+Return went out as a bare CR.
    let mut t = term(4, 20, b"");
    assert_eq!(spell(&t, named("return"), SHIFT), "\r");
    t.feed(b"\x1b[>1u");
    assert_eq!(spell(&t, named("return"), SHIFT), "\x1b[13;2u");
    t.feed(b"\x1b[<1u");
    assert_eq!(spell(&t, named("return"), SHIFT), "\r");
}

#[test]
fn modified_arrows_use_xterm_parameters() {
    let mut t = term(4, 20, b"");
    assert_eq!(spell(&t, named("up"), NONE), "\x1b[A");
    assert_eq!(spell(&t, named("up"), SHIFT), "\x1b[1;2A");
    assert_eq!(spell(&t, named("up"), META), "\x1b[1;3A");
    assert_eq!(spell(&t, named("up"), CONTROL), "\x1b[1;5A");
    assert_eq!(spell(&t, named("right"), CONTROL.with(SHIFT)), "\x1b[1;6C");
    // DECCKM only applies to the unmodified form.
    t.feed(b"\x1b[?1h");
    assert_eq!(spell(&t, named("up"), NONE), "\x1bOA");
    assert_eq!(spell(&t, named("left"), NONE), "\x1bOD");
    assert_eq!(spell(&t, named("up"), CONTROL), "\x1b[1;5A");
    // Keys outside the cursor cluster are unaffected by the mode.
    assert_eq!(spell(&t, named("next"), NONE), "\x1b[6~");
}

#[test]
fn modified_special_keys_are_encoded() {
    let t = term(4, 20, b"");
    // Shift+Tab has a real terminfo entry, `kcbt', so it needs no negotiation.
    assert_eq!(spell(&t, named("backtab"), SHIFT), "\x1b[Z");
    // Tilde-style keys take the modifier as a second parameter.
    assert_eq!(spell(&t, named("f5"), NONE), "\x1b[15~");
    assert_eq!(spell(&t, named("f5"), SHIFT), "\x1b[15;2~");
    assert_eq!(spell(&t, named("next"), SHIFT), "\x1b[6;2~");
    // F1 to F4 are SS3 until modified, then CSI like everything else.
    assert_eq!(spell(&t, named("f1"), NONE), "\x1bOP");
    assert_eq!(spell(&t, named("f1"), SHIFT), "\x1b[1;2P");
    // Return and friends have no classical modified form, so they send the bare byte
    // until the child negotiates something.
    assert_eq!(spell(&t, named("return"), NONE), "\r");
    assert_eq!(spell(&t, named("return"), SHIFT), "\r");
    assert_eq!(spell(&t, named("return"), META), "\x1b\r");
    // A key with no spelling but kitty's has none at all here.
    assert_eq!(t.key_report(named("pause"), NONE, None), None);
    assert_eq!(t.key_report(named("print"), CONTROL, None), None);
}

#[test]
fn legacy_control_chords_follow_x11() {
    // Masking every character to five bits sent `C-;' as ESC and `C-/' as SI.
    let t = term(4, 20, b"");
    assert_eq!(spell(&t, ch(';'), CONTROL), ";");
    assert_eq!(spell(&t, ch('.'), CONTROL), ".");
    assert_eq!(spell(&t, ch('/'), CONTROL), "\x1f");
    assert_eq!(spell(&t, ch('2'), CONTROL), "\0");
    assert_eq!(spell(&t, ch('7'), CONTROL), "\x1f");
    assert_eq!(spell(&t, ch('8'), CONTROL), "\x7f");
    assert_eq!(spell(&t, ch('?'), CONTROL), "\x7f");
    assert_eq!(spell(&t, ch('a'), CONTROL.with(SHIFT)), "\x01");
    assert_eq!(spell(&t, ch('a'), CONTROL.with(META)), "\x1b\x01");
    // Shift is the capital, and Emacs reports the letter unshifted.
    assert_eq!(spell(&t, ch('s'), SHIFT), "S");
    assert_eq!(spell(&t, ch('s'), NONE), "s");
    assert_eq!(spell(&t, ch('!'), NONE), "!");
    assert_eq!(spell(&t, ch('x'), META), "\x1bx");
}

#[test]
fn the_keypad_sends_ss3_only_while_the_keypad_is_in_application_mode() {
    let mut t = term(4, 20, b"");
    // NumLock on, the key types what is on the cap.
    assert_eq!(spell(&t, named("kp-1"), NONE), "1");
    assert_eq!(spell(&t, named("kp-add"), NONE), "+");
    // NumLock off, it is the editing key it stands in for, modifiers and all.
    assert_eq!(spell(&t, named("kp-home"), NONE), "\x1b[H");
    assert_eq!(spell(&t, named("kp-up"), CONTROL), "\x1b[1;5A");
    // `smkx' is DECCKM and DECKPAM together, and DECKPAM is what the keypad follows.
    t.feed(b"\x1b[?1h\x1b=");
    assert_eq!(spell(&t, named("kp-1"), NONE), "\x1bOq");
    assert_eq!(spell(&t, named("kp-home"), NONE), "\x1bOw");
    assert_eq!(spell(&t, named("kp-enter"), NONE), "\x1bOM");
    // A modifier leaves the application spelling, which terminfo has no capability for.
    assert_eq!(spell(&t, named("kp-up"), CONTROL), "\x1b[1;5A");
    t.feed(b"\x1b>");
    assert_eq!(spell(&t, named("kp-1"), NONE), "1");
    assert_eq!(spell(&t, named("kp-enter"), NONE), "\r");
}

#[test]
fn f13_to_f24_are_the_shifted_function_keys_terminfo_names() {
    let t = term(4, 20, b"");
    assert_eq!(spell(&t, named("f13"), NONE), "\x1b[1;2P");
    assert_eq!(spell(&t, named("f24"), NONE), "\x1b[24;2~");
    assert_eq!(spell(&t, named("f13"), CONTROL), "\x1b[1;6P");
}

#[test]
fn modify_other_keys_level_2_spells_every_modified_key() {
    // Level 2 against xterm: `ModifyOtherKeys' in input.c, and the us-pc105 table in
    // xterm's modified-keys FAQ, whose Mode 2 column every expected value here is read
    // from. Before, only the literal keys were re-spelled, so `C-;' went out as a bare
    // ESC -- the ambiguity the level exists to remove.
    let t = term(4, 20, b"\x1b[>4;2m");
    assert_eq!(spell(&t, ch(';'), CONTROL), "\x1b[27;5;59~");
    assert_eq!(spell(&t, ch('.'), CONTROL), "\x1b[27;5;46~");
    assert_eq!(spell(&t, ch(','), CONTROL), "\x1b[27;5;44~");
    assert_eq!(spell(&t, ch('a'), CONTROL.with(META)), "\x1b[27;7;97~");
    // Control and Meta re-spell anything, keys with a control byte included.
    assert_eq!(spell(&t, ch('a'), CONTROL), "\x1b[27;5;97~");
    assert_eq!(spell(&t, ch('a'), META), "\x1b[27;3;97~");
    assert_eq!(spell(&t, ch('1'), CONTROL), "\x1b[27;5;49~");
    assert_eq!(spell(&t, ch(' '), CONTROL), "\x1b[27;5;32~");
    assert_eq!(spell(&t, ch('é'), CONTROL), "\x1b[27;5;233~");
    // Shift alone re-spells a letter, sent as its capital, and the space bar ...
    assert_eq!(spell(&t, ch('a'), SHIFT), "\x1b[27;2;65~");
    assert_eq!(spell(&t, ch('a'), CONTROL.with(SHIFT)), "\x1b[27;6;65~");
    assert_eq!(spell(&t, ch(' '), SHIFT), "\x1b[27;2;32~");
    // ... but not a key that shifting already made unambiguous, and nothing unmodified.
    assert_eq!(spell(&t, ch('!'), NONE), "!");
    assert_eq!(spell(&t, ch('é'), SHIFT), "É");
    assert_eq!(spell(&t, ch('a'), NONE), "a");
    // The literal keys are as they were, but for Shift+Tab, which is `ESC [ Z' unless
    // something besides Shift is held.
    assert_eq!(spell(&t, named("backtab"), SHIFT), "\x1b[Z");
    assert_eq!(spell(&t, named("backtab"), CONTROL.with(SHIFT)), "\x1b[27;6;9~");
    assert_eq!(spell(&t, named("return"), SHIFT), "\x1b[27;2;13~");
    assert_eq!(spell(&t, named("return"), CONTROL), "\x1b[27;5;13~");
    assert_eq!(spell(&t, named("tab"), CONTROL), "\x1b[27;5;9~");
    assert_eq!(spell(&t, named("escape"), META), "\x1b[27;3;27~");
    assert_eq!(spell(&t, named("return"), NONE), "\r");
    // Function and cursor keys are not the protocol's.
    assert_eq!(spell(&t, named("up"), CONTROL), "\x1b[1;5A");
    // A terminal frame's TAB and ESC are keys, not C-i and a Control chord.
    assert_eq!(spell(&t, ch('\t'), NONE), "\t");
    assert_eq!(spell(&t, Key::LooseEscape, NONE), "\x1b");
}

#[test]
fn modify_other_keys_level_1_leaves_what_already_means_something() {
    // Level 1 against xterm's `allowedCharModifiers' and the Mode 1 column of the same
    // table, with Meta following metaSendsEscape as xterm's manual says it does here.
    let t = term(4, 20, b"\x1b[>4;1m");
    // The task's pair: a chord with a control byte keeps it, one without is re-spelled.
    assert_eq!(spell(&t, ch('a'), CONTROL), "\x01");
    assert_eq!(spell(&t, ch(';'), CONTROL), "\x1b[27;5;59~");
    // X's table, not a five-bit mask: these have bytes and keep them.
    assert_eq!(spell(&t, ch('2'), CONTROL), "\0");
    assert_eq!(spell(&t, ch('3'), CONTROL), "\x1b");
    assert_eq!(spell(&t, ch('/'), CONTROL), "\x1f");
    assert_eq!(spell(&t, ch('a'), CONTROL.with(SHIFT)), "\x01");
    assert_eq!(spell(&t, ch('1'), CONTROL), "\x1b[27;5;49~");
    // Shift alone and Meta alone never re-spell.
    assert_eq!(spell(&t, ch('a'), SHIFT), "A");
    assert_eq!(spell(&t, ch('a'), META), "\x1ba");
    assert_eq!(spell(&t, ch('a'), META.with(CONTROL)), "\x1b\x01");
    // Where the rest re-spells, Meta counts in the parameter.
    assert_eq!(spell(&t, ch(';'), META.with(CONTROL)), "\x1b[27;7;59~");
    // Return and Tab under Shift or Control, but Meta takes itself and Control out
    // first, as xterm's `filterAltMeta' does.
    assert_eq!(spell(&t, named("return"), SHIFT), "\x1b[27;2;13~");
    assert_eq!(spell(&t, named("tab"), CONTROL), "\x1b[27;5;9~");
    assert_eq!(spell(&t, named("return"), META), "\x1b\r");
    assert_eq!(spell(&t, named("return"), META.with(CONTROL)), "\x1b\r");
    assert_eq!(spell(&t, named("return"), META.with(SHIFT)), "\x1b[27;2;13~");
    // Shift+Tab is `ESC [ Z' at this level whatever else is held.
    assert_eq!(spell(&t, named("backtab"), SHIFT), "\x1b[Z");
    assert_eq!(spell(&t, named("backtab"), CONTROL.with(SHIFT)), "\x1b[Z");
    // Escape only with Meta and Control or Shift; Backspace never.
    assert_eq!(spell(&t, named("escape"), SHIFT), "\x1b");
    assert_eq!(spell(&t, named("escape"), CONTROL.with(SHIFT)), "\x1b");
    assert_eq!(
        spell(&t, named("escape"), CONTROL.with(META)),
        "\x1b[27;7;27~"
    );
    assert_eq!(spell(&t, named("backspace"), CONTROL), "\x7f");
    // Super has no bit in xterm's parameter, and is dropped from a chord.
    assert_eq!(spell(&t, ch(';'), CONTROL.with(SUPER)), "\x1b[27;5;59~");
}

#[test]
fn kitty_disambiguate_follows_kittys_text_key_table() {
    // Bit 1 against the example table in kitty's keyboard protocol document. Its key is
    // `i', whose Control chords Emacs folds into TAB before any keymap sees them, so
    // those columns are checked on `c', where the table's rule is the same rule.
    let t = term(4, 20, b"\x1b[>1u");
    assert_eq!(spell(&t, ch('i'), NONE), "i");
    assert_eq!(spell(&t, ch('i'), SHIFT), "I");
    assert_eq!(spell(&t, ch('i'), META), "\x1b[105;3u");
    assert_eq!(spell(&t, ch('i'), META.with(SHIFT)), "\x1b[105;4u");
    assert_eq!(spell(&t, ch('c'), CONTROL), "\x1b[99;5u");
    assert_eq!(spell(&t, ch('c'), CONTROL.with(META)), "\x1b[99;7u");
    assert_eq!(spell(&t, ch('c'), CONTROL.with(SHIFT)), "\x1b[99;6u");
    assert_eq!(spell(&t, ch(' '), CONTROL), "\x1b[32;5u");
    // Escape is always an escape code; Return, Tab and Backspace stay bare unmodified,
    // so `reset' can still be typed after a crash.
    assert_eq!(spell(&t, named("escape"), NONE), "\x1b[27u");
    assert_eq!(spell(&t, named("escape"), META), "\x1b[27;3u");
    assert_eq!(spell(&t, named("return"), NONE), "\r");
    assert_eq!(spell(&t, named("tab"), NONE), "\t");
    assert_eq!(spell(&t, named("backspace"), NONE), "\x7f");
    assert_eq!(spell(&t, named("return"), SHIFT), "\x1b[13;2u");
    assert_eq!(spell(&t, named("backtab"), SHIFT), "\x1b[9;2u");
    // A terminal frame's ESC is half of every Meta chord and goes as the byte.
    assert_eq!(spell(&t, Key::LooseEscape, NONE), "\x1b");
    // Non-text keys leave SS3 behind, DECCKM or not, and F3 is not a CPR.
    let mut t = t;
    t.feed(b"\x1b[?1h");
    assert_eq!(spell(&t, named("up"), NONE), "\x1b[A");
    assert_eq!(spell(&t, named("f1"), NONE), "\x1b[P");
    assert_eq!(spell(&t, named("up"), CONTROL), "\x1b[1;5A");
    assert_eq!(spell(&t, named("f3"), NONE), "\x1b[13~");
    assert_eq!(spell(&t, named("f3"), SHIFT), "\x1b[13;2~");
    assert_eq!(spell(&t, named("f5"), NONE), "\x1b[15~");
    assert_eq!(spell(&t, named("next"), CONTROL), "\x1b[6;5~");
    // The keypad is keys of its own: text where the cap has text, codes where it does
    // not, and F13 is a key rather than a Shift+F1.
    assert_eq!(spell(&t, named("kp-1"), NONE), "1");
    assert_eq!(spell(&t, named("kp-1"), CONTROL), "\x1b[57400;5u");
    assert_eq!(spell(&t, named("kp-home"), NONE), "\x1b[57423u");
    assert_eq!(spell(&t, named("kp-enter"), NONE), "\x1b[57414u");
    assert_eq!(spell(&t, named("f13"), NONE), "\x1b[57376u");
    assert_eq!(spell(&t, named("pause"), NONE), "\x1b[57362u");
    assert_eq!(spell(&t, named("menu"), NONE), "\x1b[57363u");
    // Super and Hyper have a bit here and nowhere else.
    assert_eq!(spell(&t, ch('a'), SUPER), "\x1b[97;9u");
    assert_eq!(spell(&t, ch('a'), HYPER), "\x1b[97;17u");
}

#[test]
fn kitty_alternate_keys_report_the_shifted_key() {
    // Bit 4: the shifted key after a colon, and only with Shift held. kitty's document:
    // ctrl+shift+a is `CSI 97 : 65 ; 6 u', never `CSI 65'. The base-layout key is never
    // sent -- an Emacs event has no physical key to name -- which the protocol allows.
    let t = term(4, 20, b"\x1b[>5u");
    assert_eq!(spell(&t, ch('a'), CONTROL.with(SHIFT)), "\x1b[97:65;6u");
    assert_eq!(spell(&t, ch('a'), META.with(SHIFT)), "\x1b[97:65;4u");
    // No Shift, no shifted key.
    assert_eq!(spell(&t, ch('a'), CONTROL), "\x1b[97;5u");
    // Only on a key that was going to be an escape code anyway.
    assert_eq!(spell(&t, ch('a'), SHIFT), "A");
    // Not on a key that produces no text.
    assert_eq!(spell(&t, named("return"), SHIFT), "\x1b[13;2u");
    assert_eq!(spell(&t, named("up"), SHIFT), "\x1b[1;2A");
    // Without the bit, the same chord has no alternate.
    let t = term(4, 20, b"\x1b[>1u");
    assert_eq!(spell(&t, ch('a'), CONTROL.with(SHIFT)), "\x1b[97;6u");
}

#[test]
fn kitty_report_all_keys_sends_text_as_escape_codes() {
    // Bit 8: every key an escape code, Return, Tab and Backspace included.
    let t = term(4, 20, b"\x1b[>8u");
    assert_eq!(spell(&t, ch('a'), NONE), "\x1b[97u");
    assert_eq!(spell(&t, ch('a'), SHIFT), "\x1b[97;2u");
    assert_eq!(spell(&t, named("return"), NONE), "\x1b[13u");
    assert_eq!(spell(&t, named("tab"), NONE), "\x1b[9u");
    assert_eq!(spell(&t, named("backspace"), NONE), "\x1b[127u");
    assert_eq!(spell(&t, named("escape"), NONE), "\x1b[27u");
    assert_eq!(spell(&t, named("kp-1"), NONE), "\x1b[57400u");
    assert_eq!(spell(&t, named("up"), NONE), "\x1b[A");
    // And bit 16 beside it, which is the only way the text survives: kitty's document
    // gives shift+a as `CSI 97 ; 2 ; 65 u'.
    let t = term(4, 20, b"\x1b[>24u");
    assert_eq!(spell(&t, ch('a'), SHIFT), "\x1b[97;2;65u");
    assert_eq!(spell(&t, ch('a'), NONE), "\x1b[97;;97u");
    assert_eq!(spell(&t, ch('é'), NONE), "\x1b[233;;233u");
    assert_eq!(spell(&t, named("kp-1"), NONE), "\x1b[57400;;49u");
    // Control prevents text, and keys that produce none carry none: kitty's Enter with
    // every flag on is `CSI 13 u'.
    assert_eq!(spell(&t, ch('a'), CONTROL), "\x1b[97;5u");
    assert_eq!(spell(&t, named("return"), NONE), "\x1b[13u");
    assert_eq!(spell(&t, named("kp-enter"), NONE), "\x1b[57414u");
    // Everything at once.
    let t = term(4, 20, b"\x1b[>29u");
    assert_eq!(spell(&t, ch('a'), SHIFT), "\x1b[97:65;2;65u");
    assert_eq!(spell(&t, ch('a'), CONTROL.with(SHIFT)), "\x1b[97:65;6u");
}

#[test]
fn kitty_associated_text_alone_changes_nothing() {
    // Bit 16 is an enhancement to bit 8 and undefined without it. Under bit 1 alone every
    // key that produces text is sent as that text, and every escape code it does send is
    // for a chord Control or Meta has already taken the text from.
    let t = term(4, 20, b"\x1b[>17u");
    assert_eq!(spell(&t, ch('a'), NONE), "a");
    assert_eq!(spell(&t, ch('a'), SHIFT), "A");
    assert_eq!(spell(&t, ch('a'), META), "\x1b[97;3u");
}

#[test]
fn a_guessed_protocol_re_spells_only_the_literal_keys() {
    // `cooked-key-protocol-overrides' names a protocol for a program that never asked for
    // one, and a guess must go on meaning what it meant: Shift+Return and Shift+Tab
    // re-spelled, Escape and every Control chord untouched. Sending `ESC [ 27 u' to a
    // Claude Code on the strength of a process name would be the rubbish-in-the-input
    // case the negotiation exists to prevent.
    let t = term(4, 20, b"");
    let kitty = Some(Assumed::Kitty);
    assert_eq!(guessing(&t, named("return"), SHIFT, kitty).unwrap(), "\x1b[13;2u");
    assert_eq!(guessing(&t, named("backtab"), SHIFT, kitty).unwrap(), "\x1b[9;2u");
    assert_eq!(guessing(&t, named("escape"), NONE, kitty).unwrap(), "\x1b");
    assert_eq!(guessing(&t, ch('a'), CONTROL, kitty).unwrap(), "\x01");
    assert_eq!(guessing(&t, ch('x'), META, kitty).unwrap(), "\x1bx");

    // The modifyOtherKeys guess has no level and is read as level 2 over the same keys.
    let other = Some(Assumed::ModifyOther);
    assert_eq!(guessing(&t, named("return"), SHIFT, other).unwrap(), "\x1b[27;2;13~");
    assert_eq!(guessing(&t, named("backspace"), CONTROL, other).unwrap(), "\x1b[27;5;127~");
    assert_eq!(guessing(&t, ch('a'), CONTROL, other).unwrap(), "\x01");
    assert_eq!(guessing(&t, ch('x'), META, other).unwrap(), "\x1bx");

    // A real negotiation is believed over a guess about what a program probably wants.
    let t = term(4, 20, b"\x1b[>1u");
    assert_eq!(guessing(&t, named("escape"), NONE, other).unwrap(), "\x1b[27u");
}
