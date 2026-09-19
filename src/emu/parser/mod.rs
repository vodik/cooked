//! The VT parser state machine, forked from `vte` 0.15.0.
//!
//! Upstream is <https://github.com/alacritty/vte>, by Joe Wilm and Christian Duerr,
//! dual-licensed Apache-2.0 OR MIT; both licences sit beside this file, and the whole
//! directory is under them, cooked's own parts included, so that nobody has to work out
//! which line came from where. It is implemented according to
//! [Paul Williams' ANSI parser state machine].
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

mod osc;
mod params;
mod payload;

pub(crate) use osc::OscCode;
pub(crate) use params::{Params, ParamsIter};
use payload::Payload;

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
mod tests;
