//! The VT front end, end to end, one file per area, with the helpers they share here.

use super::*;
use crate::emu::cell::{Attrs, Color};
use crate::emu::cell::{Deco, Extra};
use crate::emu::image::Placement;
/// Base64, so the tests spell a kitty transmission the way a client would.
use crate::emu::kitty::encode_base64 as b64;
use crate::emu::link::LinkId;
use crate::emu::style::StyleId;

fn term(rows: usize, cols: usize, input: &[u8]) -> Term {
    let mut t = Term::new(rows, cols);
    t.feed(input);
    t
}

fn runs_text(line: &Scrolled) -> String {
    line.runs.iter().map(|r| r.text.as_str()).collect()
}

fn text(t: &Term, row: usize) -> String {
    t.screen().row(row).unwrap().to_text()
}

fn links(t: &Term, row: usize) -> Vec<(String, Option<LinkId>)> {
    t.screen()
        .row(row)
        .unwrap()
        .runs()
        .into_iter()
        .map(|r| (r.text, r.link))
        .collect()
}

fn with_metrics(rows: usize, cols: usize) -> Term {
    let mut t = Term::new(rows, cols);
    t.set_cell_metrics(CellMetrics::new(10, 20));
    t
}

/// Every reply among EVENTS, as text, in the order they were queued.
fn replies(events: Vec<Event>) -> Vec<String> {
    events
        .into_iter()
        .filter_map(|e| match e {
            Event::Reply(bytes) => Some(String::from_utf8(bytes).unwrap()),
            _ => None,
        })
        .collect()
}

/// Every reply the next drain of T carries, as text.
fn reply_strings(t: &mut Term) -> Vec<String> {
    replies(t.drain().events)
}

/// The rendition of the run on row 0 whose text is TEXT.
fn run_style(t: &Term, text: &str) -> Style {
    let runs = t.screen().row(0).unwrap().runs();
    let run = runs.iter().find(|r| r.text == text).unwrap();
    t.style(run.style)
}

/// The rendition of run INDEX of ROW.
fn run_style_at(t: &Term, row: usize, index: usize) -> Style {
    t.style(t.screen().row(row).unwrap().runs()[index].style)
}

/// The rendition of the cell at ROW, COL.
fn cell_style(t: &Term, row: usize, col: usize) -> Style {
    t.style(t.screen().row(row).unwrap().cells()[col].style)
}

mod decrqss;
mod front;
mod images;
mod keyboard;
mod marks;
mod modes;
mod osc;
mod replies;
mod reports;
mod screen;
mod sgr;
mod terminfo;
mod text;
