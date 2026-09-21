//! Spelling one key press the way the child asked for it.
//!
//! The decision of *which* key was pressed -- what Emacs event arrived, which of its
//! names a graphical frame uses, whether the key is cooked's to forward at all -- is
//! Lisp's, because that is where the event is. What lives here is the spelling, because
//! it depends on a negotiation the child can change at any moment: the kitty keyboard
//! flags, xterm's modifyOtherKeys level, DECCKM and DECKPAM. Lisp used to hold a copy of
//! all four, refreshed only by a drain, so a key pressed between the child pushing
//! `CSI > 1 u` and Emacs next draining was spelled the legacy way and read by the child
//! as something else entirely. Sending the key and spelling it here closes that window,
//! exactly as [`super::mouse`] closed it for a mouse report: the negotiation is read and
//! the bytes built under the one lock, from the values the child itself set.

use super::{KeyEncoding, KittyFlags, ModifyOtherKeys, Term};

/// The modifiers held with a key, as Emacs names them.
///
/// A set rather than five booleans: every rule below is about the set -- xterm's
/// parameter is a sum over it, `allowedCharModifiers` is a subset of it, and "any
/// modifier but Shift" is a test on it -- and five parameters in a row is the shape where
/// a caller passing Control where Meta was wanted compiles.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) struct Modifiers(u8);

impl Modifiers {
    pub(crate) const NONE: Self = Self(0);
    pub(crate) const SHIFT: Self = Self(1);
    pub(crate) const META: Self = Self(2);
    pub(crate) const CONTROL: Self = Self(4);
    pub(crate) const SUPER: Self = Self(8);
    pub(crate) const HYPER: Self = Self(16);

    /// The modifier a `event-modifiers` symbol names, or `None` for one no protocol
    /// spells.
    ///
    /// Emacs' `alt` is the one that reaches here and is dropped: it has no bit in
    /// xterm's parameter and none in kitty's, which is also why DEC mode 1039 is
    /// declined. `click`, `down` and `drag` arrive on mouse events, which never reach a
    /// key encoder.
    pub(crate) fn parse(name: &str) -> Option<Self> {
        match name {
            "shift" => Some(Self::SHIFT),
            "meta" => Some(Self::META),
            "control" => Some(Self::CONTROL),
            "super" => Some(Self::SUPER),
            "hyper" => Some(Self::HYPER),
            _ => None,
        }
    }

    pub(crate) const fn with(self, other: Self) -> Self {
        Self(self.0 | other.0)
    }

    const fn without(self, other: Self) -> Self {
        Self(self.0 & !other.0)
    }

    pub(super) const fn holds(self, other: Self) -> bool {
        self.0 & other.0 != 0
    }

    /// The xterm modifier parameter: 1 plus a bit per held modifier.
    ///
    /// Shift is 1, Meta 2 and Control 4, as in xterm, where the key Emacs calls Meta is
    /// the one xterm calls Alt. Super is 8 and Hyper 16, as in kitty's keyboard protocol,
    /// so `s-<up>` is `ESC [ 1 ; 9 A`. xterm's own 8 is a Meta key distinct from Alt,
    /// which a PC keyboard does not have, and kitty sends Super in that place in its
    /// legacy spellings too.
    const fn param(self) -> u32 {
        1 + self.0 as u32
    }

    /// Whether these modifiers stop the key producing text, which every one but Shift
    /// does.
    ///
    /// Control and Meta, and Super and Hyper, whose chords are shortcuts rather than
    /// characters: kitty spells `s-a` as `ESC [ 97 ; 9 u` under bit 1, as it does `M-a`.
    const fn textless(self) -> bool {
        self.holds(
            Self::CONTROL
                .with(Self::META)
                .with(Self::SUPER)
                .with(Self::HYPER),
        )
    }

    /// SEQ as a key held with these modifiers sends it where no protocol spells the
    /// modifier.
    ///
    /// That is SEQ with an ESC in front when Meta is held and SEQ unchanged otherwise:
    /// `M-x` is `ESC x`, which is xterm's `metaSendsEscape` and the only spelling of Meta
    /// a child that negotiated nothing can read. Control and Shift are not this
    /// function's to apply, having already been folded into SEQ.
    fn meta_prefixed(self, seq: Vec<u8>) -> Vec<u8> {
        if self.holds(Self::META) {
            let mut out = Vec::with_capacity(seq.len() + 1);
            out.push(b'\x1b');
            out.extend_from_slice(&seq);
            out
        } else {
            seq
        }
    }
}

/// The key a press names, once Lisp has decomposed the event.
///
/// The three cases are spelled apart rather than carried as one integer because the
/// encoders branch on them and on nothing else: a key with a row in the table is spelled
/// from that row, a text key from the character it types, and the ESC byte from neither.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Key {
    /// A text key, named by the character it types with no modifier held: `event-basic-
    /// type` reports `a` for both `a` and `A`, and the Shift in [`Modifiers`] is what
    /// says which was pressed.
    Text(char),
    /// A key with a row in [`NamedKey`]'s table.
    Named(NamedKey),
    /// ESC as a terminal frame delivers it, which is a bare byte.
    ///
    /// Never re-spelled, whatever the child negotiated. On a terminal frame ESC is both
    /// the Escape key and the first half of every Meta chord, and the two arrive as the
    /// same event; sent as `ESC [ 27 u`, `M-x` would reach the child as an Escape
    /// followed by a letter. A graphical frame, where Escape is a key of its own, reports
    /// it as [`NamedKey::Escape`] and gets the protocol's spelling.
    LooseEscape,
}

impl Key {
    /// The key a Lisp event names: a character, or the symbol of a table row.
    ///
    /// `None` for a key no table carries -- `f30`, `wheel-up`, the symbol a mouse event
    /// reduces to -- which is how Lisp is told there is nothing to send. A raw byte above
    /// Unicode is refused for the same reason: it is no character this can spell.
    pub(crate) fn parse_char(code: i64) -> Option<Self> {
        match u32::try_from(code).ok().and_then(char::from_u32)? {
            '\x1b' => Some(Self::LooseEscape),
            c => Some(Self::Text(c)),
        }
    }

    pub(crate) fn parse_name(name: &str) -> Option<Self> {
        NamedKey::from_name(name).map(Self::Named)
    }
}

/// How a [`NamedKey`] is spelled, and so what a modifier does to it.
///
/// One table rather than parallel ones per protocol, because the unmodified spelling of
/// every key is derivable from its modified one: a separate table of unmodified
/// spellings would be a denormalization maintained by hand, and one consulted after the
/// others could never be reached at all.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Spelling {
    /// Unmodified, `ESC [ FINAL`, or `ESC O FINAL` under DECCKM; modified,
    /// `ESC [ 1 ; MOD FINAL`.
    Csi(char),
    /// Unmodified `ESC O FINAL`, and modified `ESC [ 1 ; MOD FINAL` -- F1 to F4 leave SS3
    /// behind the moment they are modified.
    Ss3(char),
    /// The number N in `ESC [ N ~`, which takes a modifier as `ESC [ N ; MOD ~`.
    Tilde(u32),
    /// A key whose classical spelling is a byte, and whose modified spelling exists only
    /// in a protocol the child negotiated.
    ///
    /// CODE is the code point the negotiated encodings name it by, and FALLBACK the
    /// classical spelling: the code point as a character unless the key says otherwise.
    /// See [`Encoder::literal`] for why a modifier here is spelled out only when the
    /// child opted in.
    Literal { code: u32, fallback: Fallback },
    /// One of the nineteen keypad keys, which is two keys in one.
    ///
    /// APP is the SS3 final byte the key sends under application keypad -- `ESC O APP`,
    /// which is what `ka1` and its neighbours in terminfo/cooked.ti spell out. PLAIN is
    /// the other spelling, the one `rmkx` asks for. KITTY is the private-use code point
    /// the kitty protocol gives the key, which is the one part of this table the protocol
    /// spells differently from a legacy terminal: a keypad key is a key of its own there,
    /// so that `kp-home` and `home` can be told apart.
    Keypad { app: char, plain: Plain, kitty: u32 },
    /// The key this one is spelled as with Shift held, so `f13` is sent as `S-f1` and
    /// `C-f13` as `C-S-f1`.
    ///
    /// That is how terminfo/cooked.ti declares `kf13` through `kf24`, after xterm's PC
    /// keyboard, where F13 is what Shift+F1 is called. xterm sends a key that really is
    /// F13 as `ESC [ 25 ~`, but no capability in the entry names that, so a program
    /// reading the entry would take it for an unknown key.
    Shifted(NamedKey),
    /// No spelling outside the kitty protocol, which gives the key a code point of its
    /// own.
    ///
    /// Pause and Print Screen send nothing in xterm and have no capability in terminfo,
    /// and inventing a sequence for them would put bytes in a program's input that it
    /// never agreed to read.
    Nothing,
}

/// What a keypad key sends when the keypad is not in application mode.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Plain {
    /// The character on the key cap, which the key then behaves exactly as: `C-kp-add`
    /// is spelled from the code point of `+` as `C-+` would be.
    Cap(char),
    /// With NumLock off this key *is* the editing key it stands in for, so a modifier
    /// reaches that key's spelling. Terminfo declares no modified keypad capability, and
    /// inventing `ESC [ 1 ; 5 w` to fill the gap would send a sequence nothing decodes.
    Like(NamedKey),
}

/// The classical spelling of a [`Spelling::Literal`] key, for a child that negotiated
/// nothing.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Fallback {
    /// The key's code point as a character, which is what every terminal has always sent:
    /// Return is CR, Tab is HT.
    Code,
    /// A spelling of its own. Shift+Tab is the one key here whose classical form is an
    /// escape sequence; terminfo calls it `kcbt`.
    Bytes(&'static str),
}

/// Every non-character key cooked speaks for, with its Lisp name and its spelling.
///
/// The names are exactly the set `cooked--key-names' carries, since Lisp has to bind each
/// of them in every modified spelling for the map it builds; `cooked--key-table' hands
/// this list back so that a test can hold the two against each other.
macro_rules! named_keys {
    ($($variant:ident => $name:literal, $spelling:expr, $kitty:expr;)*) => {
        /// A key Emacs names with a symbol rather than a character.
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        pub(crate) enum NamedKey { $($variant),* }

        impl NamedKey {
            /// Every key, in table order, for the Lisp side to bind.
            pub(crate) const ALL: &'static [Self] = &[$(Self::$variant),*];

            fn from_name(name: &str) -> Option<Self> {
                match name { $($name => Some(Self::$variant),)* _ => None }
            }

            /// The symbol Emacs names this key with.
            pub(crate) fn name(self) -> &'static str {
                match self { $(Self::$variant => $name),* }
            }

            fn spelling(self) -> Spelling {
                match self { $(Self::$variant => $spelling),* }
            }

            /// The private-use code point the kitty protocol gives this key, for the keys
            /// the protocol names in its functional table rather than by their legacy
            /// spelling.
            ///
            /// From the functional key table in kitty's keyboard protocol document. F13
            /// to F24, which terminfo spells as shifted F1 to F12, are keys of their own
            /// there, as the keypad is; `menu' has a legacy spelling, `ESC [ 29 ~', but
            /// the protocol names it `ESC [ 57363 u' all the same. Scroll Lock and the
            /// lock keys have code points too, and are missing because Emacs reports none
            /// of them as a key.
            fn functional_code(self) -> Option<u32> {
                match self { $(Self::$variant => $kitty),* }
            }

            /// Whether this key has no spelling but the kitty protocol's, so that Lisp
            /// binds it only while that protocol is negotiated.
            pub(crate) fn kitty_only(self) -> bool {
                matches!(self.spelling(), Spelling::Nothing)
            }
        }
    };
}

named_keys! {
    Up => "up", Spelling::Csi('A'), None;
    Down => "down", Spelling::Csi('B'), None;
    Right => "right", Spelling::Csi('C'), None;
    Left => "left", Spelling::Csi('D'), None;
    Home => "home", Spelling::Csi('H'), None;
    End => "end", Spelling::Csi('F'), None;
    F1 => "f1", Spelling::Ss3('P'), None;
    F2 => "f2", Spelling::Ss3('Q'), None;
    F3 => "f3", Spelling::Ss3('R'), None;
    F4 => "f4", Spelling::Ss3('S'), None;
    Prior => "prior", Spelling::Tilde(5), None;
    Next => "next", Spelling::Tilde(6), None;
    Insert => "insert", Spelling::Tilde(2), None;
    Deletechar => "deletechar", Spelling::Tilde(3), None;
    F5 => "f5", Spelling::Tilde(15), None;
    F6 => "f6", Spelling::Tilde(17), None;
    F7 => "f7", Spelling::Tilde(18), None;
    F8 => "f8", Spelling::Tilde(19), None;
    F9 => "f9", Spelling::Tilde(20), None;
    F10 => "f10", Spelling::Tilde(21), None;
    F11 => "f11", Spelling::Tilde(23), None;
    F12 => "f12", Spelling::Tilde(24), None;
    Return => "return", Spelling::Literal { code: 13, fallback: Fallback::Code }, None;
    Tab => "tab", Spelling::Literal { code: 9, fallback: Fallback::Code }, None;
    Escape => "escape", Spelling::Literal { code: 27, fallback: Fallback::Code }, None;
    Backspace => "backspace", Spelling::Literal { code: 127, fallback: Fallback::Code }, None;
    // Shift+TAB is reported by Emacs as `backtab', not as `S-tab'; `cooked--key-parts'
    // restores the Shift `event-modifiers' leaves out, so this falls out of the ordinary
    // modifier logic after all. Its fallback is the classical, un-negotiated spelling
    // rather than its code point as a character, which no other row needs.
    Backtab => "backtab", Spelling::Literal { code: 9, fallback: Fallback::Bytes("\x1b[Z") }, None;
    // `begin' is here for the keypad's centre key rather than for itself: no ordinary
    // keyboard sends it, but `kbeg' is what terminfo calls that key and this is the row
    // `kp-begin' falls back to.
    Begin => "begin", Spelling::Csi('E'), None;
    // The keypad. Nineteen capabilities -- `ka1' through `kc3', `kbeg', `kp5', `kent' and
    // the `kpADD' family -- are declared in terminfo/cooked.ti, and after `keypad(true)'
    // ncurses waits on getch for exactly these sequences.
    //
    // Emacs reports the same physical key under two names depending on NumLock, so both
    // halves are listed: `kp-7' and `kp-home' are one key and share the SS3 final `w'.
    // What differs is the *other* spelling -- the digit half falls back to the character
    // on the key cap, the editing half to whatever the equivalent main-keyboard key
    // sends, so that a modifier reaches the spelling that key already has rather than a
    // keypad form nothing decodes.
    Kp0 => "kp-0", Spelling::Keypad { app: 'p', plain: Plain::Cap('0'), kitty: 57399 }, None;
    Kp1 => "kp-1", Spelling::Keypad { app: 'q', plain: Plain::Cap('1'), kitty: 57400 }, None;
    Kp2 => "kp-2", Spelling::Keypad { app: 'r', plain: Plain::Cap('2'), kitty: 57401 }, None;
    Kp3 => "kp-3", Spelling::Keypad { app: 's', plain: Plain::Cap('3'), kitty: 57402 }, None;
    Kp4 => "kp-4", Spelling::Keypad { app: 't', plain: Plain::Cap('4'), kitty: 57403 }, None;
    Kp5 => "kp-5", Spelling::Keypad { app: 'u', plain: Plain::Cap('5'), kitty: 57404 }, None;
    Kp6 => "kp-6", Spelling::Keypad { app: 'v', plain: Plain::Cap('6'), kitty: 57405 }, None;
    Kp7 => "kp-7", Spelling::Keypad { app: 'w', plain: Plain::Cap('7'), kitty: 57406 }, None;
    Kp8 => "kp-8", Spelling::Keypad { app: 'x', plain: Plain::Cap('8'), kitty: 57407 }, None;
    Kp9 => "kp-9", Spelling::Keypad { app: 'y', plain: Plain::Cap('9'), kitty: 57408 }, None;
    KpDecimal => "kp-decimal", Spelling::Keypad { app: 'n', plain: Plain::Cap('.'), kitty: 57409 }, None;
    KpAdd => "kp-add", Spelling::Keypad { app: 'k', plain: Plain::Cap('+'), kitty: 57413 }, None;
    KpSubtract => "kp-subtract", Spelling::Keypad { app: 'm', plain: Plain::Cap('-'), kitty: 57412 }, None;
    KpMultiply => "kp-multiply", Spelling::Keypad { app: 'j', plain: Plain::Cap('*'), kitty: 57411 }, None;
    KpDivide => "kp-divide", Spelling::Keypad { app: 'o', plain: Plain::Cap('/'), kitty: 57410 }, None;
    KpSeparator => "kp-separator", Spelling::Keypad { app: 'l', plain: Plain::Cap(','), kitty: 57416 }, None;
    KpEnter => "kp-enter", Spelling::Keypad { app: 'M', plain: Plain::Cap('\r'), kitty: 57414 }, None;
    KpHome => "kp-home", Spelling::Keypad { app: 'w', plain: Plain::Like(NamedKey::Home), kitty: 57423 }, None;
    KpUp => "kp-up", Spelling::Keypad { app: 'x', plain: Plain::Like(NamedKey::Up), kitty: 57419 }, None;
    KpPrior => "kp-prior", Spelling::Keypad { app: 'y', plain: Plain::Like(NamedKey::Prior), kitty: 57421 }, None;
    KpLeft => "kp-left", Spelling::Keypad { app: 't', plain: Plain::Like(NamedKey::Left), kitty: 57417 }, None;
    KpBegin => "kp-begin", Spelling::Keypad { app: 'E', plain: Plain::Like(NamedKey::Begin), kitty: 57427 }, None;
    KpRight => "kp-right", Spelling::Keypad { app: 'v', plain: Plain::Like(NamedKey::Right), kitty: 57418 }, None;
    KpEnd => "kp-end", Spelling::Keypad { app: 'q', plain: Plain::Like(NamedKey::End), kitty: 57424 }, None;
    KpDown => "kp-down", Spelling::Keypad { app: 'r', plain: Plain::Like(NamedKey::Down), kitty: 57420 }, None;
    KpNext => "kp-next", Spelling::Keypad { app: 's', plain: Plain::Like(NamedKey::Next), kitty: 57422 }, None;
    KpInsert => "kp-insert", Spelling::Keypad { app: 'p', plain: Plain::Like(NamedKey::Insert), kitty: 57425 }, None;
    KpDelete => "kp-delete", Spelling::Keypad { app: 'n', plain: Plain::Like(NamedKey::Deletechar), kitty: 57426 }, None;
    // F13 to F24 as terminfo/cooked.ti names them: `kf13' is Shift+F1's `ESC [ 1 ; 2 P',
    // up to `kf24', Shift+F12's `ESC [ 24 ; 2 ~'.
    F13 => "f13", Spelling::Shifted(NamedKey::F1), Some(57376);
    F14 => "f14", Spelling::Shifted(NamedKey::F2), Some(57377);
    F15 => "f15", Spelling::Shifted(NamedKey::F3), Some(57378);
    F16 => "f16", Spelling::Shifted(NamedKey::F4), Some(57379);
    F17 => "f17", Spelling::Shifted(NamedKey::F5), Some(57380);
    F18 => "f18", Spelling::Shifted(NamedKey::F6), Some(57381);
    F19 => "f19", Spelling::Shifted(NamedKey::F7), Some(57382);
    F20 => "f20", Spelling::Shifted(NamedKey::F8), Some(57383);
    F21 => "f21", Spelling::Shifted(NamedKey::F9), Some(57384);
    F22 => "f22", Spelling::Shifted(NamedKey::F10), Some(57385);
    F23 => "f23", Spelling::Shifted(NamedKey::F11), Some(57386);
    F24 => "f24", Spelling::Shifted(NamedKey::F12), Some(57387);
    Menu => "menu", Spelling::Tilde(29), Some(57363);
    Pause => "pause", Spelling::Nothing, Some(57362);
    Print => "print", Spelling::Nothing, Some(57361);
}

/// Which protocol a key is spelled in, once the negotiation and Lisp's guess have been
/// held against each other.
///
/// The five cases the encoders branch on, and the reason the negotiated pair is not
/// enough on its own: [`cooked-key-protocol-overrides'] assumes a protocol for a program
/// that reads one without ever asking for it, and a guess must not be treated as the
/// negotiation it stands in for. A guessed protocol re-spells only the
/// [`Spelling::Literal`] keys, because `ESC [ 27 u` sent to a program that never asked
/// for it is not an Escape, it is four characters of garbage in its input.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum Protocol {
    /// Nothing negotiated and nothing assumed: a modified Return is just CR.
    Legacy,
    /// The kitty keyboard protocol, with the honoured flags the child pushed.
    Kitty(KittyFlags),
    /// xterm's modifyOtherKeys, at the level the child set.
    ModifyOther(ModifyOtherKeys),
    /// kitty assumed for a program that never negotiated it.
    GuessedKitty,
    /// modifyOtherKeys assumed for one, which is read as level 2 over the literal keys.
    GuessedModifyOther,
}

/// The protocol Lisp assumes a program speaks when the child has negotiated none.
///
/// `cooked-key-protocol-overrides' matches the foreground program, and a `:kitty' or
/// `:modify-other' action in `cooked-key-overrides' names one for a single key. Both are
/// Emacs' to decide -- they turn on a process name, a buffer-local predicate and the
/// user's configuration -- so the answer crosses the boundary rather than the question.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) enum Assumed {
    Kitty,
    ModifyOther,
}

impl Assumed {
    pub(crate) fn parse(name: &str) -> Option<Self> {
        match name {
            "kitty" => Some(Self::Kitty),
            "modify-other" => Some(Self::ModifyOther),
            _ => None,
        }
    }
}

impl Protocol {
    /// What NEGOTIATED and ASSUMED settle on together.
    ///
    /// A real negotiation is always believed over a guess about what a program probably
    /// wants, which is the rule `cooked-key-protocol-overrides' is documented by: the
    /// guess is the missing half of a negotiation nobody started, and has nothing to add
    /// to one that happened.
    fn resolve(negotiated: KeyEncoding, assumed: Option<Assumed>) -> Self {
        match negotiated {
            KeyEncoding::Kitty(kitty) => Self::Kitty(kitty.flags()),
            KeyEncoding::ModifyOtherKeys(level) => Self::ModifyOther(level),
            KeyEncoding::Legacy => match assumed {
                Some(Assumed::Kitty) => Self::GuessedKitty,
                Some(Assumed::ModifyOther) => Self::GuessedModifyOther,
                None => Self::Legacy,
            },
        }
    }

    /// The modifyOtherKeys level to apply to a literal key, if this protocol applies one.
    ///
    /// A guess has no level and is read as level 2, which re-spells the four literal keys
    /// under any modifier -- as the guess always has -- but for Shift+Tab, which even
    /// level 2 leaves as `ESC [ Z`.
    fn modify_other_level(self) -> Option<ModifyOtherKeys> {
        match self {
            Self::ModifyOther(level) => Some(level),
            Self::GuessedModifyOther => Some(ModifyOtherKeys::Level2),
            _ => None,
        }
    }

    /// Whether a literal key is spelled the kitty way, negotiated or guessed.
    fn kitty_literals(self) -> bool {
        matches!(self, Self::Kitty(_) | Self::GuessedKitty)
    }
}

/// Everything a key press is spelled from, read off the terminal in one go.
///
/// A value rather than three arguments threaded through the encoders, and taken once
/// under the lock: the protocol, DECCKM and DECKPAM are all the child's to change, and a
/// key built from one of them as it was and another as it is spells a chord neither end
/// agrees on.
struct Encoder {
    protocol: Protocol,
    /// DECCKM: the cursor keys send SS3 rather than CSI while it is set.
    app_cursor: bool,
    /// DECKPAM: the keypad sends the SS3 spelling `smkx' asked for while it is set.
    app_keypad: bool,
}

impl Term {
    /// The bytes for KEY held with MODS, spelled as this child asked, or `None` if this
    /// terminal has no spelling for the key.
    ///
    /// ASSUMED is the protocol Lisp guesses for a program that negotiated none; see
    /// [`Assumed`]. `None` comes back for Pause and Print Screen outside the kitty
    /// protocol, which is the one case where a key cooked binds has nothing to send.
    ///
    /// The readings are taken together, which is the point of asking here at all: a key
    /// spelled against the protocol as it was at the last drain is read by the child as a
    /// different key. See [`Encoder`].
    pub(crate) fn key_report(
        &self,
        key: Key,
        mods: Modifiers,
        assumed: Option<Assumed>,
    ) -> Option<Vec<u8>> {
        Encoder {
            protocol: Protocol::resolve(self.keys(), assumed),
            app_cursor: self.app_cursor(),
            app_keypad: self.state.modes.app_keypad,
        }
        .encode(key, mods)
    }
}

/// `ESC [ PARAMS FINAL`, the parameters joined with `;`.
///
/// The framing is the part that is identical every time, so it is the part with no
/// business being respelled at each call site. The parameters are strings because kitty's
/// carry colon-separated sub-fields and may be empty -- `ESC [ 97 : 65 ; ; 65 u` -- and
/// neither of those is a number.
fn csi(params: &[&str], final_byte: char) -> Vec<u8> {
    let mut out = String::from("\x1b[");
    for (i, param) in params.iter().enumerate() {
        if i > 0 {
            out.push(';');
        }
        out.push_str(param);
    }
    out.push(final_byte);
    out.into_bytes()
}

/// The single-shift-three sequence `ESC O FINAL`.
///
/// The application spelling of a cursor, keypad or function key: what the child receives
/// for `up` once `smkx` has asked for it, and the unmodified spelling of F1 through F4
/// whatever mode it is in. SS3 shifts exactly one character and so can carry no
/// parameters at all, which is why a key with a modifier to report leaves it behind.
fn ss3(final_byte: char) -> Vec<u8> {
    format!("\x1bO{final_byte}").into_bytes()
}

/// CHAR as one UTF-8 string, which is what a text key sends.
fn text(c: char) -> Vec<u8> {
    c.to_string().into_bytes()
}

/// The classical spelling of a literal key: the bytes FALLBACK names for CODE.
fn classical(code: u32, fallback: Fallback) -> Vec<u8> {
    match fallback {
        Fallback::Bytes(bytes) => bytes.as_bytes().to_vec(),
        Fallback::Code => char::from_u32(code).map_or_else(Vec::new, text),
    }
}

/// CHAR upper-cased the way Emacs' `upcase` does it, for the Shift a key event reports
/// separately from the letter it was pressed with.
///
/// A character whose upper case is more than one character -- `ß`, which Unicode maps to
/// `SS` in full case folding -- is left alone, as Emacs leaves it.
fn upcase(c: char) -> char {
    let mut upper = c.to_uppercase();
    match (upper.next(), upper.next()) {
        (Some(one), None) => one,
        _ => c,
    }
}

/// The byte Control turns CODE into, or `None` where Control makes no byte.
///
/// This is X11's table, from `XkbToControl` in libX11, and xterm's too, since xterm takes
/// the byte from `XLookupString`: `@` through `~` and the space bar are masked to their
/// low five bits, `2` is NUL, `3` through `7` are ESC through US, `8` and `?` are DEL,
/// and `/` is US. Every other character has no control form, and Control on it sends the
/// character itself.
///
/// The obvious rule, masking any character to five bits, is wrong on both sides of that
/// line. It sent `C-;` as a bare ESC, which a child reads as the start of an escape
/// sequence, and `C-/` as SI rather than the US every shell binds to undo.
/// modifyOtherKeys needs the real table for a second reason: level 1 is defined by it,
/// re-spelling exactly the chords that have no byte here.
fn control_code(code: u32) -> Option<u32> {
    match code {
        c if (u32::from(b'@')..=u32::from(b'~')).contains(&c) || c == u32::from(b' ') => {
            Some(c & 0x1f)
        }
        c if c == u32::from(b'2') => Some(0),
        c if (u32::from(b'3')..=u32::from(b'7')).contains(&c) => Some(27 + (c - u32::from(b'3'))),
        c if c == u32::from(b'8') || c == u32::from(b'?') => Some(127),
        c if c == u32::from(b'/') => Some(31),
        _ => None,
    }
}

/// Whether CODE may be reported as associated text: not a C0 or C1 control.
fn is_text(code: u32) -> bool {
    code >= 0x20 && !(0x7f..=0x9f).contains(&code)
}

impl Encoder {
    fn encode(&self, key: Key, mods: Modifiers) -> Option<Vec<u8>> {
        match (self.protocol, key) {
            // ESC as a terminal frame delivers it goes as the byte under every protocol;
            // see [`Key::LooseEscape`].
            (_, Key::LooseEscape) => Some(mods.meta_prefixed(b"\x1b".to_vec())),
            (Protocol::Kitty(flags), Key::Named(key)) => self.kitty_entry(key, mods, flags),
            (Protocol::Kitty(flags), Key::Text(c)) => Some(self.kitty_text(c, mods, flags)),
            (Protocol::ModifyOther(level), Key::Text(c)) => {
                Some(self.modify_other_text(c, mods, level))
            }
            (_, Key::Named(key)) => self.entry(key, mods),
            (_, Key::Text(c)) => Some(self.text_key(c, mods)),
        }
    }

    /// `ESC [ FINAL` for a cursor key, or `ESC O FINAL` while DECCKM is set.
    fn cursor_key(&self, final_byte: char) -> Vec<u8> {
        if self.app_cursor {
            ss3(final_byte)
        } else {
            csi(&[], final_byte)
        }
    }

    /// The bytes for the table row KEY held with MODS, in every encoding but a negotiated
    /// kitty.
    ///
    /// A function of its own rather than the body of [`Encoder::encode`] because the
    /// keypad answers by deferring: a modified `kp-home` is a modified `home`, and saying
    /// so means dispatching on that row from inside this one.
    fn entry(&self, key: NamedKey, mods: Modifiers) -> Option<Vec<u8>> {
        let param = mods.param();
        let modified = param > 1;
        let param = param.to_string();
        match key.spelling() {
            Spelling::Csi(final_byte) => Some(if modified {
                csi(&["1", &param], final_byte)
            } else {
                self.cursor_key(final_byte)
            }),
            // F1 to F4 leave SS3 behind the moment they are modified.
            Spelling::Ss3(final_byte) => Some(if modified {
                csi(&["1", &param], final_byte)
            } else {
                ss3(final_byte)
            }),
            Spelling::Tilde(n) => Some(if modified {
                csi(&[&n.to_string(), &param], '~')
            } else {
                csi(&[&n.to_string()], '~')
            }),
            Spelling::Keypad { app, plain, .. } => match plain {
                // The whole of what `smkx' buys: `ESC O w' for the upper-left key, which
                // is `ka1', and eighteen more like it.
                _ if !modified && self.app_keypad => Some(ss3(app)),
                Plain::Like(stands_for) => self.entry(stands_for, mods),
                Plain::Cap(cap) => Some(self.literal(cap as u32, text(cap), mods)),
            },
            Spelling::Literal { code, fallback } => {
                Some(self.literal(code, classical(code, fallback), mods))
            }
            Spelling::Shifted(shifted) => self.entry(shifted, mods.with(Modifiers::SHIFT)),
            Spelling::Nothing => None,
        }
    }

    /// The bytes for a key whose modified form exists only in a negotiated protocol:
    /// Return, Tab, Escape, Backspace, Shift+Tab and the keypad's character caps.
    ///
    /// CODE is the code point kitty and modifyOtherKeys name the key by, and FALLBACK its
    /// classical spelling. Unmodified, and wherever the child has negotiated nothing that
    /// covers the key, the fallback is what goes: that is what every terminal has always
    /// sent and what every program still understands.
    fn literal(&self, code: u32, fallback: Vec<u8>, mods: Modifiers) -> Vec<u8> {
        if mods.param() == 1 {
            return mods.meta_prefixed(fallback);
        }
        if let Some(level) = self.protocol.modify_other_level() {
            if let Some(spelled) = modify_other_mods(level, code, mods) {
                return csi(
                    &["27", &spelled.param().to_string(), &code.to_string()],
                    '~',
                );
            }
        } else if self.protocol.kitty_literals() {
            return csi(&[&code.to_string(), &mods.param().to_string()], 'u');
        }
        // Nothing negotiated, or a key the level leaves alone: Meta has a classical
        // spelling, the rest do not.
        mods.meta_prefixed(fallback)
    }

    /// The bytes for the text key CHAR held with MODS, when no protocol spells it.
    ///
    /// CHAR is the unshifted key, as `event-basic-type` reports it. Shift becomes a
    /// capital, Control the byte [`control_code`] names or nothing, and Meta a leading
    /// ESC.
    fn text_key(&self, c: char, mods: Modifiers) -> Vec<u8> {
        let c = if mods.holds(Modifiers::SHIFT) {
            upcase(c)
        } else {
            c
        };
        let c = mods
            .holds(Modifiers::CONTROL)
            .then(|| control_code(c as u32).and_then(char::from_u32))
            .flatten()
            .unwrap_or(c);
        mods.meta_prefixed(text(c))
    }

    /// The bytes for the text key CHAR under a negotiated modifyOtherKeys LEVEL.
    ///
    /// `ESC [ 27 ; PARAM ; CODE ~` where [`modify_other_mods`] says the level covers the
    /// chord, and its classical bytes where not.
    ///
    /// Narrower than xterm where an Emacs event lacks the fact: shift+1 arrives as a bare
    /// `!`, so Control+Shift+1 is sent as Control+`!` with parameter 5 rather than
    /// xterm's 6.
    fn modify_other_text(&self, c: char, mods: Modifiers, level: ModifyOtherKeys) -> Vec<u8> {
        let code = if mods.holds(Modifiers::SHIFT) {
            upcase(c)
        } else {
            c
        } as u32;
        match modify_other_mods(level, code, mods) {
            Some(spelled) => csi(
                &["27", &spelled.param().to_string(), &code.to_string()],
                '~',
            ),
            None => self.text_key(c, mods),
        }
    }

    /// `ESC [ CODE : SHIFTED ; PARAM ; TEXT u`, each optional part left out when it has
    /// nothing to say.
    ///
    /// SHIFTED is the shifted key bit 4 reports, and TEXT the character bit 16 reports.
    /// PARAM is omitted at 1, which is its default, unless TEXT follows it -- then its
    /// field is left empty rather than dropped, so that the text is not read as a
    /// modifier. kitty's own example is shift+a, `ESC [ 97 ; 2 ; 65 u`, and the same key
    /// with no modifier would be `ESC [ 97 ; ; 97 u`.
    ///
    /// The base-layout key, which the protocol puts after SHIFTED, is never sent: it
    /// names the physical key on a US layout, and an Emacs event carries no physical key.
    /// The protocol makes both alternates optional.
    fn kitty_csi_u(
        &self,
        code: u32,
        mods: Modifiers,
        shifted: Option<u32>,
        associated: Option<u32>,
    ) -> Vec<u8> {
        let key = match shifted {
            Some(shifted) => format!("{code}:{shifted}"),
            None => code.to_string(),
        };
        let param = mods.param();
        match associated {
            Some(associated) => {
                let param = if param > 1 {
                    param.to_string()
                } else {
                    String::new()
                };
                csi(&[&key, &param, &associated.to_string()], 'u')
            }
            None if param > 1 => csi(&[&key, &param.to_string()], 'u'),
            None => csi(&[&key], 'u'),
        }
    }

    /// The bytes for the text key CHAR under a negotiated kitty protocol.
    ///
    /// CHAR is the unshifted key. Plain text, shifted or not, goes as the text itself
    /// unless bit 8 asked for every key as an escape code; Control or Meta makes it an
    /// escape code under bit 1 alone, which is what disambiguation means for a text key.
    /// kitty's table for `i` is the whole of the rule: `i`, `I`, then `ESC [ 105 ; 3 u`
    /// for alt, `105 ; 5` for ctrl, `105 ; 4` for shift+alt, `105 ; 7` for ctrl+alt and
    /// `105 ; 6` for ctrl+shift.
    ///
    /// Associated text is reported only where the key still produces text, which any
    /// modifier but Shift prevents. The shifted key is reported only with Shift held and
    /// only where shifting changed something. Both are narrower than kitty for a key
    /// whose shifted glyph is not its upper case: Emacs reports shift+1 as a bare `!`
    /// with no Shift, so it is sent as the key `!`, and nothing here can recover that it
    /// was a `1` -- a fact about the keyboard layout an Emacs event does not carry.
    fn kitty_text(&self, c: char, mods: Modifiers, flags: KittyFlags) -> Vec<u8> {
        let textless = mods.textless();
        let shift = mods.holds(Modifiers::SHIFT);
        let shifted = if shift { upcase(c) } else { c };
        let all = flags.intersects(KittyFlags::REPORT_ALL_KEYS);
        if !textless && !all {
            return text(shifted);
        }
        self.kitty_csi_u(
            c as u32,
            mods,
            (flags.intersects(KittyFlags::REPORT_ALTERNATE_KEYS) && shift && shifted != c)
                .then_some(shifted as u32),
            (flags.intersects(KittyFlags::REPORT_TEXT) && !textless && is_text(shifted as u32))
                .then_some(shifted as u32),
        )
    }

    /// The bytes for the table row KEY under a negotiated kitty protocol.
    ///
    /// This departs from [`Encoder::entry`] in five places, each of them the protocol's
    /// rule that a key which produces no text is `CSI NUMBER ; MOD u` or
    /// `CSI 1 ; MOD FINAL`:
    ///
    /// A key with a functional code point is that code point, so F13 is `ESC [ 57376 u`
    /// rather than the Shift+F1 terminfo calls it.
    ///
    /// Escape is always an escape code, `ESC [ 27 u` unmodified. Return, Tab and
    /// Backspace stay bare bytes unmodified, so that `reset` can still be typed after a
    /// program dies with the mode on -- until bit 8, which takes that away too.
    ///
    /// F1 to F4 and the cursor keys drop SS3, even under DECCKM and even unmodified. F3
    /// is `ESC [ 13 ~`, since `ESC [ 1 ; MOD R` is a cursor position report. The keypad
    /// is a set of keys of its own.
    fn kitty_entry(&self, key: NamedKey, mods: Modifiers, flags: KittyFlags) -> Option<Vec<u8>> {
        let param = mods.param();
        let modified = param > 1;
        let all = flags.intersects(KittyFlags::REPORT_ALL_KEYS);
        if let Some(code) = key.functional_code() {
            return Some(self.kitty_csi_u(code, mods, None, None));
        }
        if key == NamedKey::Escape {
            return Some(self.kitty_csi_u(27, mods, None, None));
        }
        match key.spelling() {
            Spelling::Literal { code, fallback } => Some(if modified || all {
                self.kitty_csi_u(code, mods, None, None)
            } else {
                classical(code, fallback)
            }),
            _ if key == NamedKey::F3 => Some(if modified {
                csi(&["13", &param.to_string()], '~')
            } else {
                csi(&["13"], '~')
            }),
            Spelling::Csi(final_byte) | Spelling::Ss3(final_byte) => Some(if modified {
                csi(&["1", &param.to_string()], final_byte)
            } else {
                csi(&[], final_byte)
            }),
            Spelling::Keypad { plain, kitty, .. } => {
                let cap = match plain {
                    Plain::Cap(cap) => Some(cap),
                    Plain::Like(_) => None,
                };
                let types = cap.is_some_and(|cap| is_text(cap as u32)) && !mods.textless();
                match cap {
                    // A printable character on the cap types that character, shifted or
                    // not, as a main-keyboard text key would.
                    Some(cap) if types && !all => Some(text(cap)),
                    _ => Some(
                        self.kitty_csi_u(
                            kitty,
                            mods,
                            None,
                            (flags.intersects(KittyFlags::REPORT_TEXT) && types)
                                .then(|| cap.map(|cap| cap as u32))
                                .flatten(),
                        ),
                    ),
                }
            }
            _ => self.entry(key, mods),
        }
    }
}

/// The modifiers modifyOtherKeys LEVEL spells CODE with, held with MODS, or `None`.
///
/// `None` means the key is not re-spelled and goes as its classical bytes. Otherwise the
/// answer is the modifiers the parameter of `ESC [ 27 ; PARAM ; CODE ~` is made from,
/// which are MODS less what xterm leaves out of it. Super and Hyper are always left out,
/// since xterm's `allowedCharModifiers` keeps only Shift, Control and Alt: `s-a` is a
/// plain `a` at either level.
///
/// CODE is the character the key types, shifted -- `A` for shift+a, which is the keysym
/// xterm reads and the number it sends -- or the code point of a literal key. The rules
/// are `ModifyOtherKeys`, `allowedCharModifiers` and `filterAltMeta` in xterm's input.c
/// (patch 411), checked against the us-pc105 table in xterm's modified-keys FAQ.
///
/// Tab with Shift held is Shift+Tab, whichever name Emacs gave it, because that is the
/// key X reports as `ISO_Left_Tab` and xterm sends as `ESC [ Z` at both levels. Level 2
/// re-spells it only when another modifier is held beside Shift, so `C-S-<tab>` is
/// `ESC [ 27 ; 6 ; 9 ~` while Shift+Tab alone stays `ESC [ Z`, which is what a program
/// that reads `kcbt` is waiting for.
///
/// Level 2 re-spells any key held with Control or Meta. Shift alone re-spells only the
/// keys Control would otherwise turn into a byte -- the letters and `@[\]^_` with their
/// shifted partners -- and the space bar, since shift+1 already types a `!` nobody could
/// mistake. So shift+a is `ESC [ 27 ; 2 ; 65 ~` and `!` stays `!`. Return, Tab, Escape
/// and Backspace are re-spelled under any modifier. xterm leaves Control+Backspace alone,
/// since Control there flips Backspace between BS and DEL, a switch cooked does not have;
/// spelling it out loses nothing a child that asked for this can misread.
///
/// Level 1 leaves alone every chord that already means something. Control re-spells a key
/// only where [`control_code`] finds no byte for it, so `C-a` stays SOH while `C-;`
/// becomes `ESC [ 27 ; 5 ; 59 ~`. Shift alone re-spells nothing, and neither does Meta:
/// xterm's manual says Meta at this level follows metaSendsEscape, which is how cooked
/// always spells it.
///
/// Return and Tab are re-spelled under Shift or Control, except that Meta takes Control
/// and itself out of the chord first, as `filterAltMeta` does for the sake of Emacs' own
/// `C-M-RET`. So `C-M-<return>` is `ESC CR` and `M-S-<return>` is `ESC [ 27 ; 2 ; 13 ~`.
/// Escape is re-spelled only with Meta and Control or Shift held together, which is what
/// `filterAltMeta` leaves of a chord on a key that is its own control byte; Backspace
/// never is.
///
/// Where any other chord is re-spelled, Meta still counts in its parameter, so `C-M-;` is
/// `ESC [ 27 ; 7 ; 59 ~`. That is xterm with its default resources, where metaSendsEscape
/// is off. With it on xterm drops Meta from the parameter too, and the chord arrives as
/// `C-;`: cooked keeps the modifier rather than lose it. Where a chord is not re-spelled,
/// Meta is the leading ESC it always was.
fn modify_other_mods(level: ModifyOtherKeys, code: u32, mods: Modifiers) -> Option<Modifiers> {
    let mods = mods.without(Modifiers::SUPER.with(Modifiers::HYPER));
    let ctrl = mods.holds(Modifiers::CONTROL);
    let shift = mods.holds(Modifiers::SHIFT);
    let meta = mods.holds(Modifiers::META);
    match level {
        ModifyOtherKeys::Level2 => {
            let respelled = match code {
                9 if shift => ctrl || meta,
                9 | 13 | 27 | 127 => ctrl || shift || meta,
                _ => ctrl || meta || (shift && ((0x40..=0x7f).contains(&code) || code == 0x20)),
            };
            respelled.then_some(mods)
        }
        ModifyOtherKeys::Level1 => match code {
            9 if shift => None,
            9 | 13 => {
                if meta {
                    shift.then_some(Modifiers::SHIFT)
                } else {
                    (ctrl || shift).then_some(mods)
                }
            }
            27 => (meta && (ctrl || shift)).then_some(mods),
            127 => None,
            _ => (ctrl && control_code(code).is_none()).then_some(mods),
        },
    }
}
