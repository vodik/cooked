//! The primary screen and the alternate one, and the state kept once for each.
//!
//! A terminal has two grids and shows one of them. Several pieces of state follow the
//! grid rather than the byte stream -- the kitty keyboard flag stack, the character sets
//! DECSC saved -- so they come in pairs too. [`PerScreen`] is that pair, indexed by the
//! [`ScreenId`] that says which grid is showing.

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
