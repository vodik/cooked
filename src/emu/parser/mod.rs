//! The VT parser state machine, forked from `vte` 0.15.0.
//!
//! Upstream is <https://github.com/alacritty/vte>, by Joe Wilm and Christian Duerr,
//! dual-licensed Apache-2.0 OR MIT; both licences sit beside this file. It is
//! implemented according to [Paul Williams' ANSI parser state machine].
//!
//! **This is cooked's parser now, and is not kept in step with upstream.** It began as a
//! vendored copy held close to the original so that a re-sync would be a diff, and the
//! differences below outgrew that bargain: each is a place where `vte`'s interface was
//! the wrong shape for what sits behind it here, and staying faithful meant working
//! around the parser from the outside. The escape-sequence states -- CSI, DCS, ESC and
//! their parameters -- are still upstream's and still read like it. Ground, the strings
//! and the [`Perform`] trait are not.
//!
//! * **APC is delivered.** Upstream discards it along with SOS and PM, and APC is where
//!   the kitty graphics protocol lives. [`Perform::apc_dispatch`] receives a payload
//!   whole.
//! * **DCS payloads arrive as slices**, through [`Perform::put`], and both string states
//!   are scanned in bulk. Upstream calls `put` per byte, which is the wrong shape for a
//!   sixel image megabytes long.
//! * **An OSC is a code and a payload**, not a list of parameters. Upstream cut the
//!   string at every `;`, into at most sixteen pieces, and everything downstream whose
//!   payload could contain one glued it back together. See [`Perform::osc_dispatch`].
//! * **OSC and APC payloads are bounded**, by [`MAX_OSC_RAW`] and [`MAX_APC_RAW`], and
//!   one that outgrows its bound is dropped rather than truncated.
//! * **Text is bytes.** Ground hands over every run of bytes from `0x20` up as it
//!   arrived, through [`Perform::print_bytes`], and knows nothing about UTF-8. Upstream
//!   validated it, held back a sequence a read had cut short, and called `print` once a
//!   character -- and had two bugs in resuming a split code point, both found by
//!   `tests/delta_replay.rs`. Reading the bytes is [`crate::emu::utf8`]'s, where it is
//!   done once and a read may cut the stream anywhere without changing the answer.
//! * **There are no C1 controls**, and DEL is text for the decoder to drop. See
//!   [`Parser::advance_ground`].
//! * The `no_std` machinery and the optional `ansi` module are gone: cooked is always
//!   `std`, and it has its own interpreter.
//!
//! # Differences from the original state machine description
//!
//! * UTF-8 support for input
//! * OSC strings can be terminated by 0x07
//! * Only supports 7-bit codes
//!
//! [Paul Williams' ANSI parser state machine]: https://vt100.net/emu/dec_ansi_parser
#![deny(clippy::all, clippy::if_not_else, clippy::enum_glob_use)]
use core::str;

mod params;

pub(crate) use params::{Params, ParamsIter};

const MAX_INTERMEDIATES: usize = 2;

/// Largest APC payload collected before the sequence is abandoned.
///
/// Generous, because it has to hold one kitty graphics transmission: chunked transfers
/// cap themselves at 4096 bytes a piece, but an unchunked `t=d` is one APC carrying the
/// whole base64 image. Consumers cap again on what the payload *means*; this is only the
/// bound on what the parser will hold on their behalf.
pub(crate) const MAX_APC_RAW: usize = 8 << 20;
/// Largest OSC payload the parser will collect before giving up on the string.
///
/// Upstream used its own 1024 to size a `no_std` array; the `Vec` that replaced it had no
/// bound at all, which made an OSC nobody terminates an unbounded allocation driven by
/// the child. Everything conventional -- a title, a working directory, a hyperlink -- is
/// a few hundred bytes, but iTerm2's `OSC 1337` carries a whole base64 image, so the
/// bound has to clear that rather than sit near the conventional traffic.
///
/// Consumers cap again on what a payload *means* -- see `OSC_PAYLOAD_LIMIT`, which is
/// far tighter for every code that is not carrying a picture. This is only the bound on
/// what the parser will hold on their behalf.
pub(crate) const MAX_OSC_RAW: usize = 8 << 20;

/// Parser for raw _VTE_ protocol which delegates actions to a [`Perform`]
///
/// [`Perform`]: trait.Perform.html
///
#[derive(Default)]
pub(crate) struct Parser {
    state: State,
    intermediates: [u8; MAX_INTERMEDIATES],
    intermediate_idx: usize,
    params: Params,
    param: u16,
    /// The payload of whichever string is being collected, an OSC's or an APC's. One,
    /// because there is only ever one string; see [`Payload`].
    string: Payload,
    ignoring: bool,
}

impl Parser {
    /// Create a new Parser
    pub(crate) fn new() -> Parser {
        Default::default()
    }
}

impl Parser {
    #[inline]
    fn params(&self) -> &Params {
        &self.params
    }

    #[inline]
    fn intermediates(&self) -> &[u8] {
        &self.intermediates[..self.intermediate_idx]
    }

    /// Advance the parser state.
    ///
    /// Requires a [`Perform`] implementation to handle the triggered actions.
    ///
    /// [`Perform`]: trait.Perform.html
    #[inline]
    pub(crate) fn advance<P: Perform>(&mut self, performer: &mut P, bytes: &[u8]) {
        let mut i = 0;

        while i != bytes.len() {
            match self.state {
                State::Ground => i += self.advance_ground(performer, &bytes[i..]),
                // The two string states run in bulk, so that a sixel or a kitty image
                // costs a scan and one call rather than a state dispatch per byte.
                State::DcsPassthrough => i += self.advance_dcs_bulk(performer, &bytes[i..]),
                State::ApcString => i += self.advance_apc_bulk(performer, &bytes[i..]),
                _ => {
                    // Inlining it results in worse codegen.
                    let byte = bytes[i];
                    self.change_state(performer, byte);
                    i += 1;
                }
            }
        }
    }

    /// Hand over the longest run of DCS payload before anything needing a decision.
    ///
    /// The passing set is upstream's `0x00..=0x17 | 0x19 | 0x1C..=0x7E`; the first byte
    /// outside it — a terminator, a cancel, a `0x7F`, a high byte upstream drops — is
    /// handed back to the byte path so there is exactly one implementation of what those
    /// mean.
    #[inline]
    fn advance_dcs_bulk<P: Perform>(&mut self, performer: &mut P, bytes: &[u8]) -> usize {
        let end = bytes
            .iter()
            .position(|b| !matches!(b, 0x00..=0x17 | 0x19 | 0x1C..=0x7E))
            .unwrap_or(bytes.len());
        if end != 0 {
            performer.put(&bytes[..end]);
        }
        if end == bytes.len() {
            return end;
        }
        self.change_state(performer, bytes[end]);
        end + 1
    }

    /// Collect the longest run of APC payload before anything needing a decision.
    ///
    /// Everything but `CAN`, `SUB`, `ESC` and 8-bit `ST` is payload — see
    /// [`Self::advance_apc_string`], which the odd byte out is handed to.
    #[inline]
    fn advance_apc_bulk<P: Perform>(&mut self, performer: &mut P, bytes: &[u8]) -> usize {
        let end = bytes
            .iter()
            .position(|b| matches!(b, 0x18 | 0x1A | 0x1B | 0x9C))
            .unwrap_or(bytes.len());
        self.string.extend(&bytes[..end]);
        if end == bytes.len() {
            return end;
        }
        self.change_state(performer, bytes[end]);
        end + 1
    }

    /// Partially advance the parser state.
    ///
    /// This is equivalent to [`Self::advance`], but stops when
    /// [`Perform::terminated`] is true after reading a byte.
    ///
    /// Returns the number of bytes read before termination.
    ///
    /// See [`Self::advance`] for more details.
    ///
    /// Upstream added this for synchronized updates; cooked handles those through
    /// `Modes::sync_until` and uses it instead to stop at a picture that needs decoding,
    /// so the reader can decode with the terminal unlocked. See `term::Decode`. The two
    /// bulk string states are taken here as in [`Self::advance`], which upstream lacks.
    #[inline]
    #[must_use = "Returned value should be used to processs the remaining bytes"]
    pub(crate) fn advance_until_terminated<P: Perform>(
        &mut self,
        performer: &mut P,
        bytes: &[u8],
    ) -> usize {
        let mut i = 0;

        while i != bytes.len() && !performer.terminated() {
            match self.state {
                State::Ground => i += self.advance_ground(performer, &bytes[i..]),
                State::DcsPassthrough => i += self.advance_dcs_bulk(performer, &bytes[i..]),
                State::ApcString => i += self.advance_apc_bulk(performer, &bytes[i..]),
                _ => {
                    // Inlining it results in worse codegen.
                    let byte = bytes[i];
                    self.change_state(performer, byte);
                    i += 1;
                }
            }
        }

        i
    }

    #[inline(always)]
    fn change_state<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match self.state {
            State::CsiEntry => self.advance_csi_entry(performer, byte),
            State::CsiIgnore => self.advance_csi_ignore(performer, byte),
            State::CsiIntermediate => self.advance_csi_intermediate(performer, byte),
            State::CsiParam => self.advance_csi_param(performer, byte),
            State::DcsEntry => self.advance_dcs_entry(performer, byte),
            State::DcsIgnore => self.anywhere(performer, byte),
            State::DcsIntermediate => self.advance_dcs_intermediate(performer, byte),
            State::DcsParam => self.advance_dcs_param(performer, byte),
            State::DcsPassthrough => self.advance_dcs_passthrough(performer, byte),
            State::Escape => self.advance_esc(performer, byte),
            State::EscapeIntermediate => self.advance_esc_intermediate(performer, byte),
            State::OscString { code_end } => self.advance_osc_string(performer, code_end, byte),
            State::ApcString => self.advance_apc_string(performer, byte),
            State::SosPmApcString => self.anywhere(performer, byte),
            State::Ground => unreachable!(),
        }
    }

    #[inline(always)]
    fn advance_csi_entry<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x1F => performer.execute(byte),
            0x20..=0x2F => {
                self.action_collect(byte);
                self.state = State::CsiIntermediate
            }
            0x30..=0x39 => {
                self.action_paramnext(byte);
                self.state = State::CsiParam
            }
            0x3A => {
                self.action_subparam();
                self.state = State::CsiParam
            }
            0x3B => {
                self.action_param();
                self.state = State::CsiParam
            }
            0x3C..=0x3F => {
                self.action_collect(byte);
                self.state = State::CsiParam
            }
            0x40..=0x7E => self.action_csi_dispatch(performer, byte),
            _ => self.anywhere(performer, byte),
        }
    }

    #[inline(always)]
    fn advance_csi_ignore<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x1F => performer.execute(byte),
            0x20..=0x3F => (),
            0x40..=0x7E => self.state = State::Ground,
            0x7F => (),
            _ => self.anywhere(performer, byte),
        }
    }

    #[inline(always)]
    fn advance_csi_intermediate<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x1F => performer.execute(byte),
            0x20..=0x2F => self.action_collect(byte),
            0x30..=0x3F => self.state = State::CsiIgnore,
            0x40..=0x7E => self.action_csi_dispatch(performer, byte),
            _ => self.anywhere(performer, byte),
        }
    }

    #[inline(always)]
    fn advance_csi_param<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x1F => performer.execute(byte),
            0x20..=0x2F => {
                self.action_collect(byte);
                self.state = State::CsiIntermediate
            }
            0x30..=0x39 => self.action_paramnext(byte),
            0x3A => self.action_subparam(),
            0x3B => self.action_param(),
            0x3C..=0x3F => self.state = State::CsiIgnore,
            0x40..=0x7E => self.action_csi_dispatch(performer, byte),
            0x7F => (),
            _ => self.anywhere(performer, byte),
        }
    }

    #[inline(always)]
    fn advance_dcs_entry<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x1F => (),
            0x20..=0x2F => {
                self.action_collect(byte);
                self.state = State::DcsIntermediate
            }
            0x30..=0x39 => {
                self.action_paramnext(byte);
                self.state = State::DcsParam
            }
            0x3A => {
                self.action_subparam();
                self.state = State::DcsParam
            }
            0x3B => {
                self.action_param();
                self.state = State::DcsParam
            }
            0x3C..=0x3F => {
                self.action_collect(byte);
                self.state = State::DcsParam
            }
            0x40..=0x7E => self.action_hook(performer, byte),
            0x7F => (),
            _ => self.anywhere(performer, byte),
        }
    }

    #[inline(always)]
    fn advance_dcs_intermediate<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x1F => (),
            0x20..=0x2F => self.action_collect(byte),
            0x30..=0x3F => self.state = State::DcsIgnore,
            0x40..=0x7E => self.action_hook(performer, byte),
            0x7F => (),
            _ => self.anywhere(performer, byte),
        }
    }

    #[inline(always)]
    fn advance_dcs_param<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x1F => (),
            0x20..=0x2F => {
                self.action_collect(byte);
                self.state = State::DcsIntermediate
            }
            0x30..=0x39 => self.action_paramnext(byte),
            0x3A => self.action_subparam(),
            0x3B => self.action_param(),
            0x3C..=0x3F => self.state = State::DcsIgnore,
            0x40..=0x7E => self.action_hook(performer, byte),
            0x7F => (),
            _ => self.anywhere(performer, byte),
        }
    }

    #[inline(always)]
    fn advance_dcs_passthrough<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x7E => performer.put(core::slice::from_ref(&byte)),
            0x18 | 0x1A => {
                performer.unhook();
                performer.execute(byte);
                self.state = State::Ground
            }
            0x1B => {
                performer.unhook();
                self.reset_params();
                self.state = State::Escape
            }
            0x7F => (),
            0x9C => {
                performer.unhook();
                self.state = State::Ground
            }
            _ => (),
        }
    }

    #[inline(always)]
    fn advance_esc<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x1F => performer.execute(byte),
            0x20..=0x2F => {
                self.action_collect(byte);
                self.state = State::EscapeIntermediate
            }
            // The six introducers that start a string or a control sequence, listed
            // first so that everything else in 0x30..=0x7E is one dispatch arm. Written
            // out in upstream's order it was six specials interleaved with five
            // byte-identical copies of that arm.
            0x50 => {
                self.reset_params();
                self.state = State::DcsEntry
            }
            0x58 | 0x5E => self.state = State::SosPmApcString,
            0x5B => {
                self.reset_params();
                self.state = State::CsiEntry
            }
            0x5D => {
                self.string.begin(MAX_OSC_RAW);
                self.state = State::OscString { code_end: None }
            }
            0x5F => {
                self.string.begin(MAX_APC_RAW);
                self.state = State::ApcString
            }
            0x30..=0x7E => {
                performer.esc_dispatch(self.intermediates(), self.ignoring, byte);
                self.state = State::Ground
            }
            // Anywhere.
            0x18 | 0x1A => {
                performer.execute(byte);
                self.state = State::Ground
            }
            0x1B => (),
            _ => (),
        }
    }

    #[inline(always)]
    fn advance_esc_intermediate<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x17 | 0x19 | 0x1C..=0x1F => performer.execute(byte),
            0x20..=0x2F => self.action_collect(byte),
            0x30..=0x7E => {
                performer.esc_dispatch(self.intermediates(), self.ignoring, byte);
                self.state = State::Ground
            }
            0x7F => (),
            _ => self.anywhere(performer, byte),
        }
    }

    #[inline(always)]
    fn advance_osc_string<P: Perform>(
        &mut self,
        performer: &mut P,
        code_end: Option<usize>,
        byte: u8,
    ) {
        match byte {
            0x00..=0x06 | 0x08..=0x17 | 0x19 | 0x1C..=0x1F => (),
            0x07 => {
                self.osc_dispatch(performer, code_end, byte);
                self.state = State::Ground
            }
            0x18 | 0x1A => {
                self.osc_dispatch(performer, code_end, byte);
                performer.execute(byte);
                self.state = State::Ground
            }
            0x1B => {
                self.osc_dispatch(performer, code_end, byte);
                self.reset_params();
                self.state = State::Escape
            }
            // The `;` after the code is the only one the parser reads. It is not stored,
            // and every later one is payload.
            0x3B if code_end.is_none() => {
                let code_end = Some(self.string.len());
                self.state = State::OscString { code_end }
            }
            _ => self.string.extend(&[byte]),
        }
    }

    /// Collect an APC payload, byte at a time.
    ///
    /// Terminated by ST in either spelling — `ESC \\`, handled by handing the escape on
    /// exactly as [`Self::advance_osc_string`] does, or the 8-bit `0x9C`. Not by BEL:
    /// xterm's BEL shorthand is an OSC convention, and a `0x07` inside a payload that
    /// may be arbitrary bytes is payload.
    #[inline(always)]
    fn advance_apc_string<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x18 | 0x1A => {
                // Cancelled mid-payload: abandon it rather than dispatch a fragment.
                performer.execute(byte);
                self.state = State::Ground
            }
            0x1B => {
                self.apc_end(performer);
                self.reset_params();
                self.state = State::Escape
            }
            0x9C => {
                self.apc_end(performer);
                self.state = State::Ground
            }
            _ => self.string.extend(&[byte]),
        }
    }

    /// Hand a finished APC over, unless it outgrew [`MAX_APC_RAW`]; see
    /// [`Payload::finish`].
    fn apc_end<P: Perform>(&mut self, performer: &mut P) {
        if let Some(payload) = self.string.finish() {
            performer.apc_dispatch(payload);
        }
    }

    #[inline(always)]
    fn anywhere<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x18 | 0x1A => {
                performer.execute(byte);
                self.state = State::Ground
            }
            0x1B => {
                self.reset_params();
                self.state = State::Escape
            }
            _ => (),
        }
    }

    #[inline]
    fn action_csi_dispatch<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        if self.params.is_full() {
            self.ignoring = true;
        } else {
            self.params.push(self.param);
        }
        performer.csi_dispatch(
            self.params(),
            self.intermediates(),
            self.ignoring,
            byte as char,
        );

        self.state = State::Ground
    }

    #[inline]
    fn action_hook<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        if self.params.is_full() {
            self.ignoring = true;
        } else {
            self.params.push(self.param);
        }
        performer.hook(
            self.params(),
            self.intermediates(),
            self.ignoring,
            byte as char,
        );
        self.state = State::DcsPassthrough;
    }

    #[inline]
    fn action_collect(&mut self, byte: u8) {
        if self.intermediate_idx == MAX_INTERMEDIATES {
            self.ignoring = true;
        } else {
            self.intermediates[self.intermediate_idx] = byte;
            self.intermediate_idx += 1;
        }
    }

    /// Advance to the next subparameter.
    #[inline]
    fn action_subparam(&mut self) {
        if self.params.is_full() {
            self.ignoring = true;
        } else {
            self.params.extend(self.param);
            self.param = 0;
        }
    }

    /// Advance to the next parameter.
    #[inline]
    fn action_param(&mut self) {
        if self.params.is_full() {
            self.ignoring = true;
        } else {
            self.params.push(self.param);
            self.param = 0;
        }
    }

    /// Advance inside the parameter without terminating it.
    #[inline]
    fn action_paramnext(&mut self, byte: u8) {
        if self.params.is_full() {
            self.ignoring = true;
        } else {
            // Continue collecting bytes into param.
            self.param = self.param.saturating_mul(10);
            self.param = self.param.saturating_add((byte - b'0') as u16);
        }
    }

    /// Reset escape sequence parameters and intermediates.
    #[inline]
    fn reset_params(&mut self) {
        self.intermediate_idx = 0;
        self.ignoring = false;
        self.param = 0;

        self.params.clear();
    }

    /// Hand the collected OSC to the performer: its code, and the rest of it untouched.
    ///
    /// Upstream split the whole string at every `;`, into at most sixteen parameters, and
    /// every consumer whose payload may contain one -- a URI, a path, a title, a command
    /// line, iTerm2's `File=` arguments -- had to glue it back together. What separates
    /// the fields of a payload is that payload's business: OSC 8 has exactly two, OSC 133
    /// has as many options as the shell sent, and OSC 66 separates its metadata with
    /// colons. The one thing every OSC shares is `CODE ;`, so that is all this reads.
    ///
    /// An OSC whose code is not a number that fits is dispatched nowhere. Nothing has
    /// ever been specified with one, and both performers dropped them already. Nor is one
    /// that outgrew [`MAX_OSC_RAW`]; see [`Payload::finish`].
    #[inline]
    fn osc_dispatch<P: Perform>(&self, performer: &mut P, code_end: Option<usize>, byte: u8) {
        let Some(string) = self.string.finish() else {
            return;
        };
        let (code, payload) = match code_end {
            Some(end) => (&string[..end], Some(&string[end..])),
            None => (string, None),
        };
        if let Some(code) = OscCode::parse(code) {
            performer.osc_dispatch(code, payload, byte == 0x07);
        }
    }

    /// Advance the parser state from ground by one step: a run of text, or one control.
    ///
    /// Text is every byte from `0x20` up, and it is handed over as it arrived. Upstream
    /// searched for the next `ESC`, validated everything before it as UTF-8, held back a
    /// sequence the read had cut short, and walked the result a character at a time
    /// looking for controls -- after which the performer decoded it all again to draw
    /// it. None of that is grammar. The escape sequences are seven-bit and the same
    /// whatever the eighth bit means, so what a high byte *is* belongs to whoever draws
    /// text, and reading it once, there, is both less work and one fewer place that has
    /// to agree with another about ill-formed input. See [`crate::emu::utf8`].
    ///
    /// DEL is text by this rule, and is dropped by the decoder along with the C1
    /// controls, which as far as this parser is concerned do not exist.
    #[inline]
    fn advance_ground<P: Perform>(&mut self, performer: &mut P, bytes: &[u8]) -> usize {
        let text = text_len(bytes);
        if text > 0 {
            performer.print_bytes(&bytes[..text]);
            return text;
        }
        match bytes[0] {
            0x1B => {
                self.state = State::Escape;
                self.reset_params();
            }
            byte => performer.execute(byte),
        }
        1
    }
}

/// The payload of a string being collected, which may grow only so far.
///
/// What it guards is the reading. A payload that outgrew its limit is dropped rather than
/// truncated -- half a URI is a different URI, and half a kitty image is not a smaller
/// image but a parse error with a plausible-looking prefix -- and the way that is held to
/// is that [`Payload::finish`] is the only way to the bytes, and gives none once anything
/// has been turned away.
///
/// The allocation outlives the string, which is why this is a field of the parser and not
/// of the state that is collecting into it.
#[derive(Default)]
struct Payload {
    bytes: Vec<u8>,
    limit: usize,
    overflowed: bool,
}

impl Payload {
    /// Start a string of at most LIMIT bytes, forgetting whatever the last one left.
    fn begin(&mut self, limit: usize) {
        self.bytes.clear();
        self.limit = limit;
        self.overflowed = false;
    }

    /// Bytes collected so far.
    fn len(&self) -> usize {
        self.bytes.len()
    }

    /// Collect BYTES, or as many of them as there is room for.
    #[inline]
    fn extend(&mut self, bytes: &[u8]) {
        let room = self.limit.saturating_sub(self.bytes.len());
        self.overflowed |= bytes.len() > room;
        self.bytes
            .extend_from_slice(&bytes[..bytes.len().min(room)]);
    }

    /// The whole payload, or `None` if it was ever more than there was room for.
    fn finish(&self) -> Option<&[u8]> {
        (!self.overflowed).then_some(&self.bytes)
    }
}

/// How many of BYTES, from the start, are text: not a C0 control. Eight at a time, by
/// the zero-byte test asked of `word - 0x20`; `text::printable_ascii_len` explains why
/// the lowest flag can be trusted.
#[inline]
fn text_len(bytes: &[u8]) -> usize {
    const ONES: u64 = u64::MAX / 255;
    const HIGH: u64 = ONES * 0x80;
    let mut chunks = bytes.chunks_exact(8);
    let mut len = 0;
    for chunk in &mut chunks {
        let word = u64::from_le_bytes(chunk.try_into().unwrap());
        let control = word.wrapping_sub(ONES * 0x20) & !word & HIGH;
        if control != 0 {
            return len + control.trailing_zeros() as usize / 8;
        }
        len += 8;
    }
    len + chunks
        .remainder()
        .iter()
        .take_while(|&&b| b >= 0x20)
        .count()
}

/// The number an OSC opens with, once it has been read as one.
///
/// A performer that holds one of these has already been told that the digits were digits
/// and that they fit, so it matches on the codes it acts on rather than re-deciding what
/// counts as a code. The named constants below are the ones cooked answers in Rust; every
/// other code is a number Lisp is handed and is only ever compared against these, so the
/// match compiles to the integer compare it was before the type existed.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct OscCode(u16);

impl OscCode {
    /// `OSC 7`: the working directory the shell is in, as a `file://` URL.
    pub(crate) const WORKING_DIRECTORY: Self = Self(7);
    /// `OSC 8`: a hyperlink opened or closed.
    pub(crate) const HYPERLINK: Self = Self(8);
    /// `OSC 66`: kitty's text sizing protocol.
    pub(crate) const TEXT_SIZE: Self = Self(66);
    /// `OSC 133`: a shell's semantic prompt marks.
    pub(crate) const SEMANTIC_PROMPT: Self = Self(133);
    /// `OSC 1337`: iTerm2's private channel, `File=` among much else.
    pub(crate) const ITERM: Self = Self(1337);

    /// The code DIGITS spell: digits and nothing else, and no more than fit.
    fn parse(digits: &[u8]) -> Option<Self> {
        if digits.is_empty() || !digits.iter().all(u8::is_ascii_digit) {
            return None;
        }
        // ASCII digits are UTF-8, so only an overflow can fail from here.
        Some(Self(str::from_utf8(digits).ok()?.parse().ok()?))
    }

    /// The number itself, for the one consumer that needs it as a number: an OSC cooked
    /// does not act on crosses to Lisp as `(osc CODE ...)`, and Lisp decides what it means.
    pub(crate) fn get(self) -> u16 {
        self.0
    }
}

#[derive(PartialEq, Eq, Debug, Default, Copy, Clone)]
enum State {
    CsiEntry,
    CsiIgnore,
    CsiIntermediate,
    CsiParam,
    DcsEntry,
    DcsIgnore,
    DcsIntermediate,
    DcsParam,
    DcsPassthrough,
    Escape,
    EscapeIntermediate,
    /// `ESC ]` — an operating system command, collected and handed over as a code and a
    /// payload.
    ///
    /// `code_end` is where the code ends in the payload, once the `;` after it has
    /// arrived. It travels with the state so that it cannot outlive the string: an OSC
    /// abandoned halfway leaves nothing for the next to inherit.
    OscString {
        code_end: Option<usize>,
    },
    /// `ESC _` — an application programming command, collected and handed over whole.
    ///
    /// Upstream folds this into `SosPmApcString` and discards it. It is split out
    /// because the kitty graphics protocol lives here; SOS and PM stay discarded,
    /// nothing cooked cares about having ever been sent through them.
    ApcString,
    SosPmApcString,
    #[default]
    Ground,
}

/// Performs actions requested by the Parser
///
/// Actions in this case mean, for example, handling a CSI escape sequence
/// describing cursor movement, or simply printing characters to the screen.
///
/// The methods on this type correspond to actions described in
/// <http://vt100.net/emu/dec_ansi_parser>. I've done my best to describe them in
/// a useful way in my own words for completeness, but the site should be
/// referenced if something isn't clear. If the site disappears at some point in
/// the future, consider checking archive.org.
pub(crate) trait Perform {
    /// Draw a run of text: bytes from `0x20` up, exactly as they arrived.
    ///
    /// Not characters, because the parser does not know what a character is; see
    /// [`Parser::advance_ground`]. Two calls with nothing dispatched between them carry
    /// consecutive bytes of the stream, so a multi-byte sequence may be split across
    /// them, and a performer reading the bytes as UTF-8 holds the first part until the
    /// second arrives. Any other dispatch in between means it never will.
    ///
    /// No guarantee is made about where runs are cut: a single logical line may arrive as
    /// several calls, and a call may end mid-word or mid-character.
    fn print_bytes(&mut self, _bytes: &[u8]) {}

    /// Execute a C0 control function. `ESC` never arrives, DEL is text, and there are no
    /// C1 controls; see [`Parser::advance_ground`].
    fn execute(&mut self, _byte: u8) {}

    /// Invoked when a final character arrives in first part of device control
    /// string.
    ///
    /// The control function should be determined from the private marker, final
    /// character, and execute with a parameter list. A handler should be
    /// selected for remaining characters in the string; the handler
    /// function should subsequently be called by `put` for every character in
    /// the control string.
    ///
    /// The `ignore` flag indicates that more than two intermediates arrived and
    /// subsequent characters were ignored.
    fn hook(&mut self, _params: &Params, _intermediates: &[u8], _ignore: bool, _action: char) {}

    /// Pass bytes as part of a device control string to the handler chosen in
    /// `hook`. C0 controls will also be passed to the handler.
    ///
    /// A slice rather than upstream's single byte, and called with the longest run the
    /// parser can see at once. A sixel image is a device control string megabytes long,
    /// and a call per byte of it is the wrong shape; a handler that wants bytes can
    /// still iterate. No guarantee is made about where the runs are cut, so a handler
    /// must accumulate rather than treat one call as one unit.
    fn put(&mut self, _bytes: &[u8]) {}

    /// Dispatch an application programming command — `ESC _ ... ST` — payload and all.
    ///
    /// Whole rather than streamed, because an APC payload is a structured message that
    /// cannot be acted on in pieces, and because the parser has to buffer it to find
    /// the terminator regardless. A payload that outgrew [`MAX_APC_RAW`] is dropped
    /// rather than passed on truncated, so this is never called with a fragment.
    ///
    /// Upstream has no equivalent: it discards APC along with SOS and PM. The kitty
    /// graphics protocol is carried here, which is why cooked vendors this parser.
    fn apc_dispatch(&mut self, _bytes: &[u8]) {}

    /// Called when a device control string is terminated.
    ///
    /// The previously selected handler should be notified that the DCS has
    /// terminated.
    fn unhook(&mut self) {}

    /// Dispatch an operating system command: `OSC CODE ; PAYLOAD ST`.
    ///
    /// PAYLOAD is everything after the first `;`, semicolons included, for the performer
    /// to take apart in whatever way CODE calls for. It is `None` when there was no `;`
    /// at all, which is not the same statement as an empty payload: `OSC 112 ST` resets
    /// the cursor colour, and `OSC 8 ; ST` is a malformed hyperlink.
    fn osc_dispatch(&mut self, _code: OscCode, _payload: Option<&[u8]>, _bell_terminated: bool) {}

    /// A final character has arrived for a CSI sequence
    ///
    /// The `ignore` flag indicates that either more than two intermediates
    /// arrived or the number of parameters exceeded the maximum supported
    /// length, and subsequent characters were ignored.
    fn csi_dispatch(
        &mut self,
        _params: &Params,
        _intermediates: &[u8],
        _ignore: bool,
        _action: char,
    ) {
    }

    /// The final character of an escape sequence has arrived.
    ///
    /// The `ignore` flag indicates that more than two intermediates arrived and
    /// subsequent characters were ignored.
    fn esc_dispatch(&mut self, _intermediates: &[u8], _ignore: bool, _byte: u8) {}

    /// Whether the parser should terminate prematurely.
    ///
    /// This can be used in conjunction with
    /// [`Parser::advance_until_terminated`] to terminate the parser after
    /// receiving certain escape sequences like synchronized updates.
    ///
    /// This is checked after every parsed byte, so no expensive computation
    /// should take place in this function.
    #[inline(always)]
    fn terminated(&self) -> bool {
        false
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emu::utf8::{Decoder, Piece};

    const OSC_BYTES: &[u8] = &[
        0x1B, 0x5D, // Begin OSC
        b'2', b';', b'j', b'w', b'i', b'l', b'm', b'@', b'j', b'w', b'i', b'l', b'm', b'-', b'd',
        b'e', b's', b'k', b':', b' ', b'~', b'/', b'c', b'o', b'd', b'e', b'/', b'a', b'l', b'a',
        b'c', b'r', b'i', b't', b't', b'y', 0x07, // End OSC
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
                        let run = run.iter().map(|&b| Sequence::Print(char::from(b)));
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
            0x0D, 0x1B, 0x5D, 0x32, 0x3B, 0x65, 0x63, 0x68, 0x6F, 0x20, 0x27, 0xC2, 0xAF, 0x5C,
            0x5F, 0x28, 0xE3, 0x83, 0x84, 0x29, 0x5F, 0x2F, 0xC2, 0xAF, 0x27, 0x20, 0x26, 0x26,
            0x20, 0x73, 0x6C, 0x65, 0x65, 0x70, 0x20, 0x31, 0x07,
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
}
