//! What the child negotiated about how keys are spelled: the kitty keyboard protocol's
//! flag stacks, xterm's modifyOtherKeys level, and the [`KeyEncoding`] that follows from
//! both.
//!
//! The encoder itself is Lisp's, because that is where the key event is. What lives here
//! is the negotiation, reduced to one value that says everything the encoder needs, so
//! that the pieces of it cannot reach Lisp disagreeing with each other.

use std::ops::{BitAnd, BitOr, Not};

/// A set of kitty keyboard protocol flags, as `CSI > FLAGS u` pushes them.
///
/// Carries every bit the child sent, including the ones cooked does not honour: a pop has
/// to restore exactly what its matching push put there. [`KittyFlags::honoured`] is the
/// reading that makes a claim about this terminal.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Hash)]
pub struct KittyFlags(u8);

impl KittyFlags {
    pub const NONE: Self = Self(0);
    /// Bit 1: escape codes for keys that are ambiguous in the legacy encoding.
    pub const DISAMBIGUATE: Self = Self(1);
    /// Bit 2: press, repeat and release reported separately. Never honoured, because
    /// Emacs delivers no release events and cannot tell a repeat from a press, so a child
    /// told yes would wait for releases that never come.
    pub const REPORT_EVENT_TYPES: Self = Self(2);
    /// Bit 4: the shifted key alongside the key. Only the shifted alternate is sent; the
    /// base-layout key names a physical key, which an Emacs event does not carry.
    pub const REPORT_ALTERNATE_KEYS: Self = Self(4);
    /// Bit 8: every key as an escape code, text keys included. A bare modifier press is
    /// never reported, since Emacs only reports a modifier as part of another key.
    pub const REPORT_ALL_KEYS: Self = Self(8);
    /// Bit 16: the text a key produces, alongside its code.
    pub const REPORT_TEXT: Self = Self(16);

    /// The flags cooked implements. This is what crosses to Lisp and what a `CSI ? u`
    /// reply is masked with, so the two cannot disagree about what was granted.
    pub const HONOURED: Self = Self(
        Self::DISAMBIGUATE.0
            | Self::REPORT_ALTERNATE_KEYS.0
            | Self::REPORT_ALL_KEYS.0
            | Self::REPORT_TEXT.0,
    );

    /// The flags a child's raw parameter names. Only the low byte is kept, as the
    /// protocol defines no flag above bit 16.
    pub const fn from_bits_retain(bits: u8) -> Self {
        Self(bits)
    }

    pub const fn bits(self) -> u8 {
        self.0
    }

    pub const fn is_empty(self) -> bool {
        self.0 == 0
    }

    pub const fn intersects(self, other: Self) -> bool {
        self.0 & other.0 != 0
    }

    /// These flags less the ones cooked does not implement.
    pub const fn honoured(self) -> Self {
        Self(self.0 & Self::HONOURED.0)
    }

    /// Whether these flags switch the kitty encoding on at all.
    ///
    /// Bit 8 does so as surely as bit 1: reporting every key as an escape code
    /// disambiguates them all by construction. Bits 4 and 16 alone do not, because each
    /// only adds a field to an escape code that something else already chose to send.
    pub const fn enables_encoding(self) -> bool {
        self.intersects(Self(Self::DISAMBIGUATE.0 | Self::REPORT_ALL_KEYS.0))
    }
}

impl BitOr for KittyFlags {
    type Output = Self;
    fn bitor(self, rhs: Self) -> Self {
        Self(self.0 | rhs.0)
    }
}

impl BitAnd for KittyFlags {
    type Output = Self;
    fn bitand(self, rhs: Self) -> Self {
        Self(self.0 & rhs.0)
    }
}

impl Not for KittyFlags {
    type Output = Self;
    fn not(self) -> Self {
        Self(!self.0)
    }
}

impl std::fmt::Display for KittyFlags {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", self.0)
    }
}

/// One screen's kitty keyboard flag stack, innermost last.
///
/// Capped at [`KittyStack::LIMIT`], and a push onto a full stack evicts the *oldest*
/// entry rather than being dropped, as the spec requires. Dropping the push would be the
/// worse failure: the child's next pop would take away the entry beneath it, and from
/// then on every pop would restore the wrong flags.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct KittyStack(Vec<KittyFlags>);

impl KittyStack {
    /// Real clients push once around a full-screen session; anything deeper is a child
    /// that never pops.
    pub(super) const LIMIT: usize = 16;

    /// The flags in force: the top of the stack, as pushed.
    pub(super) fn top(&self) -> KittyFlags {
        self.0.last().copied().unwrap_or_default()
    }

    /// `CSI > FLAGS u`.
    pub(super) fn push(&mut self, flags: KittyFlags) {
        if self.0.len() >= Self::LIMIT {
            self.0.remove(0);
        }
        self.0.push(flags);
    }

    /// `CSI < N u`: pop N entries, at least one.
    pub(super) fn pop(&mut self, count: usize) {
        let keep = self.0.len().saturating_sub(count.max(1));
        self.0.truncate(keep);
    }

    /// `CSI = FLAGS ; MODE u`: 1 (the default) replaces the top, 2 sets the given bits
    /// and 3 clears them. Read as a plain replace, `CSI = 16 ; 2 u` -- add associated
    /// text -- would drop disambiguation on the way.
    pub(super) fn set(&mut self, flags: KittyFlags, mode: usize) {
        let top = self.top();
        let flags = match mode {
            2 => top | flags,
            3 => top & !flags,
            _ => flags,
        };
        match self.0.last_mut() {
            Some(top) => *top = flags,
            None => self.0.push(flags),
        }
    }
}

/// xterm's modifyOtherKeys level, as `CSI > 4 ; LEVEL m` sets it.
///
/// Only the two levels cooked honours exist. They differ in which keys they cover, not in
/// how a covered key is spelled; the rules are xterm's and live with the encoder, in
/// `cooked--modify-other-p`. Level 1 is the one `emacs -nw` asks for, so it is not a
/// curiosity. Level 3 sends unmodified keys as escapes too, which nothing here does, so it
/// reads as no level at all: a child handed level 2's spelling would still be waiting for
/// every plain key, and the legacy encoding at least types.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub enum ModifyOtherKeys {
    Level1 = 1,
    Level2 = 2,
}

impl ModifyOtherKeys {
    /// The level a `CSI > 4 ; LEVEL m` parameter names, if cooked honours it.
    pub(super) fn from_param(level: u16) -> Option<Self> {
        match level {
            1 => Some(Self::Level1),
            2 => Some(Self::Level2),
            _ => None,
        }
    }

    pub const fn level(self) -> u8 {
        self as u8
    }
}

/// How the child wants keys that have no classical encoding -- modified Return, Tab,
/// Escape and Backspace -- to be spelled, with everything the chosen encoding needs.
///
/// This has to be negotiated rather than assumed. `ESC [ 27 ; 2 ; 13 ~` sent to a program
/// that never asked for it is not a shift+enter, it is six characters of garbage in its
/// input, so [`KeyEncoding::Legacy`] is the only safe default and the extended forms are
/// unlocked by the child itself.
///
/// The payload rides the variant so that it exists exactly when it means something: there
/// are no kitty flags to consult under modifyOtherKeys, and no level under kitty.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum KeyEncoding {
    /// Nothing negotiated: a modified Return is just CR, as it has always been.
    #[default]
    Legacy,
    /// xterm's `modifyOtherKeys`: `CSI 27 ; MOD ; CHAR ~`, over the keys the level covers.
    ModifyOtherKeys(ModifyOtherKeys),
    /// The kitty keyboard protocol: `CSI CHAR ; MOD u`, with the honoured flags in force.
    /// Never constructed with flags for which [`KittyFlags::enables_encoding`] is false.
    Kitty(KittyFlags),
}

impl KeyEncoding {
    /// The encoding a kitty flag set and a modifyOtherKeys level settle on together.
    ///
    /// Kitty wins when both are on: a child that pushed kitty flags is speaking the newer
    /// protocol deliberately, and libraries that enable both expect kitty to take effect.
    pub(super) fn negotiate(kitty: KittyFlags, modify_other: Option<ModifyOtherKeys>) -> Self {
        let kitty = kitty.honoured();
        if kitty.enables_encoding() {
            Self::Kitty(kitty)
        } else if let Some(level) = modify_other {
            Self::ModifyOtherKeys(level)
        } else {
            Self::Legacy
        }
    }

    /// The kitty flags the encoder applies: empty unless the encoding is kitty.
    pub fn kitty_flags(self) -> KittyFlags {
        match self {
            Self::Kitty(flags) => flags,
            _ => KittyFlags::NONE,
        }
    }

    /// The modifyOtherKeys level the encoder applies, as its number: 0 unless the
    /// encoding is modifyOtherKeys.
    pub fn modify_other_keys_level(self) -> u8 {
        match self {
            Self::ModifyOtherKeys(level) => level.level(),
            _ => 0,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_full_stack_evicts_its_oldest_entry_so_pops_still_pair() {
        let mut stack = KittyStack::default();
        for bits in 0..KittyStack::LIMIT as u8 + 1 {
            stack.push(KittyFlags::from_bits_retain(bits));
        }
        assert_eq!(stack.top().bits(), KittyStack::LIMIT as u8);
        stack.pop(KittyStack::LIMIT - 1);
        assert_eq!(stack.top().bits(), 1, "the entry evicted was the oldest, 0");
    }

    #[test]
    fn only_disambiguation_or_all_keys_turns_kitty_on() {
        for (bits, kitty) in [(1, true), (8, true), (4, false), (16, false), (20, false)] {
            let encoding = KeyEncoding::negotiate(KittyFlags::from_bits_retain(bits), None);
            assert_eq!(matches!(encoding, KeyEncoding::Kitty(_)), kitty, "{bits}");
        }
    }

    #[test]
    fn the_encoding_carries_only_honoured_flags() {
        let encoding = KeyEncoding::negotiate(KittyFlags::from_bits_retain(0b11111), None);
        assert_eq!(encoding.kitty_flags(), KittyFlags::HONOURED);
        assert_eq!(encoding.modify_other_keys_level(), 0);
    }

    #[test]
    fn kitty_wins_over_modify_other_keys() {
        let encoding =
            KeyEncoding::negotiate(KittyFlags::DISAMBIGUATE, Some(ModifyOtherKeys::Level2));
        assert_eq!(encoding, KeyEncoding::Kitty(KittyFlags::DISAMBIGUATE));
    }
}
