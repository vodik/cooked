//! Terminal emulation: grid, styling, and the VT parser front end.

pub mod cell;
pub mod glyph;
pub mod parser;
pub mod screen;
pub mod term;

pub use cell::{Attrs, Cell, Color, Row, Run, Style};
pub use glyph::BoxGlyph;
pub use screen::{Cursor, Erase, Screen};
pub use term::{
    Anchor, BACKLOG_HIGH_WATER, CursorShape, Delta, Event, KeyEncoding, Mouse, SYNC_TIMEOUT,
    Scrolled, Term, osc_reply,
};
