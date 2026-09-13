//! The pen as the child sets it, and the ids it writes cells with.

use super::super::cell::{Pen, Style};
use super::super::link::LinkId;

/// The rendition and open hyperlink the child has set, with the ids they resolve to.
///
/// The ids are cached because the print path asks for them once per character or run,
/// while the pen changes only when an escape sequence changes it: a `cat` of a coloured
/// log writes thousands of characters between two `SGR`s, and none of them should pay
/// for comparing the whole rendition against the one the ids were looked up for.
///
/// The fields are private so that every change goes through a method that drops the
/// cached ids. That makes a stale cache a compile error at any new mutation site rather
/// than a wrong colour at runtime: there is no way to write to the pen and keep the ids.
#[derive(Debug, Default)]
pub(super) struct PenState {
    style: Style,
    /// The `OSC 8` hyperlink the child currently has open, if any.
    ///
    /// Written into every cell printed while it is open, beside the rendition, but it is
    /// not an SGR attribute, so no rendition change closes it. Terminals hold it open until
    /// an explicit `OSC 8 ; ; ST`, which is what lets a program colour a link as it prints
    /// it. One for both screens, like the rendition: an open hyperlink belongs to the byte
    /// stream, so a child that opens one and then takes the alternate screen goes on
    /// writing it there.
    link: Option<LinkId>,
    /// What [`State::pen`](super::State::pen) resolved the pen to, until the pen changes.
    ids: Option<Pen>,
}

impl PenState {
    pub(super) fn style(&self) -> Style {
        self.style
    }

    pub(super) fn link(&self) -> Option<LinkId> {
        self.link
    }

    pub(super) fn set_style(&mut self, style: Style) {
        self.ids = None;
        self.style = style;
    }

    /// The rendition to change in place, for the decoders that edit it field by field.
    ///
    /// The ids are dropped before the borrow is handed out, whether or not the caller
    /// ends up changing anything; an `SGR 0` on a pen that is already default costs one
    /// lookup, which the store's recent-rendition check answers without hashing.
    pub(super) fn style_mut(&mut self) -> &mut Style {
        self.ids = None;
        &mut self.style
    }

    pub(super) fn set_link(&mut self, link: Option<LinkId>) {
        self.ids = None;
        self.link = link;
    }

    /// The ids the pen resolved to, if nothing has changed it since.
    #[inline]
    pub(super) fn ids(&self) -> Option<Pen> {
        self.ids
    }

    /// Remember the ids the pen as it stands resolved to.
    pub(super) fn remember(&mut self, pen: Pen) {
        self.ids = Some(pen);
    }

    /// Forget the ids without changing the pen, for when the store may have freed them.
    pub(super) fn forget_ids(&mut self) {
        self.ids = None;
    }
}
