//! Terminal emulation: grid, styling, and the VT parser front end.

pub mod cell;
pub mod screen;
pub mod term;

pub use cell::{Attrs, Cell, Color, Row, Run, Style};
pub use screen::{Cursor, Erase, Screen};
pub use term::{BACKLOG_HIGH_WATER, Delta, Event, KeyEncoding, Mouse, Scrolled, Term, osc_reply};
