//! The primary screen and the alternate one, and the state kept once for each.
//!
//! A terminal has two grids and shows one of them. Several pieces of state follow the
//! grid rather than the byte stream -- the kitty keyboard flag stack, the character sets
//! DECSC saved -- so they come in pairs too. [`PerScreen`] is that pair, indexed by the
//! [`ScreenId`] that says which grid is showing.

use super::promote::Promotion;
use std::ops::{Index, IndexMut};

/// Which of the two grids something belongs to, or which one is showing.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(super) enum ScreenId {
    /// The transcript: rows that scroll off it become Emacs' scrollback.
    #[default]
    Primary,
    /// A full-screen program's frame: nothing on it is ever history.
    Alternate,
}

impl ScreenId {
    pub(super) fn is_alternate(self) -> bool {
        self == Self::Alternate
    }
}

/// Which grid the child is writing to, and the promotion that cannot outlive it.
///
/// A promotion is a claim about rows that left *the screen being shown* since the last
/// drain and are still the rows at the top of what Emacs holds; see [`Promotion`]. Showing
/// the other grid ends the claim, and it has to end at the switch rather than at the next
/// drain: a `CSI ?1049h` / `CSI ?1049l` round trip with no drain between it would
/// otherwise promote rows that go as text today, and a row leaving after the switch would
/// be matched against rows the other grid drew.
///
/// So the two are one value. [`Shown::show`] is the only way to change screens and it
/// drops the promotion, which is why nothing in `csi.rs`, `osc.rs` or `State::set_alt` has
/// to remember to: there is no order of statements that gets it wrong.
#[derive(Debug, Default)]
pub(super) struct Shown {
    screen: ScreenId,
    promotion: Promotion,
}

impl Shown {
    /// Which of the two grids is being written to and shown.
    pub(super) fn id(&self) -> ScreenId {
        self.screen
    }

    pub(super) fn is_alternate(&self) -> bool {
        self.screen.is_alternate()
    }

    /// Show SCREEN, ending the promotion, and say whether that changed which screen is up.
    ///
    /// The answer is the guard the caller needs and cannot get afterwards: a second
    /// `CSI ?1049h` while the alternate screen is already up must not erase it again.
    #[must_use]
    pub(super) fn show(&mut self, screen: ScreenId) -> bool {
        if self.screen == screen {
            return false;
        }
        self.screen = screen;
        self.promotion = Promotion::default();
        true
    }

    /// The rows this screen's departures can still hand Emacs as text it already holds.
    pub(super) fn promotion(&mut self) -> &mut Promotion {
        &mut self.promotion
    }
}

/// One `T` for the primary screen and one for the alternate.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(super) struct PerScreen<T> {
    pub(super) primary: T,
    pub(super) alternate: T,
}

impl<T> PerScreen<T> {
    /// Both values, primary first, for the operations that apply to each screen alike.
    pub(super) fn each(&self) -> [&T; 2] {
        [&self.primary, &self.alternate]
    }

    pub(super) fn each_mut(&mut self) -> [&mut T; 2] {
        [&mut self.primary, &mut self.alternate]
    }
}

impl<T> Index<ScreenId> for PerScreen<T> {
    type Output = T;

    fn index(&self, id: ScreenId) -> &T {
        match id {
            ScreenId::Primary => &self.primary,
            ScreenId::Alternate => &self.alternate,
        }
    }
}

impl<T> IndexMut<ScreenId> for PerScreen<T> {
    fn index_mut(&mut self, id: ScreenId) -> &mut T {
        match id {
            ScreenId::Primary => &mut self.primary,
            ScreenId::Alternate => &mut self.alternate,
        }
    }
}
