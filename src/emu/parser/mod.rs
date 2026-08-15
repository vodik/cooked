//! The VT parser state machine, vendored from `vte` 0.15.0.
//!
//! Upstream is <https://github.com/alacritty/vte>, by Joe Wilm and Christian Duerr,
//! dual-licensed Apache-2.0 OR MIT; both licences sit beside this file. It is
//! implemented according to [Paul Williams' ANSI parser state machine].
//!
//! Vendored rather than depended on because two things cooked needs cannot be
//! expressed through [`Perform`] as upstream defines it:
//!
//! * **APC is discarded.** `ESC _` lands in `State::SosPmApcString`, which consumes to
//!   the terminator and tells the performer nothing — and APC is where the kitty
//!   graphics protocol lives, so an image never reaches us at all.
//! * **String payloads arrive one byte at a time.** `Perform::put` is called per byte,
//!   which is the wrong shape for a multi-megabyte image transmission.
//!
//! Both are answered here: [`Perform::apc_dispatch`] receives an APC payload whole, and
//! DCS payloads arrive as slices through [`Perform::put`].
//!
//! Kept otherwise faithful to upstream, so that a future re-sync is a diff rather than
//! an archaeology exercise. The `no_std` machinery and the optional `ansi` module are
//! the only things dropped: cooked is always `std`, and it has its own interpreter.
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

pub use params::{Params, ParamsIter};

const MAX_INTERMEDIATES: usize = 2;
const MAX_OSC_PARAMS: usize = 16;

/// Largest APC payload collected before the sequence is abandoned.
///
/// Generous, because it has to hold one kitty graphics transmission: chunked transfers
/// cap themselves at 4096 bytes a piece, but an unchunked `t=d` is one APC carrying the
/// whole base64 image. Consumers cap again on what the payload *means*; this is only the
/// bound on what the parser will hold on their behalf.
pub const MAX_APC_RAW: usize = 8 << 20;
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
pub const MAX_OSC_RAW: usize = 8 << 20;

/// Parser for raw _VTE_ protocol which delegates actions to a [`Perform`]
///
/// [`Perform`]: trait.Perform.html
///
#[derive(Default)]
pub struct Parser {
    state: State,
    intermediates: [u8; MAX_INTERMEDIATES],
    intermediate_idx: usize,
    params: Params,
    param: u16,
    osc_raw: Vec<u8>,
    osc_params: [(usize, usize); MAX_OSC_PARAMS],
    osc_num_params: usize,
    /// Set when an OSC payload outgrew [`MAX_OSC_RAW`], so its end dispatches nothing.
    ///
    /// Dropped rather than truncated, for the same reason an over-long APC is: the
    /// parameter offsets index into a buffer that stopped growing, so half an OSC is not
    /// a shorter OSC but a set of slices that no longer mean what they say.
    osc_overflow: bool,
    apc_raw: Vec<u8>,
    /// Set when an APC payload outgrew [`MAX_APC_RAW`], so its end dispatches nothing.
    ///
    /// Dropped rather than truncated: the consumer of an APC is decoding a structured
    /// payload, and half of a kitty image is not a smaller image, it is a parse error
    /// with a plausible-looking prefix.
    apc_overflow: bool,
    ignoring: bool,
    partial_utf8: [u8; 4],
    partial_utf8_len: usize,
}

impl Parser {
    /// Create a new Parser
    pub fn new() -> Parser {
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
    pub fn advance<P: Perform>(&mut self, performer: &mut P, bytes: &[u8]) {
        let mut i = 0;

        // Handle partial codepoints from previous calls to `advance`.
        if self.partial_utf8_len != 0 {
            i += self.advance_partial_utf8(performer, bytes);
        }

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
        if end != 0 {
            let room = MAX_APC_RAW - self.apc_raw.len().min(MAX_APC_RAW);
            if end > room {
                self.apc_overflow = true;
            }
            self.apc_raw.extend_from_slice(&bytes[..end.min(room)]);
        }
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
    /// See [`Perform::advance`] for more details.
    #[inline]
    #[must_use = "Returned value should be used to processs the remaining bytes"]
    pub fn advance_until_terminated<P: Perform>(
        &mut self,
        performer: &mut P,
        bytes: &[u8],
    ) -> usize {
        let mut i = 0;

        // Handle partial codepoints from previous calls to `advance`.
        if self.partial_utf8_len != 0 {
            i += self.advance_partial_utf8(performer, bytes);
        }

        while i != bytes.len() && !performer.terminated() {
            match self.state {
                State::Ground => i += self.advance_ground(performer, &bytes[i..]),
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
            State::OscString => self.advance_osc_string(performer, byte),
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
                self.osc_raw.clear();
                self.osc_num_params = 0;
                self.osc_overflow = false;
                self.state = State::OscString
            }
            0x5F => {
                self.apc_raw.clear();
                self.apc_overflow = false;
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
    fn advance_osc_string<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        match byte {
            0x00..=0x06 | 0x08..=0x17 | 0x19 | 0x1C..=0x1F => (),
            0x07 => {
                self.osc_end(performer, byte);
                self.state = State::Ground
            }
            0x18 | 0x1A => {
                self.osc_end(performer, byte);
                performer.execute(byte);
                self.state = State::Ground
            }
            0x1B => {
                self.osc_end(performer, byte);
                self.reset_params();
                self.state = State::Escape
            }
            0x3B => self.action_osc_put_param(),
            _ => self.action_osc_put(byte),
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
                self.apc_raw.clear();
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
            _ => self.action_apc_put(byte),
        }
    }

    #[inline(always)]
    fn action_apc_put(&mut self, byte: u8) {
        if self.apc_raw.len() >= MAX_APC_RAW {
            self.apc_overflow = true;
            return;
        }
        self.apc_raw.push(byte);
    }

    fn apc_end<P: Perform>(&mut self, performer: &mut P) {
        if !self.apc_overflow {
            performer.apc_dispatch(&self.apc_raw);
        }
        self.apc_raw.clear();
        self.apc_overflow = false;
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

    /// Add OSC param separator.
    #[inline]
    fn action_osc_put_param(&mut self) {
        let idx = self.osc_raw.len();

        let param_idx = self.osc_num_params;
        match param_idx {
            // First param is special - 0 to current byte index.
            0 => self.osc_params[param_idx] = (0, idx),

            // Only process up to MAX_OSC_PARAMS.
            MAX_OSC_PARAMS => return,

            // All other params depend on previous indexing.
            _ => {
                let prev = self.osc_params[param_idx - 1];
                let begin = prev.1;
                self.osc_params[param_idx] = (begin, idx);
            }
        }

        self.osc_num_params += 1;
    }

    #[inline(always)]
    fn action_osc_put(&mut self, byte: u8) {
        if self.osc_raw.len() >= MAX_OSC_RAW {
            self.osc_overflow = true;
            return;
        }
        self.osc_raw.push(byte);
    }

    fn osc_end<P: Perform>(&mut self, performer: &mut P, byte: u8) {
        self.action_osc_put_param();
        if !self.osc_overflow {
            self.osc_dispatch(performer, byte);
        }
        self.osc_raw.clear();
        self.osc_num_params = 0;
        self.osc_overflow = false;
    }

    /// Reset escape sequence parameters and intermediates.
    #[inline]
    fn reset_params(&mut self) {
        self.intermediate_idx = 0;
        self.ignoring = false;
        self.param = 0;

        self.params.clear();
    }

    /// Hand the collected OSC parameters to the performer as slices of `osc_raw`.
    ///
    /// Upstream built this array with `MaybeUninit` and a pointer cast, which is `no_std`
    /// machinery for avoiding a default value -- and `no_std` is precisely what this
    /// vendored copy dropped. An empty slice is a perfectly good default here, so the
    /// safe form compiles to the same thing without the `assume_init` or the cast.
    #[inline]
    fn osc_dispatch<P: Perform>(&self, performer: &mut P, byte: u8) {
        let mut slices: [&[u8]; MAX_OSC_PARAMS] = [&[]; MAX_OSC_PARAMS];
        for (slice, &(start, end)) in slices
            .iter_mut()
            .zip(&self.osc_params[..self.osc_num_params])
        {
            *slice = &self.osc_raw[start..end];
        }
        performer.osc_dispatch(&slices[..self.osc_num_params], byte == 0x07);
    }

    /// Advance the parser state from ground.
    ///
    /// The ground state is handled separately since it can only be left using
    /// the escape character (`\x1b`). This allows more efficient parsing by
    /// using SIMD search with [`memchr`].
    #[inline]
    fn advance_ground<P: Perform>(&mut self, performer: &mut P, bytes: &[u8]) -> usize {
        // Find the next escape character.
        let num_bytes = bytes.len();
        let plain_chars = memchr::memchr(0x1B, bytes).unwrap_or(num_bytes);

        // If the next character is ESC, just process it and short-circuit.
        if plain_chars == 0 {
            self.state = State::Escape;
            self.reset_params();
            return 1;
        }

        match str::from_utf8(&bytes[..plain_chars]) {
            Ok(parsed) => {
                Self::ground_dispatch(performer, parsed);
                let mut processed = plain_chars;

                // If there's another character, it must be escape so process it directly.
                if processed < num_bytes {
                    self.state = State::Escape;
                    self.reset_params();
                    processed += 1;
                }

                processed
            }
            // Handle invalid and partial utf8.
            Err(err) => {
                // Dispatch all the valid bytes.
                let valid_bytes = err.valid_up_to();
                let parsed = unsafe { str::from_utf8_unchecked(&bytes[..valid_bytes]) };
                Self::ground_dispatch(performer, parsed);

                match err.error_len() {
                    Some(len) => {
                        // Execute C1 escapes or emit replacement character.
                        if len == 1 && bytes[valid_bytes] <= 0x9F {
                            performer.execute(bytes[valid_bytes]);
                        } else {
                            performer.print('�');
                        }

                        // Restart processing after the invalid bytes.
                        //
                        // While we could theoretically try to just re-parse
                        // `bytes[valid_bytes + len..plain_chars]`, it's easier
                        // to just skip it and invalid utf8 is pretty rare anyway.
                        valid_bytes + len
                    }
                    None => {
                        if plain_chars < num_bytes {
                            // Process bytes cut off by escape.
                            performer.print('�');
                            self.state = State::Escape;
                            self.reset_params();
                            plain_chars + 1
                        } else {
                            // Process bytes cut off by the buffer end.
                            let extra_bytes = num_bytes - valid_bytes;
                            let partial_len = self.partial_utf8_len + extra_bytes;
                            self.partial_utf8[self.partial_utf8_len..partial_len]
                                .copy_from_slice(&bytes[valid_bytes..valid_bytes + extra_bytes]);
                            self.partial_utf8_len = partial_len;
                            num_bytes
                        }
                    }
                }
            }
        }
    }

    /// Advance the parser while processing a partial utf8 codepoint.
    #[inline]
    fn advance_partial_utf8<P: Perform>(&mut self, performer: &mut P, bytes: &[u8]) -> usize {
        // Try to copy up to 3 more characters, to ensure the codepoint is complete.
        let old_bytes = self.partial_utf8_len;
        let to_copy = bytes.len().min(self.partial_utf8.len() - old_bytes);
        self.partial_utf8[old_bytes..old_bytes + to_copy].copy_from_slice(&bytes[..to_copy]);
        self.partial_utf8_len += to_copy;

        // Parse the unicode character.
        match str::from_utf8(&self.partial_utf8[..self.partial_utf8_len]) {
            // If the entire buffer is valid, use the first character and continue parsing.
            Ok(parsed) => {
                let c = unsafe { parsed.chars().next().unwrap_unchecked() };
                performer.print(c);

                self.partial_utf8_len = 0;
                c.len_utf8() - old_bytes
            }
            Err(err) => {
                let valid_bytes = err.valid_up_to();
                // If we have any valid bytes, that means we partially copied another
                // utf8 character into `partial_utf8`. Since we only care about the
                // first character, we just ignore the rest.
                if valid_bytes > 0 {
                    let c = unsafe {
                        let parsed = str::from_utf8_unchecked(&self.partial_utf8[..valid_bytes]);
                        parsed.chars().next().unwrap_unchecked()
                    };

                    performer.print(c);

                    self.partial_utf8_len = 0;
                    return valid_bytes - old_bytes;
                }

                match err.error_len() {
                    // If the partial character was also invalid, emit the replacement
                    // character.
                    Some(invalid_len) => {
                        performer.print('�');

                        self.partial_utf8_len = 0;
                        invalid_len - old_bytes
                    }
                    // If the character still isn't complete, wait for more data.
                    None => to_copy,
                }
            }
        }
    }

    /// Handle ground dispatch of print/execute for all characters in a string.
    #[inline]
    fn ground_dispatch<P: Perform>(performer: &mut P, text: &str) {
        for c in text.chars() {
            match c {
                '\x00'..='\x1f' | '\u{80}'..='\u{9f}' => performer.execute(c as u8),
                _ => performer.print(c),
            }
        }
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
    OscString,
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
pub trait Perform {
    /// Draw a character to the screen and update states.
    fn print(&mut self, _c: char) {}

    /// Execute a C0 or C1 control function.
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

    /// Dispatch an operating system command.
    fn osc_dispatch(&mut self, _params: &[&[u8]], _bell_terminated: bool) {}

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

    const OSC_BYTES: &[u8] = &[
        0x1B, 0x5D, // Begin OSC
        b'2', b';', b'j', b'w', b'i', b'l', b'm', b'@', b'j', b'w', b'i', b'l', b'm', b'-', b'd',
        b'e', b's', b'k', b':', b' ', b'~', b'/', b'c', b'o', b'd', b'e', b'/', b'a', b'l', b'a',
        b'c', b'r', b'i', b't', b't', b'y', 0x07, // End OSC
    ];

    #[derive(Default)]
    struct Dispatcher {
        dispatched: Vec<Sequence>,
    }

    #[derive(Debug, PartialEq, Eq)]
    enum Sequence {
        Osc(Vec<Vec<u8>>, bool),
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
        fn osc_dispatch(&mut self, params: &[&[u8]], bell_terminated: bool) {
            let params = params.iter().map(|p| p.to_vec()).collect();
            self.dispatched.push(Sequence::Osc(params, bell_terminated));
        }

        fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], ignore: bool, c: char) {
            let params = params.iter().map(|subparam| subparam.to_vec()).collect();
            let intermediates = intermediates.to_vec();
            self.dispatched
                .push(Sequence::Csi(params, intermediates, ignore, c));
        }

        fn esc_dispatch(&mut self, intermediates: &[u8], ignore: bool, byte: u8) {
            let intermediates = intermediates.to_vec();
            self.dispatched
                .push(Sequence::Esc(intermediates, ignore, byte));
        }

        fn hook(&mut self, params: &Params, intermediates: &[u8], ignore: bool, c: char) {
            let params = params.iter().map(|subparam| subparam.to_vec()).collect();
            let intermediates = intermediates.to_vec();
            self.dispatched
                .push(Sequence::DcsHook(params, intermediates, ignore, c));
        }

        fn put(&mut self, bytes: &[u8]) {
            self.dispatched
                .extend(bytes.iter().copied().map(Sequence::DcsPut));
        }

        fn apc_dispatch(&mut self, bytes: &[u8]) {
            self.dispatched.push(Sequence::Apc(bytes.to_vec()));
        }

        fn unhook(&mut self) {
            self.dispatched.push(Sequence::DcsUnhook);
        }

        fn print(&mut self, c: char) {
            self.dispatched.push(Sequence::Print(c));
        }

        fn execute(&mut self, byte: u8) {
            self.dispatched.push(Sequence::Execute(byte));
        }
    }

    #[test]
    fn parse_osc() {
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, OSC_BYTES);

        assert_eq!(dispatcher.dispatched.len(), 1);
        match &dispatcher.dispatched[0] {
            Sequence::Osc(params, _) => {
                assert_eq!(params.len(), 2);
                assert_eq!(params[0], &OSC_BYTES[2..3]);
                assert_eq!(params[1], &OSC_BYTES[4..(OSC_BYTES.len() - 1)]);
            }
            _ => panic!("expected osc sequence"),
        }
    }

    #[test]
    fn parse_empty_osc() {
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, &[0x1B, 0x5D, 0x07]);

        assert_eq!(dispatcher.dispatched.len(), 1);
        match &dispatcher.dispatched[0] {
            Sequence::Osc(..) => (),
            _ => panic!("expected osc sequence"),
        }
    }

    #[test]
    fn parse_osc_max_params() {
        let params = ";".repeat(params::MAX_PARAMS + 1);
        let input = format!("\x1b]{}\x1b", &params[..]).into_bytes();
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, &input);

        assert_eq!(dispatcher.dispatched.len(), 1);
        match &dispatcher.dispatched[0] {
            Sequence::Osc(params, _) => {
                assert_eq!(params.len(), MAX_OSC_PARAMS);
                assert!(params.iter().all(Vec::is_empty));
            }
            _ => panic!("expected osc sequence"),
        }
    }

    #[test]
    fn osc_bell_terminated() {
        const INPUT: &[u8] = b"\x1b]11;ff/00/ff\x07";
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, INPUT);

        assert_eq!(dispatcher.dispatched.len(), 1);
        match &dispatcher.dispatched[0] {
            Sequence::Osc(_, true) => (),
            _ => panic!("expected osc with bell terminator"),
        }
    }

    #[test]
    fn osc_c0_st_terminated() {
        const INPUT: &[u8] = b"\x1b]11;ff/00/ff\x1b\\";
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, INPUT);

        assert_eq!(dispatcher.dispatched.len(), 2);
        match &dispatcher.dispatched[0] {
            Sequence::Osc(_, false) => (),
            _ => panic!("expected osc with ST terminator"),
        }
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
            Sequence::Osc(vec![vec![b'2'], osc_data], true)
        );
        assert_eq!(dispatcher.dispatched.len(), 2);
    }

    #[test]
    fn osc_containing_string_terminator() {
        const INPUT: &[u8] = b"\x1b]2;\xe6\x9c\xab\x1b\\";
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, INPUT);

        assert_eq!(dispatcher.dispatched.len(), 2);
        match &dispatcher.dispatched[0] {
            Sequence::Osc(params, _) => {
                assert_eq!(params[1], &INPUT[4..(INPUT.len() - 2)]);
            }
            _ => panic!("expected osc sequence"),
        }
    }

    #[test]
    fn an_overlong_osc_is_dropped_rather_than_truncated() {
        // Upstream let this `Vec` grow without limit, so an OSC nobody terminates was an
        // allocation the child controlled. Dropped rather than truncated because the
        // parameter offsets index into the buffer: half an OSC is not a shorter OSC, it
        // is a set of slices that no longer mean what they say.
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, b"\x1b]52;s");
        parser.advance(&mut dispatcher, &vec![b'a'; MAX_OSC_RAW + 100]);
        parser.advance(&mut dispatcher, b"\x07");

        assert!(dispatcher.dispatched.is_empty());
    }

    #[test]
    fn an_overlong_osc_does_not_poison_the_next_one() {
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, b"\x1b]52;s");
        parser.advance(&mut dispatcher, &vec![b'a'; MAX_OSC_RAW + 100]);
        parser.advance(&mut dispatcher, b"\x07");
        parser.advance(&mut dispatcher, b"\x1b]2;title\x07");

        assert_eq!(dispatcher.dispatched.len(), 1);
        match &dispatcher.dispatched[0] {
            Sequence::Osc(params, _) => {
                assert_eq!(params[0], b"2");
                assert_eq!(params[1], b"title");
            }
            other => panic!("expected osc sequence, got {other:?}"),
        }
    }

    #[test]
    fn an_osc_abandoned_midway_does_not_poison_the_next_one() {
        // An overflow cleared by `osc_end` is the easy case; one abandoned by an ESC
        // that starts something else has to clear the flag too.
        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, b"\x1b]52;s");
        parser.advance(&mut dispatcher, &vec![b'a'; MAX_OSC_RAW + 100]);
        parser.advance(&mut dispatcher, b"\x1b]2;title\x07");

        let dispatched: Vec<_> = dispatcher
            .dispatched
            .iter()
            .filter(|s| matches!(s, Sequence::Osc(..)))
            .collect();
        assert_eq!(dispatched.len(), 1);
        match dispatched[0] {
            Sequence::Osc(params, _) => assert_eq!(params[1], b"title"),
            other => panic!("expected osc sequence, got {other:?}"),
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

    #[test]
    fn c1s() {
        const INPUT: &[u8] = b"\x00\x1f\x80\x90\x98\x9b\x9c\x9d\x9e\x9fa";

        let mut dispatcher = Dispatcher::default();
        let mut parser = Parser::new();

        parser.advance(&mut dispatcher, INPUT);

        assert_eq!(dispatcher.dispatched.len(), 11);
        assert_eq!(dispatcher.dispatched[0], Sequence::Execute(0));
        assert_eq!(dispatcher.dispatched[1], Sequence::Execute(31));
        assert_eq!(dispatcher.dispatched[2], Sequence::Execute(128));
        assert_eq!(dispatcher.dispatched[3], Sequence::Execute(144));
        assert_eq!(dispatcher.dispatched[4], Sequence::Execute(152));
        assert_eq!(dispatcher.dispatched[5], Sequence::Execute(155));
        assert_eq!(dispatcher.dispatched[6], Sequence::Execute(156));
        assert_eq!(dispatcher.dispatched[7], Sequence::Execute(157));
        assert_eq!(dispatcher.dispatched[8], Sequence::Execute(158));
        assert_eq!(dispatcher.dispatched[9], Sequence::Execute(159));
        assert_eq!(dispatcher.dispatched[10], Sequence::Print('a'));
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
