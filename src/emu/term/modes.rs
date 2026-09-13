//! The modes a child can set, reset and ask about, by name.
//!
//! Every private mode cooked has an answer for is a [`DecMode`] variant, including the
//! ones it declines. That makes the DECRQM table an exhaustive match: a mode added here
//! cannot be settable and yet report itself unknown, because the compiler asks what it
//! answers.

/// DECRQM's answer about a mode, as the protocol numbers it.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u8)]
pub(super) enum ModeReport {
    /// The mode is not one we implement, and the child should stop asking.
    Unknown = 0,
    Set = 1,
    Reset = 2,
    /// Permanently on: the behaviour the mode asks for is the only one there is, so a
    /// reset would be a lie. Mode 2027 and 1036, Meta sending ESC, answer this.
    PermanentlySet = 3,
    /// Deliberately not implemented -- this is how a child learns that without guessing.
    PermanentlyReset = 4,
}

impl From<bool> for ModeReport {
    fn from(on: bool) -> Self {
        if on { Self::Set } else { Self::Reset }
    }
}

impl std::fmt::Display for ModeReport {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{}", *self as u8)
    }
}

/// Declare a mode enum whose discriminants are the protocol's numbers, with the
/// conversion from a parameter generated from the same list.
macro_rules! numbered_modes {
    ($(#[$meta:meta])* $name:ident { $($(#[$doc:meta])* $variant:ident = $number:literal,)* }) => {
        $(#[$meta])*
        #[derive(Debug, Clone, Copy, PartialEq, Eq)]
        #[repr(u16)]
        pub(super) enum $name {
            $($(#[$doc])* $variant = $number,)*
        }

        impl TryFrom<u16> for $name {
            type Error = u16;

            fn try_from(number: u16) -> Result<Self, u16> {
                match number {
                    $($number => Ok(Self::$variant),)*
                    other => Err(other),
                }
            }
        }
    };
}

numbered_modes! {
    /// A DEC private mode, `CSI ? Pm h/l`, that cooked implements or declines.
    ///
    /// A number with no variant is one cooked has never heard of: a set or reset of it
    /// does nothing and DECRQM answers 0.
    DecMode {
        /// DECCKM: cursor keys send SS3.
        AppCursor = 1,
        /// DECCOLM, 132 columns. Declined: a buffer has no column mode, but `is2` and
        /// `rs2` reset it, so a child reading the entry has seen the number.
        Columns132 = 3,
        /// DECSCLM, smooth scroll. Declined for the same reason as 3.
        SmoothScroll = 4,
        /// DECSCNM: the whole screen in reverse video.
        ReverseScreen = 5,
        /// DECOM: cursor addressing relative to the scroll region.
        Origin = 6,
        /// DECAWM: autowrap.
        Autowrap = 7,
        /// Cursor blink. Declined: blinking is `blink-cursor-mode`, the user's setting.
        CursorBlink = 12,
        /// DECTCEM: the cursor is visible.
        CursorVisible = 25,
        /// Reverse wraparound. Declined: nothing lets a backspace cross into the row
        /// above, which is why the entry has no `bw`.
        ReverseWrap = 45,
        /// The alternate screen, without the clear or the cursor save.
        AltScreenLegacy = 47,
        /// DECNKM: application keypad.
        AppKeypad = 66,
        /// DECBKM, backarrow sends BS. Declined: `kbs=^?` fixes it at DEL.
        BackarrowSendsBackspace = 67,
        /// DECLRMM, left and right margins. Declined.
        LeftRightMargins = 69,
        /// Mouse reports of presses and releases; see [`MouseTracking`](super::MouseTracking).
        MouseClick = 1000,
        /// Mouse reports of presses, releases and motion with a button held.
        MouseDrag = 1002,
        /// Mouse reports of all motion.
        MouseMotion = 1003,
        /// `CSI I` and `CSI O` on focus changes.
        FocusEvents = 1004,
        /// The UTF-8 mouse encoding. Declined: superseded by 1006, and ambiguous.
        MouseUtf8 = 1005,
        /// SGR mouse reports.
        MouseSgr = 1006,
        /// On the alternate screen, the wheel sends cursor keys.
        AltScroll = 1007,
        /// The urxvt mouse encoding. Declined, as 1005.
        MouseUrxvt = 1015,
        /// SGR mouse reports in pixels.
        MouseSgrPixels = 1016,
        /// Eight-bit meta. Declined: Meta sends ESC.
        EightBitMeta = 1034,
        /// Meta sends ESC. Permanently set: it is how every key cooked does not
        /// re-encode spells Meta, and nothing a child sends turns that off.
        MetaSendsEscape = 1036,
        /// Alt sends ESC. Declined: where Alt and Meta are different keys Emacs reports
        /// an `alt` modifier cooked does not spell, and elsewhere 1036 answers for it.
        AltSendsEscape = 1039,
        /// Extended reverse wraparound. Declined, as 45.
        ReverseWrapExtended = 1045,
        /// The alternate screen, cleared on entry.
        AltScreen = 1047,
        /// DECSC and DECRC as a mode.
        SaveCursor = 1048,
        /// Save the cursor, switch to the alternate screen, and the reverse on reset.
        AltScreenSaveCursor = 1049,
        /// Bracketed paste.
        BracketedPaste = 2004,
        /// Synchronized output.
        SynchronizedOutput = 2026,
        /// Grapheme cluster segmentation. Permanently set: the segmenter is how every
        /// character reaches the grid.
        GraphemeClusters = 2027,
        /// Colour scheme change reports.
        ColorSchemeUpdates = 2031,
        /// In-band size reports.
        SizeReports = 2048,
    }
}

impl DecMode {
    /// The mode whose XTSAVE slot this one shares.
    ///
    /// xterm keeps one saved value for the tracking modes (`DP_X_MOUSE`), one for the
    /// coordinate encodings (`DP_X_EXT_MOUSE`) and one for the three alternate screen
    /// modes (`DP_X_ALTBUF`), because each group is one choice: saving under 1000 and
    /// restoring under 1003 puts back the same tracking, and saving under 47 and
    /// restoring under 1049 puts back the same screen. Every other mode has a slot of its
    /// own.
    pub(super) fn save_slot(self) -> Self {
        match self {
            Self::MouseClick | Self::MouseDrag | Self::MouseMotion => Self::MouseClick,
            Self::AltScreenLegacy | Self::AltScreen | Self::AltScreenSaveCursor => Self::AltScreen,
            Self::MouseSgr | Self::MouseSgrPixels => Self::MouseSgr,
            other => other,
        }
    }
}

numbered_modes! {
    /// An ANSI mode, `CSI Pm h/l`, that cooked implements or has an answer about.
    ///
    /// Only two are real. The rest are the ECMA-48 modes xterm's DECRQM answers for, and
    /// each is either always in the one state cooked has or describes a block-mode
    /// terminal that has never existed here; a set or reset of any of them does nothing.
    AnsiMode {
        /// GATM, guarded area transfer. Declined: there are no guarded areas.
        GuardedAreaTransfer = 1,
        /// KAM, keyboard action: a set locks the keyboard. Declined: nothing a child sends
        /// takes the keyboard away from Emacs.
        KeyboardAction = 2,
        /// CRM, control representation: controls shown rather than acted on. Declined.
        ControlRepresentation = 3,
        /// IRM: insert rather than replace.
        Insert = 4,
        /// SRTM, status report transfer. Declined.
        StatusReportTransfer = 5,
        /// VEM, vertical editing. Declined.
        VerticalEditing = 7,
        /// HEM, horizontal editing. Declined.
        HorizontalEditing = 10,
        /// PUM, positioning unit. Declined: positions are always in cells.
        PositioningUnit = 11,
        /// SRM, send/receive. Permanently set, which is "no local echo": a key reaches
        /// the child and is shown only if the child echoes it.
        SendReceive = 12,
        /// FEAM, format effector action. Declined.
        FormatEffectorAction = 13,
        /// FETM, format effector transfer. Declined.
        FormatEffectorTransfer = 14,
        /// MATM, multiple area transfer. Declined.
        MultipleAreaTransfer = 15,
        /// TTM, transfer termination. Declined.
        TransferTermination = 16,
        /// SATM, selected area transfer. Declined.
        SelectedAreaTransfer = 17,
        /// TSM, tabulation stop. Declined.
        TabulationStop = 18,
        /// EBM, editing boundary. Declined.
        EditingBoundary = 19,
        /// LNM: LF also returns the carriage.
        Newline = 20,
    }
}
