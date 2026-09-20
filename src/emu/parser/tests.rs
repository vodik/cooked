//! The parser's tests: upstream's, less the ones its changed interface retired, and
//! cooked's own for APC, the bounded strings, the OSC payload and text as bytes.

use super::*;
use crate::emu::utf8::{Decoder, Piece};

const OSC_BYTES: &[u8] = &[
    0x1B, 0x5D, // Begin OSC
    b'2', b';', b'j', b'w', b'i', b'l', b'm', b'@', b'j', b'w', b'i', b'l', b'm', b'-', b'd', b'e',
    b's', b'k', b':', b' ', b'~', b'/', b'c', b'o', b'd', b'e', b'/', b'a', b'l', b'a', b'c', b'r',
    b'i', b't', b't', b'y', 0x07, // End OSC
];

/// Records what the parser dispatched. Text is read through the same [`Decoder`] the
/// real performers use, and recorded a character at a time, so that the tests below
/// about UTF-8 cut across reads say what a performer would have drawn.
#[derive(Default)]
struct Dispatcher {
    dispatched: Vec<Sequence>,
    decoder: Decoder,
}

impl Dispatcher {
    /// Record S, after giving up on any sequence the text before it left unfinished.
    fn push(&mut self, s: Sequence) {
        self.dispatched
            .extend(self.decoder.flush().map(Sequence::Print));
        self.dispatched.push(s);
    }
}

#[derive(Debug, PartialEq, Eq)]
enum Sequence {
    Osc(u16, Option<Vec<u8>>, bool),
    Csi(Vec<Vec<u16>>, Vec<u8>, bool, char),
    Esc(Vec<u8>, bool, u8),
    DcsHook(Vec<Vec<u16>>, Vec<u8>, bool, char),
    DcsPut(u8),
    Apc(Vec<u8>),
    Print(char),
    Execute(u8),
    DcsUnhook,
}

impl Perform for Dispatcher {
    fn osc_dispatch(&mut self, code: OscCode, payload: Option<&[u8]>, bell_terminated: bool) {
        let payload = payload.map(<[u8]>::to_vec);
        self.push(Sequence::Osc(code.get(), payload, bell_terminated));
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], ignore: bool, c: char) {
        let params = params.iter().map(|subparam| subparam.to_vec()).collect();
        let intermediates = intermediates.to_vec();
        self.push(Sequence::Csi(params, intermediates, ignore, c));
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
        let intermediates = intermediates.to_vec();
        self.push(Sequence::Esc(intermediates, ignore, byte));
    }

    fn hook(&mut self, params: &Params, intermediates: &[u8], ignore: bool, c: char) {
        let params = params.iter().map(|subparam| subparam.to_vec()).collect();
        let intermediates = intermediates.to_vec();
        self.push(Sequence::DcsHook(params, intermediates, ignore, c));
    }

    fn put(&mut self, bytes: &[u8]) {
        self.dispatched
            .extend(bytes.iter().copied().map(Sequence::DcsPut));
    }

    fn apc_dispatch(&mut self, bytes: &[u8]) {
        self.push(Sequence::Apc(bytes.to_vec()));
    }

    fn unhook(&mut self) {
        self.push(Sequence::DcsUnhook);
    }

    fn print_bytes(&mut self, bytes: &[u8]) {
        let mut rest = bytes;
        while let Some(piece) = self.decoder.next(&mut rest) {
            match piece {
                Piece::Ascii(run) => {
                    let run = run
                        .as_bytes()
                        .iter()
                        .map(|&b| Sequence::Print(char::from(b)));
                    self.dispatched.extend(run);
                }
                Piece::Char(c) => self.dispatched.push(Sequence::Print(c)),
            }
        }
    }

    fn execute(&mut self, byte: u8) {
        self.push(Sequence::Execute(byte));
    }
}

/// The one OSC a parse of INPUT dispatched, as `(code, payload, bell_terminated)`.
fn one_osc(input: &[u8]) -> (u16, Option<Vec<u8>>, bool) {
    let mut dispatcher = Dispatcher::default();
    Parser::new().advance(&mut dispatcher, input);
    let mut oscs = dispatcher.dispatched.into_iter().filter_map(|s| match s {
        Sequence::Osc(code, payload, bell) => Some((code, payload, bell)),
        _ => None,
    });
    let osc = oscs.next().expect("an osc sequence");
    assert!(oscs.next().is_none(), "more than one osc sequence");
    osc
}

/// Whatever a parse of INPUT dispatched that was an OSC.
fn oscs(input: &[u8]) -> usize {
    let mut dispatcher = Dispatcher::default();
    Parser::new().advance(&mut dispatcher, input);
    let is_osc = |s: &&Sequence| matches!(s, Sequence::Osc(..));
    dispatcher.dispatched.iter().filter(is_osc).count()
}

#[test]
fn parse_osc() {
    let (code, payload, _) = one_osc(OSC_BYTES);
    assert_eq!(code, 2);
    assert_eq!(payload.unwrap(), &OSC_BYTES[4..(OSC_BYTES.len() - 1)]);
}

#[test]
fn osc_payload_keeps_its_semicolons() {
    // Upstream cut an OSC at every `;`, into at most sixteen parameters, and ran the
    // ones past the sixteenth together with the separators gone. Only the first is
    // the parser's to read.
    let uri = format!("https://example.com/{}", ";a=b".repeat(40));
    let input = format!("\x1b]8;id=x;{uri}\x1b\\");
    let (code, payload, _) = one_osc(input.as_bytes());
    assert_eq!(code, 8);
    assert_eq!(payload.unwrap(), format!("id=x;{uri}").as_bytes());
}

#[test]
fn an_osc_with_no_semicolon_has_no_payload_and_one_with_has_an_empty_one() {
    assert_eq!(one_osc(b"\x1b]112\x07"), (112, None, true));
    assert_eq!(one_osc(b"\x1b]112;\x07"), (112, Some(vec![]), true));
}

#[test]
fn an_osc_without_a_numeric_code_is_not_dispatched() {
    for input in [
        &b"\x1b]\x07"[..],
        b"\x1b];title\x07",
        b"\x1b]L;title\x07",
        b"\x1b]+8;;uri\x07",
        b"\x1b]99999;too big for a code\x07",
    ] {
        assert_eq!(oscs(input), 0, "{input:?}");
    }
}

#[test]
fn osc_bell_terminated() {
    assert!(one_osc(b"\x1b]11;ff/00/ff\x07").2);
}

#[test]
fn osc_c0_st_terminated() {
    assert!(!one_osc(b"\x1b]11;ff/00/ff\x1b\\").2);
}

#[test]
fn parse_osc_with_utf8_arguments() {
    const INPUT: &[u8] = &[
        0x0D, 0x1B, 0x5D, 0x32, 0x3B, 0x65, 0x63, 0x68, 0x6F, 0x20, 0x27, 0xC2, 0xAF, 0x5C, 0x5F,
        0x28, 0xE3, 0x83, 0x84, 0x29, 0x5F, 0x2F, 0xC2, 0xAF, 0x27, 0x20, 0x26, 0x26, 0x20, 0x73,
        0x6C, 0x65, 0x65, 0x70, 0x20, 0x31, 0x07,
    ];
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched[0], Sequence::Execute(b'\r'));
    let osc_data = INPUT[5..(INPUT.len() - 1)].into();
    assert_eq!(
        dispatcher.dispatched[1],
        Sequence::Osc(2, Some(osc_data), true)
    );
    assert_eq!(dispatcher.dispatched.len(), 2);
}

#[test]
fn osc_containing_string_terminator() {
    const INPUT: &[u8] = b"\x1b]2;\xe6\x9c\xab\x1b\\";
    let (_, payload, _) = one_osc(INPUT);
    assert_eq!(payload.unwrap(), &INPUT[4..(INPUT.len() - 2)]);
}

#[test]
fn an_overlong_osc_is_dropped_rather_than_truncated() {
    // Upstream let this `Vec` grow without limit, so an OSC nobody terminates was an
    // allocation the child controlled. Dropped rather than truncated because half a
    // payload is not a shorter payload: it is a different URI, or a base64 image that
    // fails to decode.
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, b"\x1b]52;s");
    parser.advance(&mut dispatcher, &vec![b'a'; MAX_OSC_RAW + 100]);
    parser.advance(&mut dispatcher, b"\x07");

    assert!(dispatcher.dispatched.is_empty());
}

#[test]
fn an_overlong_osc_does_not_poison_the_next_one() {
    let mut input = b"\x1b]52;s".to_vec();
    input.extend(vec![b'a'; MAX_OSC_RAW + 100]);
    input.extend(b"\x07\x1b]2;title\x07");
    assert_eq!(one_osc(&input), (2, Some(b"title".to_vec()), true));
}

#[test]
fn an_osc_abandoned_midway_does_not_poison_the_next_one() {
    // Abandoned by an ESC that starts something else, with the payload overflowed and
    // a code already read. The code lives in `State::OscString` and the overflow in a
    // `Payload` that every string begins afresh, so the next OSC inherits neither.
    let mut input = b"\x1b]52;s".to_vec();
    input.extend(vec![b'a'; MAX_OSC_RAW + 100]);
    input.extend(b"\x1b]2;title\x07");
    assert_eq!(one_osc(&input), (2, Some(b"title".to_vec()), true));
}

#[test]
fn an_osc_split_at_every_offset_dispatches_the_same_as_unsplit() {
    // `advance_osc_bulk` has two stops a bulk scan of a DCS or an APC does not: the
    // first `;`, which ends the code only while `code_end` is still `None`, and the
    // C0 bytes OSC drops silently rather than treats as a terminator. A split that
    // lands the boundary on either -- mid-run, right before it, or right after -- must
    // still dispatch exactly what one unbroken `advance` would.
    let mut input = b"\x1b]52;pa".to_vec();
    input.extend([0x01, 0x02, 0x08, 0x19, 0x1F]); // ignored C0 bytes, mid-payload
    input.extend(b";more;semicolons;stay;in;the;payload");
    input.push(0x07);

    let whole = {
        let mut dispatcher = Dispatcher::default();
        Parser::new().advance(&mut dispatcher, &input);
        dispatcher.dispatched
    };

    for at in 0..=input.len() {
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();
        parser.advance(&mut dispatcher, &input[..at]);
        parser.advance(&mut dispatcher, &input[at..]);
        assert_eq!(dispatcher.dispatched, whole, "split at {at}");
    }
}

#[test]
fn parse_csi_max_params() {
    // This will build a list of repeating '1;'s
    // The length is MAX_PARAMS - 1 because the last semicolon is interpreted
    // as an implicit zero, making the total number of parameters MAX_PARAMS
    let params = "1;".repeat(params::MAX_PARAMS - 1);
    let input = format!("\x1b[{}p", &params[..]).into_bytes();

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, &input);

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::Csi(params, _, ignore, _) => {
            assert_eq!(params.len(), params::MAX_PARAMS);
            assert!(!ignore);
        }
        _ => panic!("expected csi sequence"),
    }
}

#[test]
fn parse_csi_params_ignore_long_params() {
    // This will build a list of repeating '1;'s
    // The length is MAX_PARAMS because the last semicolon is interpreted
    // as an implicit zero, making the total number of parameters MAX_PARAMS + 1
    let params = "1;".repeat(params::MAX_PARAMS);
    let input = format!("\x1b[{}p", &params[..]).into_bytes();

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, &input);

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::Csi(params, _, ignore, _) => {
            assert_eq!(params.len(), params::MAX_PARAMS);
            assert!(ignore);
        }
        _ => panic!("expected csi sequence"),
    }
}

#[test]
fn parse_csi_params_trailing_semicolon() {
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, b"\x1b[4;m");

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::Csi(params, ..) => assert_eq!(params, &[[4], [0]]),
        _ => panic!("expected csi sequence"),
    }
}

#[test]
fn parse_csi_params_leading_semicolon() {
    // Create dispatcher and check state
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, b"\x1b[;4m");

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::Csi(params, ..) => assert_eq!(params, &[[0], [4]]),
        _ => panic!("expected csi sequence"),
    }
}

#[test]
fn parse_long_csi_param() {
    // The important part is the parameter, which is (i64::MAX + 1)
    const INPUT: &[u8] = b"\x1b[9223372036854775808m";
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::Csi(params, ..) => assert_eq!(params, &[[u16::MAX]]),
        _ => panic!("expected csi sequence"),
    }
}

#[test]
fn csi_reset() {
    const INPUT: &[u8] = b"\x1b[3;1\x1b[?1049h";
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::Csi(params, intermediates, ignore, _) => {
            assert_eq!(intermediates, b"?");
            assert_eq!(params, &[[1049]]);
            assert!(!ignore);
        }
        _ => panic!("expected csi sequence"),
    }
}

#[test]
fn csi_subparameters() {
    const INPUT: &[u8] = b"\x1b[38:2:255:0:255;1m";
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::Csi(params, intermediates, ignore, _) => {
            assert_eq!(params, &[vec![38, 2, 255, 0, 255], vec![1]]);
            assert_eq!(intermediates, &[]);
            assert!(!ignore);
        }
        _ => panic!("expected csi sequence"),
    }
}

#[test]
fn parse_dcs_max_params() {
    let params = "1;".repeat(params::MAX_PARAMS + 1);
    let input = format!("\x1bP{}p", &params[..]).into_bytes();
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, &input);

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::DcsHook(params, _, ignore, _) => {
            assert_eq!(params.len(), params::MAX_PARAMS);
            assert!(params.iter().all(|param| param == &[1]));
            assert!(ignore);
        }
        _ => panic!("expected dcs sequence"),
    }
}

#[test]
fn dcs_reset() {
    const INPUT: &[u8] = b"\x1b[3;1\x1bP1$tx\x9c";
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 3);
    match &dispatcher.dispatched[0] {
        Sequence::DcsHook(params, intermediates, ignore, _) => {
            assert_eq!(intermediates, b"$");
            assert_eq!(params, &[[1]]);
            assert!(!ignore);
        }
        _ => panic!("expected dcs sequence"),
    }
    assert_eq!(dispatcher.dispatched[1], Sequence::DcsPut(b'x'));
    assert_eq!(dispatcher.dispatched[2], Sequence::DcsUnhook);
}

#[test]
fn parse_dcs() {
    const INPUT: &[u8] = b"\x1bP0;1|17/ab\x9c";
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 7);
    match &dispatcher.dispatched[0] {
        Sequence::DcsHook(params, _, _, c) => {
            assert_eq!(params, &[[0], [1]]);
            assert_eq!(c, &'|');
        }
        _ => panic!("expected dcs sequence"),
    }
    for (i, byte) in b"17/ab".iter().enumerate() {
        assert_eq!(dispatcher.dispatched[1 + i], Sequence::DcsPut(*byte));
    }
    assert_eq!(dispatcher.dispatched[6], Sequence::DcsUnhook);
}

#[test]
fn intermediate_reset_on_dcs_exit() {
    const INPUT: &[u8] = b"\x1bP=1sZZZ\x1b+\x5c";
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 6);
    match &dispatcher.dispatched[5] {
        Sequence::Esc(intermediates, ..) => assert_eq!(intermediates, b"+"),
        _ => panic!("expected esc sequence"),
    }
}

#[test]
fn esc_reset() {
    const INPUT: &[u8] = b"\x1b[3;1\x1b(A";
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::Esc(intermediates, ignore, byte) => {
            assert_eq!(intermediates, b"(");
            assert_eq!(*byte, b'A');
            assert!(!ignore);
        }
        _ => panic!("expected esc sequence"),
    }
}

#[test]
fn esc_reset_intermediates() {
    const INPUT: &[u8] = b"\x1b[?2004l\x1b#8";
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 2);
    assert_eq!(
        dispatcher.dispatched[0],
        Sequence::Csi(vec![vec![2004]], vec![63], false, 'l')
    );
    assert_eq!(dispatcher.dispatched[1], Sequence::Esc(vec![35], false, 56));
}

#[test]
fn params_buffer_filled_with_subparam() {
    const INPUT: &[u8] = b"\x1b[::::::::::::::::::::::::::::::::x\x1b";
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 1);
    match &dispatcher.dispatched[0] {
        Sequence::Csi(params, intermediates, ignore, c) => {
            assert_eq!(intermediates, &[]);
            assert_eq!(params, &[[0; 32]]);
            assert_eq!(c, &'x');
            assert!(ignore);
        }
        _ => panic!("expected csi sequence"),
    }
}

#[test]
fn unicode() {
    const INPUT: &[u8] = b"\xF0\x9F\x8E\x89_\xF0\x9F\xA6\x80\xF0\x9F\xA6\x80_\xF0\x9F\x8E\x89";

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 6);
    assert_eq!(dispatcher.dispatched[0], Sequence::Print('🎉'));
    assert_eq!(dispatcher.dispatched[1], Sequence::Print('_'));
    assert_eq!(dispatcher.dispatched[2], Sequence::Print('🦀'));
    assert_eq!(dispatcher.dispatched[3], Sequence::Print('🦀'));
    assert_eq!(dispatcher.dispatched[4], Sequence::Print('_'));
    assert_eq!(dispatcher.dispatched[5], Sequence::Print('🎉'));
}

#[test]
fn invalid_utf8() {
    const INPUT: &[u8] = b"a\xEF\xBCb";

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 3);
    assert_eq!(dispatcher.dispatched[0], Sequence::Print('a'));
    assert_eq!(dispatcher.dispatched[1], Sequence::Print('�'));
    assert_eq!(dispatcher.dispatched[2], Sequence::Print('b'));
}

#[test]
fn partial_utf8() {
    const INPUT: &[u8] = b"\xF0\x9F\x9A\x80";

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, &INPUT[..1]);
    parser.advance(&mut dispatcher, &INPUT[1..2]);
    parser.advance(&mut dispatcher, &INPUT[2..3]);
    parser.advance(&mut dispatcher, &INPUT[3..]);

    assert_eq!(dispatcher.dispatched.len(), 1);
    assert_eq!(dispatcher.dispatched[0], Sequence::Print('🚀'));
}

#[test]
fn partial_utf8_separating_utf8() {
    // This is different from the `partial_utf8` test since it has a multi-byte UTF8
    // character after the partial UTF8 state, causing a partial byte to be present
    // in the `partial_utf8` buffer after the 2-byte codepoint.

    // "ĸ🎉"
    const INPUT: &[u8] = b"\xC4\xB8\xF0\x9F\x8E\x89";

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, &INPUT[..1]);
    parser.advance(&mut dispatcher, &INPUT[1..]);

    assert_eq!(dispatcher.dispatched.len(), 2);
    assert_eq!(dispatcher.dispatched[0], Sequence::Print('ĸ'));
    assert_eq!(dispatcher.dispatched[1], Sequence::Print('🎉'));
}

/// cooked's, not upstream's: the case the `valid_bytes - old_bytes` return dropped.
///
/// `"ĸaĸ"` cut after the first byte. Completing that codepoint fills the four-byte
/// staging buffer with `ĸ`, the `a`, and the lead byte of the second `ĸ` -- so the
/// buffer ends mid-character and lands in the `Err` arm with two characters' worth of
/// valid bytes in it. Upstream skipped the caller past all of them, and the `a` was
/// never printed. Found by `tests/delta_replay.rs`; see the comment in
/// `crate::emu::utf8`.
#[test]
fn partial_utf8_followed_by_more_text() {
    const INPUT: &[u8] = "ĸaĸ".as_bytes();

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, &INPUT[..1]);
    parser.advance(&mut dispatcher, &INPUT[1..]);

    assert_eq!(dispatcher.dispatched.len(), 3);
    assert_eq!(dispatcher.dispatched[0], Sequence::Print('ĸ'));
    assert_eq!(dispatcher.dispatched[1], Sequence::Print('a'));
    assert_eq!(dispatcher.dispatched[2], Sequence::Print('ĸ'));
}

/// A C1 control is dropped, and dropped the same whether or not a read cut it in half.
///
/// `\u{9b}` is `CSI`, and the two bytes it is written as in UTF-8 are as likely to
/// straddle a read as any other pair. Upstream executed them arriving together and
/// printed them arriving apart. See `crate::emu::utf8`.
#[test]
fn a_c1_control_is_dropped_whole_or_split() {
    const INPUT: &[u8] = "a\u{9b}b".as_bytes();

    for cut in 0..=INPUT.len() {
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, &INPUT[..cut]);
        parser.advance(&mut dispatcher, &INPUT[cut..]);

        assert_eq!(
            dispatcher.dispatched,
            [Sequence::Print('a'), Sequence::Print('b')],
            "cut at {cut}"
        );
    }
}

/// A sequence that ASCII interrupts is one replacement character, wherever the read
/// was cut: the bytes after it cannot complete it, so it is invalid and not partial.
#[test]
fn utf8_cut_short_by_ascii_is_one_replacement() {
    const INPUT: &[u8] = b"\xE2\x82a\xE2\x82\x1b[m";

    for cut in 0..=INPUT.len() {
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, &INPUT[..cut]);
        parser.advance(&mut dispatcher, &INPUT[cut..]);

        assert_eq!(
            dispatcher.dispatched,
            [
                Sequence::Print('\u{fffd}'),
                Sequence::Print('a'),
                Sequence::Print('\u{fffd}'),
                Sequence::Csi(vec![vec![0]], vec![], false, 'm'),
            ],
            "cut at {cut}"
        );
    }
}

#[test]
fn partial_invalid_utf8() {
    const INPUT: &[u8] = b"a\xEF\xBCb";

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, &INPUT[..1]);
    parser.advance(&mut dispatcher, &INPUT[1..2]);
    parser.advance(&mut dispatcher, &INPUT[2..3]);
    parser.advance(&mut dispatcher, &INPUT[3..]);

    assert_eq!(dispatcher.dispatched.len(), 3);
    assert_eq!(dispatcher.dispatched[0], Sequence::Print('a'));
    assert_eq!(dispatcher.dispatched[1], Sequence::Print('�'));
    assert_eq!(dispatcher.dispatched[2], Sequence::Print('b'));
}

#[test]
fn partial_invalid_utf8_split() {
    const INPUT: &[u8] = b"\xE4\xBF\x99\xB5";

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, &INPUT[..2]);
    parser.advance(&mut dispatcher, &INPUT[2..]);

    assert_eq!(dispatcher.dispatched[0], Sequence::Print('俙'));
    assert_eq!(dispatcher.dispatched[1], Sequence::Print('�'));
}

#[test]
fn partial_utf8_into_esc() {
    const INPUT: &[u8] = b"\xD8\x1b012";

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 4);
    assert_eq!(dispatcher.dispatched[0], Sequence::Print('�'));
    assert_eq!(
        dispatcher.dispatched[1],
        Sequence::Esc(Vec::new(), false, b'0')
    );
    assert_eq!(dispatcher.dispatched[2], Sequence::Print('1'));
    assert_eq!(dispatcher.dispatched[3], Sequence::Print('2'));
}

/// C0 controls are executed, DEL is dropped, and a stray byte from the C1 range is as
/// invalid as any other stray byte; see `crate::emu::utf8`.
#[test]
fn c0_del_and_stray_high_bytes() {
    const INPUT: &[u8] = b"\x00\x1f\x7f\x80\x9b\x9fa";

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(
        dispatcher.dispatched,
        [
            Sequence::Execute(0),
            Sequence::Execute(31),
            Sequence::Print('\u{fffd}'),
            Sequence::Print('\u{fffd}'),
            Sequence::Print('\u{fffd}'),
            Sequence::Print('a'),
        ]
    );
}

#[test]
fn execute_anywhere() {
    const INPUT: &[u8] = b"\x18\x1a";

    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();

    parser.advance(&mut dispatcher, INPUT);

    assert_eq!(dispatcher.dispatched.len(), 2);
    assert_eq!(dispatcher.dispatched[0], Sequence::Execute(0x18));
    assert_eq!(dispatcher.dispatched[1], Sequence::Execute(0x1A));
}

// --- cooked's additions ------------------------------------------------
//
// Everything above this line is upstream's. These cover the two capabilities this
// parser was vendored to add: APC delivery, and string payloads in slices.

/// Collects `put` call *shapes*, which `Dispatcher` deliberately flattens away.
#[derive(Default)]
struct PutShape {
    calls: Vec<Vec<u8>>,
}

impl Perform for PutShape {
    fn put(&mut self, bytes: &[u8]) {
        self.calls.push(bytes.to_vec());
    }
}

fn apc_payloads(input: &[u8]) -> Vec<Vec<u8>> {
    let mut dispatcher = Dispatcher::default();
    Parser::new().advance(&mut dispatcher, input);
    dispatcher
        .dispatched
        .into_iter()
        .filter_map(|seq| match seq {
            Sequence::Apc(bytes) => Some(bytes),
            _ => None,
        })
        .collect()
}

#[test]
fn apc_payload_arrives_whole() {
    assert_eq!(
        apc_payloads(b"\x1b_Gf=100,a=T,m=1;SGVsbG8\x1b\\"),
        vec![b"Gf=100,a=T,m=1;SGVsbG8".to_vec()]
    );
}

#[test]
fn apc_accepts_either_spelling_of_the_terminator() {
    assert_eq!(apc_payloads(b"\x1b_Gx\x1b\\"), vec![b"Gx".to_vec()]);
    assert_eq!(apc_payloads(b"\x1b_Gx\x9c"), vec![b"Gx".to_vec()]);
}

#[test]
fn a_bel_inside_an_apc_is_payload() {
    // Unlike OSC, where BEL is xterm's terminator shorthand. An APC payload may be
    // arbitrary bytes, so ending on one would truncate a legitimate transmission.
    assert_eq!(apc_payloads(b"\x1b_G\x07x\x1b\\"), vec![b"G\x07x".to_vec()]);
}

#[test]
fn apc_survives_being_split_across_advances() {
    let mut dispatcher = Dispatcher::default();
    let mut parser = Parser::new();
    for chunk in [&b"\x1b_Gf=1"[..], b"00,a=", b"T;AAA", b"A\x1b\\"] {
        parser.advance(&mut dispatcher, chunk);
    }
    let payloads: Vec<_> = dispatcher
        .dispatched
        .into_iter()
        .filter_map(|seq| match seq {
            Sequence::Apc(bytes) => Some(bytes),
            _ => None,
        })
        .collect();
    assert_eq!(payloads, vec![b"Gf=100,a=T;AAAA".to_vec()]);
}

#[test]
fn an_overlong_apc_is_dropped_rather_than_truncated() {
    let mut input = Vec::from(&b"\x1b_G"[..]);
    input.extend(std::iter::repeat_n(b'A', MAX_APC_RAW + 1));
    input.extend_from_slice(b"\x1b\\");
    assert!(apc_payloads(&input).is_empty());
}

#[test]
fn an_overlong_apc_does_not_poison_the_next_one() {
    let mut input = Vec::from(&b"\x1b_G"[..]);
    input.extend(std::iter::repeat_n(b'A', MAX_APC_RAW + 1));
    input.extend_from_slice(b"\x1b\\\x1b_Gok\x1b\\");
    assert_eq!(apc_payloads(&input), vec![b"Gok".to_vec()]);
}

#[test]
fn apc_is_abandoned_on_cancel() {
    assert!(apc_payloads(b"\x1b_Gpartial\x18").is_empty());
}

#[test]
fn apc_does_not_swallow_what_follows_it() {
    let mut dispatcher = Dispatcher::default();
    Parser::new().advance(&mut dispatcher, b"\x1b_Gx\x1b\\\x1b[31m");
    assert_eq!(dispatcher.dispatched[0], Sequence::Apc(b"Gx".to_vec()));
    assert_eq!(
        dispatcher.dispatched.last().unwrap(),
        &Sequence::Csi(vec![vec![31]], vec![], false, 'm')
    );
}

#[test]
fn sos_and_pm_are_still_discarded() {
    assert!(apc_payloads(b"\x1bXsos\x1b\\").is_empty());
    assert!(apc_payloads(b"\x1b^pm\x1b\\").is_empty());
}

#[test]
fn a_dcs_payload_arrives_in_one_call_not_one_per_byte() {
    let mut shape = PutShape::default();
    Parser::new().advance(&mut shape, b"\x1bPq#0;2;0;0;0#0~~@@vv@@~~$\x1b\\");
    assert_eq!(shape.calls, vec![b"#0;2;0;0;0#0~~@@vv@@~~$".to_vec()]);
}

#[test]
fn a_dcs_payload_split_across_advances_is_cut_at_the_seam() {
    // No guarantee is made about where the runs are cut, only that they concatenate
    // to the payload -- which is what `Perform::put` promises its callers.
    let mut shape = PutShape::default();
    let mut parser = Parser::new();
    for chunk in [&b"\x1bPq#0;2"[..], b";0;0;0", b"$\x1b\\"] {
        parser.advance(&mut shape, chunk);
    }
    assert_eq!(shape.calls.concat(), b"#0;2;0;0;0$".to_vec());
    assert!(shape.calls.len() > 1, "{:?}", shape.calls);
}
