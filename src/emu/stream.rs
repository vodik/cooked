//! A VT filter with no grid behind it: bytes in, styled text out.
//!
//! The second [`Perform`] impl in the crate, and the one that is not a terminal. Its
//! consumer is `cooked-comint.el', which hangs it on `comint-preoutput-filter-functions'
//! so that every comint buffer in Emacs -- `M-x shell', `run-python',
//! `sql-interactive-mode', `gud' -- gets a real VT parser where it has an
//! `ansi-color'-shaped regexp today. comint owns the buffer, the process mark, the input
//! region and the field boundaries; this owns nothing but a reading of the bytes.
//!
//! ## Why not the grid
//!
//! `cooked-process.el' runs a *headless* session for `compile' and friends, but a grid
//! retires a row only when it scrolls off the top, so a session eight rows tall hands its
//! consumer the first line when the ninth arrives. That is fine for a build log and fatal
//! for a shell, which would sit eight lines behind its own prompt.
//!
//! So this is a third mode, between a grid and ghostel's pass-everything-through: **one
//! row of cells, and no rows at all above or below it**. A line retires the instant its
//! `\n` arrives, which is no latency at all, and the open line is emitted at the end of
//! every feed, so an unterminated prompt (`read -p', `$ ') shows up the moment it is
//! written rather than when the next line ends.
//!
//! ## Why a line buffer rather than passing CR and BS through
//!
//! Passing them through is what ghostel's `comint_filter.zig' does, and it is wrong:
//!
//! ```text
//!   $ printf 'abcdefghij\rXYZ\n'
//!   XYZ           # comint: the CR deleted to the start of the line
//!   XYZdefghij    # a terminal: the CR moved the cursor and XYZ overwrote
//! ```
//!
//! `comint-carriage-motion' *deletes* where a terminal *overwrites*, and once `CSI K' is
//! dropped on the floor as well there is nothing left to tell "the child erased the line
//! and reprinted it" from "the child rewrote part of it". Progress bars survive that by
//! accident, because they rewrite the whole line every time; partial overwrites do not.
//!
//! A one-row line buffer resolves all of it -- CR, BS, TAB, `CSI K', `CSI G', `CSI X',
//! `CSI P', `CSI @' -- and leaves the consumer with text that says what the child meant.
//! `cooked-comint-mode' therefore sets `comint-inhibit-carriage-motion'.
//!
//! ## What is *not* here, and why that is the point
//!
//! No cursor addressing between rows, no scroll region, no alternate screen, no height,
//! no width. A full-screen program run in a comint buffer is not a thing this can
//! rescue, and the sequences that would matter to one are ignored rather than
//! half-implemented -- `CSI H` and `CSI J` included. What a stream of *lines* can mean
//! is resolved exactly; everything else is dropped, deliberately and in one place
//! ([`Stream::csi_dispatch`]).
//!
//! ## The one thing it cannot express
//!
//! An open line is emitted before it is finished, so the text Emacs holds for it can go
//! stale: a `\r` that rewrites what was already handed over has to be *taken back*.
//! [`Filter::feed`] reports that as a retraction -- how many characters immediately
//! before the insertion point are no longer true -- and the Lisp side deletes exactly
//! that many, having first checked that those characters are still the ones it emitted.
//! When they are not (comint inserted the user's input in between, which is the ordinary
//! case at every prompt), the caller says so by passing `retract: false`, and the open line
//! is given up on without a word: the line the buffer now ends in is the user's, and what
//! the child writes next starts a line of its own.

use super::cell::{BLANK, CONTINUATION, Cell, Color, Runs, Style};
use super::link::{LinkId, LinkStore, MAX_URI_LEN};
use super::parser::{Params, Parser, Perform};
use super::sgr;
use super::style::{StyleId, StyleStore};
use super::term::osc::validated_text;
use super::text::{self, Segmenter, Step, Width};

/// Columns one logical line may reach before it is retired to keep it bounded.
///
/// A line buffer has no width to stop it growing, and a child that never sends a
/// newline is not hypothetical -- `find / -print0' is one, and a corrupted stream is
/// another. 64k columns is far past any line a person will read and far short of
/// anything that costs a modern machine a thought, and hitting it retires the line as if
/// a newline had arrived, which is the failure mode that loses nothing.
///
/// Printing is not the only way to lengthen a line, so the cursor motions and the
/// editing operators meet the cap too; see [`Stream::confine`].
const MAX_LINE_COLUMNS: usize = 1 << 16;

/// Where a tab stop falls. Fixed at eight rather than a table of them, because `CSI H`
/// (HTS) sets a stop on the *screen* this does not have; see the module docs.
const TAB_WIDTH: usize = 8;

/// One column of the open line.
///
/// [`Cell`] is the grid's own cell -- a character, a rendition id and a link -- and the
/// combining marks are what the grid keeps in a side table per row (see
/// [`Extras`](super::cell::Extras)). They ride the column here instead: a side table buys
/// the grid a smaller `Cell` across tens of thousands of them, and there is exactly one
/// line here.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
struct Column {
    cell: Cell,
    /// Zero-width characters -- combining marks, variation selectors -- riding this
    /// column, in stream order. `None` for the overwhelming majority of columns.
    marks: Option<Box<str>>,
}

impl Column {
    fn new(cell: Cell) -> Self {
        Self { cell, marks: None }
    }

    fn is_continuation(&self) -> bool {
        self.cell.is_continuation()
    }

    /// Characters this column contributes to the text handed to Emacs.
    ///
    /// Not one: a continuation column contributes none, and a column carrying combining
    /// marks contributes one per mark on top of its base. Every offset the wire format
    /// carries is a *character* offset into a multibyte Emacs string, so this is the
    /// count that has to be right -- see `Block::push_style'.
    fn chars(&self) -> usize {
        if self.is_continuation() {
            0
        } else {
            1 + self.marks.as_ref().map_or(0, |m| m.chars().count())
        }
    }

    /// Whether a run may span this column and the next without a break.
    fn joins(&self, next: &Self) -> bool {
        self.cell.same_pen(next.cell)
    }
}

/// What one [`Filter::feed`] produced.
#[derive(Debug, Default)]
pub(crate) struct Emission {
    /// Characters to delete immediately before the insertion point before inserting
    /// [`Emission::runs`]. Always zero when the caller passed `retract: false`.
    pub(crate) retract: usize,
    /// The styled text, in the shape the grid's renderer already takes.
    ///
    /// Kept across feeds and cleared rather than rebuilt, so a chunk an interactive
    /// child dribbles out a character at a time reuses the buffers the last one grew.
    pub(crate) runs: Runs,
    /// Renditions the runs name that the consumer has not been told about, as the grid's
    /// drain sends them; see [`StyleStore`].
    pub(crate) styles: Vec<(StyleId, Style)>,
    /// The last `OSC 7` the chunk carried, if any: the child's working directory as of
    /// the end of it. Last rather than every one, because the consumer of this is
    /// `default-directory', which only has room for the answer.
    pub(crate) directory: Option<String>,
}

impl Emission {
    fn clear(&mut self) {
        self.retract = 0;
        self.runs.clear();
        self.styles.clear();
        self.directory = None;
    }

    /// Whether anything at all needs to reach Emacs.
    pub(crate) fn is_empty(&self) -> bool {
        // The styles too: a table the consumer never receives would leave a later run
        // naming an id it cannot resolve.
        self.retract == 0
            && self.runs.is_empty()
            && self.styles.is_empty()
            && self.directory.is_none()
    }
}

/// The parser and the state it drives, in the shape [`Term`](super::term::Term) uses for
/// the same reason: a `Perform` impl cannot hold the parser that calls it.
pub(crate) struct Filter {
    parser: Parser,
    stream: Stream,
}

impl Default for Filter {
    fn default() -> Self {
        Self::new()
    }
}

impl Filter {
    pub(crate) fn new() -> Self {
        Self {
            parser: Parser::new(),
            stream: Stream::default(),
        }
    }

    /// Parse BYTES and return what Emacs should do about them.
    ///
    /// RETRACT is the caller's answer to "are the characters you were last handed for
    /// the open line still sitting where you put them?". Only the caller can know: it
    /// owns the buffer, and comint inserts the user's input into the middle of this
    /// conversation every time a command is entered. A `false` retires the open line
    /// before BYTES are parsed, and retires it silently; see [`Stream::abandon`].
    ///
    /// The parser is resumable, so a chunk ending in the middle of an escape sequence
    /// costs nothing and needs no buffering here: the next call continues it. That is
    /// the whole reason to own a VT parser rather than a regexp, and the reason a
    /// rendition set in one chunk still colours text in the next.
    pub(crate) fn feed(&mut self, bytes: &[u8], retract: bool) {
        self.stream.out.clear();
        self.stream.flushed = false;
        if !retract {
            self.stream.abandon();
        }
        self.parser.advance(&mut self.stream, bytes);
        // The open line, every time: a prompt that never ends in a newline has to arrive
        // when it is written, not when the next line is. Whatever this hands over is
        // remembered as provisional, and the next feed reconciles against it.
        self.stream.flush(false);
        self.stream.out.styles = self.stream.styles.take_unsent();
    }

    /// What the last [`Filter::feed`] produced.
    ///
    /// Separate from `feed` so the emission can be read beside [`Filter::uri`]; a `&mut`
    /// borrow outliving the feed would forbid holding the runs while asking about links.
    pub(crate) fn emission(&self) -> &Emission {
        &self.stream.out
    }

    /// The rendition ID names, for tests reading an emission back.
    #[cfg(test)]
    pub(crate) fn style(&self, id: StyleId) -> Style {
        self.stream.styles.get(id)
    }

    /// The destination of the `OSC 8` link ID names, for turning a link span into
    /// something Emacs can act on without an id table of its own.
    pub(crate) fn uri(&self, id: LinkId) -> Option<&str> {
        self.stream.links.get(id)
    }
}

/// The line buffer, the pen, and the [`Perform`] impl that drives them.
#[derive(Default)]
struct Stream {
    /// The open logical line, one entry per column. Never contains a newline: a newline
    /// is what empties it.
    line: Vec<Column>,
    /// The cursor's column within [`Stream::line`]. May sit past the end -- `CSI 40G` on
    /// a ten-column line -- in which case the gap is filled with blanks by whatever
    /// writes next, exactly as a grid's row would already have been.
    col: usize,
    /// The column the last printed character landed on, for a combining mark arriving
    /// next to attach to. `None` after anything that is not a print, which is the same
    /// rule [`Segmenter`] follows and has to be, since the two answer one question
    /// between them.
    base: Option<usize>,
    /// The line as Emacs last saw it: the columns already handed over for the *open*
    /// line, and therefore the ones a rewrite has to take back.
    ///
    /// A snapshot of the columns rather than a count of characters, because the question
    /// asked of it is where the new line and the old one first differ -- a progress bar
    /// that rewrites only its percentage should retract only its percentage.
    emitted: Vec<Column>,
    /// Whether anything has been flushed during this feed, which is what makes
    /// [`Stream::emitted`] stale rather than authoritative.
    flushed: bool,
    seg: Segmenter,
    pen: Style,
    link: Option<LinkId>,
    /// The renditions the line's cells name; see [`StyleStore`].
    styles: StyleStore,
    /// `OSC 8` destinations, interned so a run can name one in a word. Session-lifetime
    /// like the grid's, and bounded by the same caps -- a child sending a fresh URI per
    /// cell forever is a memory leak otherwise.
    links: LinkStore,
    out: Emission,
}

impl Stream {
    // -- the line buffer ---------------------------------------------------------

    /// Make the line at least COLUMNS wide, padding with blanks in the *default* style.
    ///
    /// Default and not the pen, deliberately. Padding happens when the cursor is moved
    /// beyond the end of the line and something is then written there; the columns
    /// skipped over were never written to, and a terminal leaves them as they were. It
    /// is the erases -- `CSI K`, `CSI X` -- that paint with the pen's background, which
    /// is what `bce` means and what [`Stream::erase`] does.
    fn pad(&mut self, columns: usize) {
        if self.line.len() < columns {
            self.line.resize(columns, Column::default());
        }
    }

    /// Hold the line and the cursor to [`MAX_LINE_COLUMNS`], as a right margin would.
    ///
    /// Printing retires a line at the cap, but a line also grows without printing:
    /// `CSI 65535 C` moves the cursor that far and `CSI 1 X` then pads out to it, and
    /// `CSI 65535 @` opens a gap of that many blanks. Four of either is 36 bytes of
    /// output for a quarter of a million 48-byte columns, doubled by the copy in
    /// [`Stream::emitted`], and a crafted file `cat` in `M-x shell` repeats that until
    /// Emacs is killed. So everything that is not a print ends here, and whatever it
    /// pushed past the cap falls off the end, as text pushed past a terminal's right
    /// margin does. One sequence can still reach twice the cap before this runs, since
    /// its count is at most 65535; what can no longer happen is the next one building
    /// on it.
    fn confine(&mut self) {
        self.line.truncate(MAX_LINE_COLUMNS);
        self.col = self.col.min(MAX_LINE_COLUMNS);
    }

    /// Blank COUNT columns from AT with the pen's background, the `bce` rule.
    fn erase(&mut self, at: usize, count: usize) {
        self.pad(at + count);
        let blank = Column::new(self.blank_cell());
        for column in &mut self.line[at..at + count] {
            *column = blank.clone();
        }
    }

    /// Detach the column at AT from any wide character it is half of.
    ///
    /// Writing to either half of a two-column character destroys the whole of it -- the
    /// glyph cannot be drawn in one column, so what is left is not half a glyph but a
    /// blank. The grid does the same thing in [`Row::set`](super::cell::Row); doing it
    /// here as well is what keeps a backspace into the middle of a CJK character from
    /// leaving a stray continuation column that renders as nothing and counts as
    /// something.
    fn split_wide(&mut self, at: usize) {
        if at < self.line.len() && self.line[at].is_continuation() {
            if let Some(base) = self.line[..at].iter().rposition(|c| !c.is_continuation()) {
                let style = self.line[base].cell.style;
                self.line[base] = Column::new(Cell::blank(style));
            }
        }
        if at + 1 < self.line.len() && self.line[at + 1].is_continuation() {
            let style = self.line[at + 1].cell.style;
            self.line[at + 1] = Column::new(Cell::blank(style));
        }
    }

    /// Write CH at the cursor, WIDTH columns wide, and advance.
    fn place(&mut self, ch: char, width: usize) {
        if self.col >= MAX_LINE_COLUMNS {
            self.retire();
        }
        self.pad(self.col + width);
        for offset in 0..width {
            self.split_wide(self.col + offset);
        }
        let cell = self.pen_cell(ch);
        self.line[self.col] = Column::new(cell);
        // The columns a wide character stands on beyond its first hold no character of
        // their own and contribute no text, but they do carry the rendition, so that a
        // background painted under a CJK character covers both halves of it.
        for offset in 1..width {
            self.line[self.col + offset] = Column::new(cell.with_char(CONTINUATION));
        }
        self.base = Some(self.col);
        self.col += width;
    }

    /// Attach a zero-width character to the column the last print landed on.
    ///
    /// BEFORE and AFTER are what the segmenter says the cell measured before this code
    /// point joined it and after -- they differ only for a variation selector, which can
    /// turn a one-column character into a two-column one. A mark with no cell to ride --
    /// the first thing on a fresh line being a combining mark -- is dropped, which is
    /// the one thing that can be done with it: there is nothing for it to combine with,
    /// and hanging it on a blank would invent a character the child never sent.
    fn join(&mut self, c: char, before: usize, after: usize) {
        let Some(base) = self.base else { return };
        if base >= self.line.len() {
            return;
        }
        let mut marks = self.line[base]
            .marks
            .take()
            .unwrap_or_default()
            .into_string();
        marks.push(c);
        self.line[base].marks = Some(marks.into_boxed_str());
        if after > before {
            // The character grew. Claim the columns to its right, destroying whatever
            // stood there -- which is what a terminal does, and here can only be blanks
            // or text this same line already wrote past.
            self.pad(base + after);
            for offset in before.max(1)..after {
                self.split_wide(base + offset);
                let continuation = Column::new(self.line[base].cell.with_char(CONTINUATION));
                self.line[base + offset] = continuation;
            }
            self.col = self.col.max(base + after);
        }
        self.seg.settle(after);
    }

    /// CH as the pen writes it: its rendition and the open link.
    fn pen_cell(&mut self, ch: char) -> Cell {
        Cell::linked(ch, self.style_id(self.pen), self.link)
    }

    /// The blank an erase leaves: the pen's rendition without its underline colour, and no
    /// link.
    fn blank_cell(&mut self) -> Cell {
        let style = Style {
            underline: Color::Default,
            ..self.pen
        };
        Cell::blank(self.style_id(style))
    }

    /// The id STYLE has, giving it one if it has none; see `State::style_id`.
    ///
    /// A collection marks the open line, the copy of what was last emitted, and the runs
    /// this feed has already produced, which are every place an id lives until the feed
    /// hands its table over.
    fn style_id(&mut self, style: Style) -> StyleId {
        if let Some(id) = self.styles.lookup(style) {
            return id;
        }
        if self.styles.is_full() {
            let (line, emitted, runs) = (&self.line, &self.emitted, &self.out.runs);
            self.styles.collect(|mark| {
                line.iter()
                    .chain(emitted)
                    .for_each(|column| mark(column.cell.style));
                runs.iter().for_each(|run| mark(run.style));
            });
        }
        self.styles.insert(style)
    }

    // -- retirement and emission -------------------------------------------------

    /// Hand the open line over as a finished line and start an empty one.
    fn retire(&mut self) {
        self.flush(true);
        self.forget();
    }

    /// Start an empty line without handing the open one over, because the buffer has
    /// already moved past it.
    ///
    /// The case is every command run from a prompt. A comint pty does not echo, so when
    /// the user enters `pip install x` the child never ends the line its `$ ` prompt is
    /// on: comint inserts `pip install x` and a newline of comint's own after the prompt,
    /// and the child's next write is its output. That output is not a rewrite of the
    /// prompt's line, although this buffer still holds `$ ` with the cursor at column 2.
    /// Treating it as one is what went wrong: `\rDownloading 10%` overwrote the prompt
    /// here, only the columns past the two already emitted could be appended, and the
    /// buffer showed `wnloading 10%` with every later redraw of it lost.
    ///
    /// Nothing is emitted, not even the newline that retiring would add: the characters
    /// the line held are already in the buffer, followed by text that is not the
    /// child's. The pen and the open link carry on, as they would across a newline.
    fn abandon(&mut self) {
        self.seg.reset();
        self.forget();
    }

    /// Empty the open line and everything that describes it.
    fn forget(&mut self) {
        self.line.clear();
        self.emitted.clear();
        self.col = 0;
        self.base = None;
    }

    /// Hand over whatever of the open line Emacs has not got, and remember what that
    /// leaves it holding. NEWLINE closes the line off.
    ///
    /// The reconciliation is the whole of this function. The line as it stands and the
    /// line as it was emitted are compared, and the emission starts at the first column
    /// they differ on: everything after that point is retracted and re-sent. A progress
    /// bar rewriting `[###   ] 42%` into `[####  ] 51%` retracts eight characters, not
    /// the line, and `printf 'abcdefghij\rXYZ'` retracts ten and sends `XYZdefghij` --
    /// the overwrite semantics this filter exists for.
    ///
    /// That is only safe while the emitted text is still the last thing in the buffer,
    /// and a feed whose caller said it is not has already emptied [`Stream::emitted`] in
    /// [`Stream::abandon`], so there is nothing here to retract.
    fn flush(&mut self, newline: bool) {
        let common = self
            .line
            .iter()
            .zip(&self.emitted)
            .take_while(|(a, b)| a == b)
            .count();
        let retract = self.emitted[common..]
            .iter()
            .map(Column::chars)
            .sum::<usize>();
        // Only the first flush of a feed can retract, and this is the invariant that
        // says so rather than a comment hoping it holds. The count is measured against
        // the buffer as it stood *before* this feed, so a second flush retracting
        // anything would be deleting text the first flush is in the middle of adding --
        // and the first flush is what empties `emitted', which is why it cannot.
        debug_assert!(
            !self.flushed || retract == 0,
            "a retraction after the first flush would be measured against the wrong text"
        );
        self.out.retract += retract;
        self.flushed = true;
        self.push_columns(common);
        if newline {
            self.push_newline();
        }
        self.emitted.clear();
        self.emitted.extend_from_slice(&self.line);
    }

    /// Append the open line from column FROM onward as styled runs.
    fn push_columns(&mut self, from: usize) {
        let mut at = from;
        while at < self.line.len() {
            let start = at;
            at += 1;
            while at < self.line.len()
                && (self.line[at].is_continuation() || self.line[start].joins(&self.line[at]))
            {
                at += 1;
            }
            let columns = &self.line[start..at];
            // A run of its own rather than one the pen might let it join: the scan above
            // has already decided where the boundaries are, and the runs of one feed must
            // not merge into whatever the last feed left open.
            self.out
                .runs
                .start(columns[0].cell.style, columns[0].cell.link, None);
            for column in columns {
                if column.is_continuation() {
                    continue;
                }
                self.out.runs.push_char(column.cell.ch);
                if let Some(marks) = &column.marks {
                    self.out.runs.push_str(marks);
                }
            }
            self.out.runs.add_cols(columns.len());
        }
    }

    /// Close a line off.
    ///
    /// In a run of its own, in the default rendition, and that is not tidiness: a face
    /// with a background on a newline paints the rest of the screen line in Emacs, so a
    /// line the child ended while a background was set would draw a coloured bar out to
    /// the window edge.
    fn push_newline(&mut self) {
        self.out.runs.start(StyleId::DEFAULT, None, None);
        self.out.runs.push_char('\n');
    }

    // -- escape sequences --------------------------------------------------------

    /// `OSC 8 ; params ; uri` -- open or close a hyperlink.
    ///
    /// Validated by the same [`validated_text`] as the grid's `State::hyperlink`, so a
    /// destination cannot smuggle an escape sequence into whatever displays it.
    fn hyperlink(&mut self, params: &[&[u8]]) {
        let Some(uri) = validated_text(params, 2, MAX_URI_LEN) else {
            return;
        };
        self.link = (!uri.is_empty()).then(|| self.links.intern(&uri).0);
    }

    /// `OSC 7 ; file://host/path` -- the child's working directory.
    ///
    /// Carried over as the text the child sent, unvalidated: what a `file://` URL means
    /// is a question about hosts, TRAMP and percent-encoding that Lisp already answers
    /// once, in `cooked-osc.el', and answering it a second time here in Rust is how the
    /// two answers come to differ. The cap is [`MAX_URI_LEN`] for the reason the
    /// hyperlink has one: the payload is a child's to choose the length of.
    fn set_directory(&mut self, params: &[&[u8]]) {
        if let Some(url) = validated_text(params, 1, MAX_URI_LEN).filter(|url| !url.is_empty()) {
            self.out.directory = Some(url);
        }
    }
}

impl Perform for Stream {
    fn print(&mut self, c: char) {
        match self.seg.push(c) {
            Step::Cell(width) => self.place(c, width),
            Step::Join { before, after } => self.join(c, before, after),
        }
    }

    /// The batched form, for the printable-ASCII runs that are nearly all of a stream.
    ///
    /// Worth having here for the same reason the grid has one: the per-character path
    /// asks the segmenter a question whose answer for `0x20..=0x7e` is always "one cell,
    /// starts a cluster". What it cannot skip is the per-column write, because the
    /// columns are what a later `\r` overwrites -- the text is not accumulated as a
    /// string until it is emitted.
    fn print_str(&mut self, text: &str) {
        let mut rest = text;
        while !rest.is_empty() {
            let plain = text::printable_ascii_len(rest.as_bytes());
            if plain == 0 {
                let c = rest.chars().next().unwrap_or('\0');
                self.print(c);
                rest = &rest[c.len_utf8()..];
                continue;
            }
            if self.col + plain > MAX_LINE_COLUMNS {
                self.retire();
            }
            self.pad(self.col + plain);
            self.split_wide(self.col);
            self.split_wide(self.col + plain - 1);
            let cell = self.pen_cell(BLANK);
            for (offset, c) in rest[..plain].chars().enumerate() {
                self.line[self.col + offset] = Column::new(cell.with_char(c));
            }
            self.col += plain;
            self.base = Some(self.col - 1);
            // The run bypassed the segmenter, so the segmenter is told what it missed:
            // the last character placed is what a combining mark arriving next has to
            // find. See `State::print_str', which does the same and explains the one
            // `Prepend' case this declines.
            let last = rest[..plain].chars().next_back().unwrap_or(BLANK);
            let mut buf = [0u8; 4];
            self.seg
                .restart(last.encode_utf8(&mut buf), Width::Measured(1));
            rest = &rest[plain..];
        }
    }

    fn execute(&mut self, byte: u8) {
        // Anything that is not a print ends the cluster under the cursor, for the reason
        // `State::execute' gives: the cell to the cursor's left is only this side's to
        // extend while this side is the one that wrote it.
        self.seg.reset();
        self.base = None;
        match byte {
            // BS. Past the end of the line it still steps back, because the cursor may
            // legitimately be out there after a `CSI C`.
            0x08 => self.col = self.col.saturating_sub(1),
            0x09 => self.col = (self.col / TAB_WIDTH + 1) * TAB_WIDTH,
            // LF, VT and FF all end the line here. A terminal distinguishes them by what
            // they do to the column, and this has one row: there is nowhere for the
            // distinction to land.
            0x0A..=0x0C => self.retire(),
            0x0D => self.col = 0,
            // BEL, SO, SI and the rest. A bell has nobody to ring -- the consumer is a
            // buffer, and `ding' on output would let any child ring it -- and DEC
            // graphics is a box-drawing mode for the full-screen programs this filter
            // has already declined to serve.
            _ => {}
        }
        self.confine();
    }

    fn csi_dispatch(&mut self, params: &Params, intermediates: &[u8], _ignore: bool, action: char) {
        self.seg.reset();
        self.base = None;
        // Private and intermediate-bearing sequences are all modes, reports and DEC
        // extensions: nothing a line of text can be changed by. Dropping them here keeps
        // the table below about the one thing it can answer.
        if !intermediates.is_empty() {
            return;
        }
        // Omitted or zero means one, as it does for nearly every `CSI` with a count.
        let n = params.arg(0, 1);
        match action {
            'm' => sgr::apply(params, &mut self.pen),
            // CUF and CUB. Within the line, and never past its start.
            'C' => self.col += n,
            'D' => self.col = self.col.saturating_sub(n),
            // CHA and HPA: the column, one-based on the wire.
            'G' | '`' => self.col = n - 1,
            // EL. 0 truncates, and truncates rather than blanking to the right margin
            // because there is no right margin here: a comint buffer's line ends where
            // the text does, and blanks out to a width this filter does not have would
            // be trailing whitespace the child never asked for.
            'K' => match params.value(0) {
                Some(1) => {
                    let to = (self.col + 1).min(self.line.len());
                    self.erase(0, to);
                }
                // 2 takes the whole line and leaves the cursor where it stands, so
                // text written next lands at that column with blanks before it --
                // which is what a terminal shows. Emptied rather than blanked so that
                // a line erased and then ended carries no trailing spaces into the
                // buffer; a screen has a right margin to blank out to and this has not.
                Some(2) => self.line.clear(),
                _ => self.line.truncate(self.col.min(self.line.len())),
            },
            // ECH: blank N columns without moving the cursor.
            'X' => self.erase(self.col, n),
            // DCH: close the gap, which is how a line editor deletes a character.
            'P' => {
                if self.col < self.line.len() {
                    let to = (self.col + n).min(self.line.len());
                    self.line.drain(self.col..to);
                }
            }
            // ICH: open a gap, the other half of the same line editing. Declined past
            // the end of the line, where there is nothing to push rightward.
            '@' if self.col <= self.line.len() => {
                let (blank, at) = (Column::new(self.blank_cell()), self.col);
                self.line.splice(at..at, std::iter::repeat_n(blank, n));
            }
            // Everything else, and it is most of the table: cursor addressing between
            // rows, scroll regions, erase-in-display, modes, reports, the alternate
            // screen. See the module docs -- a line buffer that half-implemented these
            // would be a grid with holes in it.
            _ => {}
        }
        self.confine();
    }

    fn esc_dispatch(&mut self, intermediates: &[u8], _ignore: bool, byte: u8) {
        self.seg.reset();
        self.base = None;
        // RIS. The pen is the only part of a reset that means anything without a screen,
        // and a child that resets the terminal after a full-screen program has left it
        // in some rendition is the case that matters: without this the rest of the
        // session comes out in that rendition.
        if intermediates.is_empty() && byte == b'c' {
            self.pen = Style::default();
            self.link = None;
        }
    }

    fn osc_dispatch(&mut self, params: &[&[u8]], _bell_terminated: bool) {
        self.seg.reset();
        self.base = None;
        match params.first().copied() {
            Some(b"8") => self.hyperlink(params),
            Some(b"7") => self.set_directory(params),
            // Titles, clipboard writes, colour queries, the semantic marks: every one of
            // them is a statement about a *terminal*, and the thing on the other end of
            // this is a comint buffer that has an Emacs mode line, an Emacs kill ring
            // and an Emacs notion of what a prompt is. `cooked-mode' answers them
            // because it is a terminal; this is not one.
            _ => {}
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::emu::cell::RunRef;

    /// Feed BYTES as one chunk and return the text it emitted, with the retraction
    /// applied to a buffer that starts out holding WAS.
    ///
    /// The buffer is the point: every assertion here is about what a consumer ends up
    /// *displaying*, since a retraction and the text after it are only meaningful
    /// together.
    struct Buffer {
        filter: Filter,
        text: String,
    }

    impl Buffer {
        fn new() -> Self {
            Self {
                filter: Filter::new(),
                text: String::new(),
            }
        }

        /// One chunk, applied the way `cooked-comint--emit' applies one.
        fn feed(&mut self, bytes: &str) -> &str {
            self.filter.feed(bytes.as_bytes(), true);
            let emission = self.filter.emission();
            let keep = self.text.chars().count() - emission.retract;
            self.text = self.text.chars().take(keep).collect();
            for run in &emission.runs {
                self.text.push_str(run.text);
            }
            &self.text
        }

        /// A chunk arriving after something else edited the buffer's tail, which is what
        /// comint inserting the user's input looks like from here.
        fn feed_unsynced(&mut self, bytes: &str) -> &str {
            self.filter.feed(bytes.as_bytes(), false);
            let emission = self.filter.emission();
            assert_eq!(emission.retract, 0, "an unsynced feed must not retract");
            for run in &emission.runs {
                self.text.push_str(run.text);
            }
            &self.text
        }
    }

    fn runs(bytes: &str) -> Runs {
        let mut filter = Filter::new();
        filter.feed(bytes.as_bytes(), true);
        filter.emission().runs.clone()
    }

    #[test]
    fn a_carriage_return_overwrites_rather_than_deleting() {
        // The case `cooked-process.el' documents and comint gets wrong: the CR moves the
        // cursor, and what follows overwrites only as far as it reaches.
        assert_eq!(Buffer::new().feed("abcdefghij\rXYZ\n"), "XYZdefghij\n");
    }

    #[test]
    fn a_backspace_rubs_out_rather_than_deleting_the_line() {
        assert_eq!(Buffer::new().feed("abc\x08\x08\x08XY\n"), "XYc\n");
    }

    #[test]
    fn a_backspace_past_the_start_of_the_line_stops_there() {
        assert_eq!(Buffer::new().feed("ab\x08\x08\x08\x08Z\n"), "Zb\n");
    }

    #[test]
    fn a_progress_bar_rewrites_the_line_it_is_on() {
        let mut buffer = Buffer::new();
        assert_eq!(buffer.feed("[#     ] 10%"), "[#     ] 10%");
        assert_eq!(buffer.feed("\r[###   ] 42%"), "[###   ] 42%");
        assert_eq!(
            buffer.feed("\r[######] 100%\ndone\n"),
            "[######] 100%\ndone\n"
        );
    }

    #[test]
    fn a_bar_redraw_retracts_only_what_it_changed() {
        // The reconciliation is a common-prefix comparison, so a bar that rewrites its
        // whole line but changes only its tail costs only its tail.
        let mut filter = Filter::new();
        filter.feed(b"[###   ] 42%", true);
        filter.feed(b"\r[####  ] 51%", true);
        let emission = filter.emission();
        assert_eq!(emission.retract, 8);
        let text: String = emission.runs.text().to_owned();
        assert_eq!(text, "#  ] 51%");
    }

    #[test]
    fn an_erase_to_end_of_line_takes_the_rest_of_the_line_with_it() {
        assert_eq!(Buffer::new().feed("abcdefghij\rXYZ\x1b[K\n"), "XYZ\n");
    }

    #[test]
    fn an_erase_to_the_start_of_the_line_blanks_it() {
        assert_eq!(Buffer::new().feed("abcdef\x1b[4G\x1b[1K\n"), "    ef\n");
    }

    #[test]
    fn an_erase_of_the_whole_line_leaves_nothing_of_it() {
        assert_eq!(Buffer::new().feed("abcdef\x1b[2Kxy\n"), "      xy\n");
    }

    #[test]
    fn a_column_address_moves_within_the_line() {
        assert_eq!(Buffer::new().feed("abcdef\x1b[3GXY\n"), "abXYef\n");
    }

    #[test]
    fn cursor_forward_past_the_end_of_the_line_pads_with_blanks() {
        assert_eq!(Buffer::new().feed("ab\x1b[4CZ\n"), "ab    Z\n");
    }

    #[test]
    fn a_tab_lands_on_an_eight_column_stop() {
        assert_eq!(Buffer::new().feed("ab\tc\n"), "ab      c\n");
    }

    #[test]
    fn erase_characters_blank_without_moving_the_cursor() {
        assert_eq!(Buffer::new().feed("abcdef\x1b[3G\x1b[2XZ\n"), "abZ ef\n");
    }

    #[test]
    fn delete_and_insert_character_are_the_line_editors_two_halves() {
        assert_eq!(Buffer::new().feed("abcdef\x1b[3G\x1b[2P\n"), "abef\n");
        assert_eq!(Buffer::new().feed("abcdef\x1b[3G\x1b[2@\n"), "ab  cdef\n");
    }

    #[test]
    fn a_line_retires_the_moment_its_newline_arrives() {
        // The whole reason this is not the headless grid: no eight-row wait.
        let mut filter = Filter::new();
        filter.feed(b"one\n", true);
        let emission = filter.emission();
        let text: String = emission.runs.text().to_owned();
        assert_eq!(text, "one\n");
    }

    #[test]
    fn a_readline_redraw_leaves_only_the_line_it_settled_on() {
        // What a Python or Node REPL actually sends, and the case that makes the
        // difference visible without anybody having to contrive one: readline redraws
        // the whole line on every keystroke, each redraw prefixed by a carriage
        // return. comint deletes to the start of the line for each of them and leaves
        // the lot behind as `>>> p>>> pr>>> pri...'; resolved against the line they
        // address, they are one line that changed its mind eight times.
        let mut buffer = Buffer::new();
        for typed in ["p", "pr", "pri", "prin", "print", "print()"] {
            buffer.feed(&format!("\r>>> {typed}"));
        }
        assert_eq!(buffer.feed("\r\n2\n"), ">>> print()\n2\n");
    }

    #[test]
    fn crlf_ends_one_line_rather_than_making_two() {
        // The pair every child on a pty sends, and the reason CR cannot simply be
        // passed on: resolved here it is a cursor move that the newline then makes
        // moot, which is one line and not a line plus an empty one.
        assert_eq!(Buffer::new().feed("one\r\ntwo\r\n"), "one\ntwo\n");
    }

    #[test]
    fn a_rewrite_that_shortens_the_line_takes_back_the_rest_of_it() {
        let mut buffer = Buffer::new();
        assert_eq!(buffer.feed("a long line"), "a long line");
        assert_eq!(buffer.feed("\r\x1b[Kshort\n"), "short\n");
    }

    #[test]
    fn an_unterminated_prompt_arrives_before_its_line_ends() {
        assert_eq!(Buffer::new().feed("$ "), "$ ");
    }

    #[test]
    fn a_rendition_set_in_one_chunk_colours_the_next() {
        // The argument for owning a parser rather than a regexp, in one assertion.
        let mut filter = Filter::new();
        filter.feed(b"\x1b[31m", true);
        filter.feed(b"red\n", true);
        let emission = filter.emission();
        assert_eq!(
            filter.style(emission.runs.run(0).style).fg,
            Color::Indexed(1)
        );
    }

    #[test]
    fn an_escape_sequence_split_across_chunks_still_arrives() {
        let mut filter = Filter::new();
        filter.feed(b"\x1b[3", true);
        assert!(filter.emission().is_empty());
        filter.feed(b"1mred\n", true);
        let emission = filter.emission();
        assert_eq!(emission.runs.run(0).text, "red");
        assert_eq!(
            filter.style(emission.runs.run(0).style).fg,
            Color::Indexed(1)
        );
    }

    #[test]
    fn the_newline_closing_a_styled_line_carries_no_style() {
        // Otherwise a background painted by the child runs to the window's edge.
        let runs = runs("\x1b[41mred\n");
        assert_eq!(runs.iter().next_back().unwrap().text, "\n");
        assert_eq!(runs.iter().next_back().unwrap().style, StyleId::DEFAULT);
    }

    #[test]
    fn a_run_breaks_where_the_rendition_does() {
        let runs = runs("plain\x1b[1mbold\x1b[0mplain\n");
        let texts: Vec<&str> = runs.iter().map(|r| r.text).collect();
        assert_eq!(texts, ["plain", "bold", "plain", "\n"]);
    }

    #[test]
    fn a_rewritten_column_carries_the_rendition_it_was_rewritten_in() {
        // The line buffer holds cells, not a string with spans over it, which is what
        // makes a partial overwrite in a new colour come out right.
        let mut filter = Filter::new();
        filter.feed(b"\x1b[31mabcdef\r\x1b[32mXY\n", true);
        let runs = &filter.emission().runs;
        let coloured: Vec<(&str, Color)> = runs
            .iter()
            .map(|r| (r.text, filter.style(r.style).fg))
            .collect();
        assert_eq!(
            coloured,
            [
                ("XY", Color::Indexed(2)),
                ("cdef", Color::Indexed(1)),
                ("\n", Color::Default),
            ]
        );
    }

    #[test]
    fn a_hyperlink_splits_a_run_and_names_its_destination() {
        let mut filter = Filter::new();
        filter.feed(
            b"see \x1b]8;;https://example.com\x1b\\here\x1b]8;;\x1b\\ ok\n",
            true,
        );
        let runs = filter.emission().runs.clone();
        let linked: Vec<RunRef<'_>> = runs.iter().filter(|r| r.link.is_some()).collect();
        assert_eq!(linked.len(), 1);
        assert_eq!(linked[0].text, "here");
        assert_eq!(
            filter.uri(linked[0].link.unwrap()),
            Some("https://example.com")
        );
    }

    #[test]
    fn a_hyperlink_whose_uri_hides_a_control_character_is_refused() {
        // A C1 control, spelled in UTF-8, because a C0 one cannot get this far: the
        // parser discards those inside an OSC string, and `\x07' would terminate it.
        // What is left for this guard to catch is exactly the ones that survive the
        // parser and would otherwise reach whatever displays the destination.
        let runs = runs("\x1b]8;;https://ex\u{85}ample.com\x1b\\x\n");
        assert!(runs.iter().all(|r| r.link.is_none()));
    }

    #[test]
    fn the_last_working_directory_of_a_chunk_is_the_one_reported() {
        let mut filter = Filter::new();
        filter.feed(
            b"\x1b]7;file://host/tmp\x07a\n\x1b]7;file://host/var\x07b\n",
            true,
        );
        assert_eq!(
            filter.emission().directory.as_deref(),
            Some("file://host/var")
        );
    }

    #[test]
    fn a_wide_character_stands_on_two_columns_and_a_backspace_into_it_blanks_it() {
        assert_eq!(Buffer::new().feed("漢字\n"), "漢字\n");
        // Column 2 is the second half of the first character; writing there destroys the
        // whole character rather than leaving half a glyph.
        assert_eq!(Buffer::new().feed("漢字\x1b[2Gx\n"), " x字\n");
    }

    #[test]
    fn a_combining_mark_rides_the_character_before_it() {
        let runs = runs("e\u{301}\n");
        assert_eq!(runs.run(0).text, "e\u{301}");
        assert_eq!(runs.run(0).cols, 1);
    }

    #[test]
    fn a_combining_mark_with_nothing_before_it_is_dropped() {
        let runs = runs("\u{301}x\n");
        let text: String = runs.iter().map(|r| r.text).collect();
        assert_eq!(text, "x\n");
    }

    #[test]
    fn a_retraction_counts_characters_and_not_columns() {
        // The offsets on the wire are character offsets into an Emacs string, so a wide
        // character retracts as one and a combining mark as one of its own.
        let mut filter = Filter::new();
        filter.feed("漢e\u{301}".as_bytes(), true);
        filter.feed(b"\rx", true);
        let emission = filter.emission();
        assert_eq!(emission.retract, 3);
    }

    #[test]
    fn an_unsynced_feed_appends_rather_than_correcting() {
        // The ordinary shape at every prompt: the prompt is emitted, comint inserts the
        // user's input after it, and the child then ends the line the prompt was on.
        // Re-sending the prompt would double it.
        let mut buffer = Buffer::new();
        assert_eq!(buffer.feed("$ "), "$ ");
        buffer.text.push_str("ls\n"); // comint, inserting what the user typed
        assert_eq!(buffer.feed_unsynced("\r\nfile\n"), "$ ls\n\nfile\n");
    }

    #[test]
    fn output_after_a_prompt_is_a_line_of_its_own() {
        // A comint pty does not echo, so the prompt's line is never ended by the child:
        // comint ends it, with the user's input. A progress bar that starts with `\r`
        // is then the start of the command's output, not a rewrite of `$ `, and every
        // later frame of it has to land.
        let mut buffer = Buffer::new();
        assert_eq!(buffer.feed("$ "), "$ ");
        buffer.text.push_str("pip install x\n");
        assert_eq!(
            buffer.feed_unsynced("\rDownloading 10%"),
            "$ pip install x\nDownloading 10%"
        );
        assert_eq!(
            buffer.feed("\rDownloading 20%"),
            "$ pip install x\nDownloading 20%"
        );
        assert_eq!(
            buffer.feed("\rDownloading 100%\n$ "),
            "$ pip install x\nDownloading 100%\n$ "
        );
    }

    #[test]
    fn an_unsynced_feed_shows_everything_the_child_writes_after_it() {
        let mut buffer = Buffer::new();
        assert_eq!(buffer.feed("part"), "part");
        buffer.text.push('!');
        assert_eq!(buffer.feed_unsynced("ial\n"), "part!ial\n");
    }

    #[test]
    fn no_cursor_motion_or_edit_grows_a_line_past_the_cap() {
        // A gap opened four times over, the cursor sent far out by `CUF` and by tab stops
        // with one blank written there: none of them prints, so none of them meets the
        // retirement that printing does.
        let hostile = [
            "\x1b[65535@".repeat(4),
            "\x1b[65535C".repeat(4) + "\x1b[1X",
            "\x1b[65535G".to_string() + &"\t".repeat(1000) + "\x1b[1X",
        ];
        for bytes in hostile {
            let mut filter = Filter::new();
            filter.feed(bytes.as_bytes(), true);
            assert!(filter.stream.line.len() <= MAX_LINE_COLUMNS);
            assert!(filter.stream.emitted.len() <= MAX_LINE_COLUMNS);
            let text: usize = filter.emission().runs.iter().map(|r| r.text.len()).sum();
            assert!(text <= MAX_LINE_COLUMNS);
        }
    }

    #[test]
    fn a_printed_line_that_never_ends_is_retired_before_it_can_grow_without_bound() {
        let mut filter = Filter::new();
        let chunk = "x".repeat(MAX_LINE_COLUMNS + 16);
        filter.feed(chunk.as_bytes(), true);
        let emission = filter.emission();
        let text: String = emission.runs.text().to_owned();
        assert_eq!(text.matches('\n').count(), 1);
        assert_eq!(text.len(), chunk.len() + 1);
    }

    #[test]
    fn a_sequence_the_filter_declines_leaves_the_text_alone() {
        // Cursor addressing, erase-in-display, the alternate screen: dropped whole, and
        // the characters around them survive intact.
        assert_eq!(
            Buffer::new().feed("a\x1b[2J\x1b[10;5H\x1b[?1049hb\n"),
            "ab\n"
        );
    }

    /// The filter's own oracle: where a read happens to end must not change what is shown.
    ///
    /// comint hands the filter whatever one `read' returned, so a progress bar's `\r`, an
    /// `SGR` or an `OSC 8` can be cut anywhere, and the parser, the pen, the segmenter and
    /// the retraction all have to carry across the cut. The grid has `delta_replay.rs` for
    /// the same question; this filter is not the grid, and a bug in its reconciliation
    /// would pass every property that one has. So the same script is fed whole to one
    /// filter and in pieces to another, and the two consumers must end up displaying the
    /// same characters under the same renditions and the same link destinations.
    mod chunking {
        use super::*;
        use proptest::prelude::*;

        /// How many renditions the cut side's filter holds before it collects the ids
        /// nothing holds.
        ///
        /// Small so that a script of a few `SGR`s and erases collects several times.
        /// Whether an id is held is decided by the roots `Stream::style_id` marks, and a
        /// root left off that list has its id reused while a run still names it, which
        /// resolves to the wrong rendition on the cut side and not on the whole one.
        const STYLE_LIMIT: usize = 2;

        /// What a consumer displays: each character, with the rendition and the `OSC 8`
        /// destination it was inserted under.
        ///
        /// Resolved rather than kept as ids, because the two filters under comparison
        /// number their renditions independently: one that saw a style first in a
        /// different feed may well have given it a different id.
        type Shown = Vec<(char, Style, Option<String>)>;

        /// A comint buffer, reduced to what `cooked-comint--emit' does with an emission.
        struct Consumer {
            filter: Filter,
            shown: Shown,
            /// `cooked-comint--open': the text of the open line as last handed over,
            /// which is what decides whether the next feed may retract.
            open: String,
            /// `cooked-comint--open-start': where in `shown` the open line begins, so
            /// that input typed after an open line with no text is noticed too.
            open_start: usize,
        }

        impl Consumer {
            fn new() -> Self {
                Self {
                    filter: Filter::new(),
                    shown: Vec::new(),
                    open: String::new(),
                    open_start: 0,
                }
            }

            /// A consumer whose filter looks for renditions to free once
            /// [`STYLE_LIMIT`] are live, rather than at the four thousand an ordinary
            /// one holds.
            fn with_tiny_style_table() -> Self {
                let mut consumer = Self::new();
                consumer.filter.stream.styles = StyleStore::with_limit(STYLE_LIMIT);
                consumer
            }

            /// Whether the buffer still ends in the open line, as
            /// `cooked-comint--intact-p' asks it: by its text, and by where it begins.
            fn intact(&self) -> bool {
                let open: Vec<char> = self.open.chars().collect();
                self.shown.len() >= open.len()
                    && self.open_start == self.shown.len() - open.len()
                    && self.shown[self.shown.len() - open.len()..]
                        .iter()
                        .map(|(c, ..)| *c)
                        .eq(open.iter().copied())
            }

            /// One chunk, applied the way `cooked-comint--emit' applies one.
            fn feed(&mut self, chunk: &str) {
                let intact = self.intact();
                self.filter.feed(chunk.as_bytes(), intact);
                let emission = self.filter.emission();
                // The core gave the line up, so `cooked-comint--emit' forgets it whether
                // or not the chunk made anything.
                if !intact {
                    self.open.clear();
                    self.open_start = self.shown.len();
                }
                // `cooked--filter-feed' answers nil, and nothing more happens.
                if emission.is_empty() {
                    return;
                }
                assert!(
                    intact || emission.retract == 0,
                    "an unsynced feed retracted"
                );
                self.shown.truncate(self.shown.len() - emission.retract);
                let mut text = String::new();
                for run in &emission.runs {
                    let style = self.filter.style(run.style);
                    let link = run
                        .link
                        .and_then(|id| self.filter.uri(id))
                        .map(str::to_string);
                    self.shown
                        .extend(run.text.chars().map(|c| (c, style, link.clone())));
                    text.push_str(run.text);
                }
                let tail = text.rsplit('\n').next().unwrap_or_default();
                if text.contains('\n') || !intact {
                    self.open = tail.to_string();
                } else {
                    let keep = self.open.chars().count() - emission.retract;
                    self.open = self.open.chars().take(keep).collect::<String>() + tail;
                }
                // `cooked-comint--place-open-start', once the text is in.
                self.open_start = self.shown.len() - self.open.chars().count();
            }

            /// What `comint-send-input' does to the buffer: INPUT inserted after the
            /// output, in no rendition of the child's. The open line is left alone, as
            /// comint leaves `cooked-comint--open', and so no longer ends the buffer.
            fn type_input(&mut self, input: &str) {
                self.shown
                    .extend(input.chars().map(|c| (c, Style::default(), None)));
            }

            /// SCRIPT cut at CUTS, each a fraction of its length in 256ths, and moved to
            /// the nearest character boundary at or before it: comint decodes the output
            /// before a preoutput filter sees it, so a cut inside a character is not one
            /// the filter can meet.
            fn feed_cut(&mut self, script: &str, cuts: &[u8]) {
                let mut offsets: Vec<usize> = cuts
                    .iter()
                    .map(|&cut| {
                        let mut at = usize::from(cut) * script.len() / 256;
                        while !script.is_char_boundary(at) {
                            at -= 1;
                        }
                        at
                    })
                    .collect();
                offsets.sort_unstable();
                let mut from = 0;
                for at in offsets.into_iter().chain([script.len()]) {
                    self.feed(&script[from..at]);
                    from = at;
                }
            }
        }

        /// The pieces a script is made of: everything the line buffer resolves, each in a
        /// shape that has something to disturb, and the ones that make characters and
        /// columns disagree.
        fn token() -> impl Strategy<Value = String> {
            prop_oneof![
                4 => prop::sample::select(vec!["abc", "Downloading", " 42%", "$ ", "x"])
                    .prop_map(str::to_string),
                3 => prop::sample::select(vec!["\r", "\x08", "\t", "\n", "\r\n"])
                    .prop_map(str::to_string),
                2 => prop::sample::select(vec!["\x1b[K", "\x1b[1K", "\x1b[2K"])
                    .prop_map(str::to_string),
                // A progress line repainted in another rendition: the text comes back the
                // same, so only the rendition ids say whether it has to be emitted again.
                2 => (prop::sample::select(vec!["\x1b[31m", "\x1b[1;42m", "\x1b[0m"]),
                      prop::sample::select(vec!["abc", " 42%"]))
                    .prop_map(|(pen, text)| format!("\r\x1b[2K{pen}{text}")),
                3 => (1usize..12, prop::sample::select(vec!['G', 'X', 'P', '@', 'C', 'D']))
                    .prop_map(|(n, verb)| format!("\x1b[{n}{verb}")),
                2 => prop::sample::select(vec!["\x1b[31m", "\x1b[1;42m", "\x1b[0m"])
                    .prop_map(str::to_string),
                // A wide character, and a combining mark both with a base and without.
                2 => prop::sample::select(vec!["\u{6f22}", "e\u{301}", "\u{301}"])
                    .prop_map(str::to_string),
                1 => (0usize..3)
                    .prop_map(|n| format!("\x1b]8;;https://example.invalid/{n}\x1b\\")),
                1 => Just("\x1b]8;;\x1b\\".to_string()),
            ]
        }

        fn script() -> impl Strategy<Value = String> {
            prop::collection::vec(token(), 0..24).prop_map(|tokens| tokens.concat())
        }

        fn cuts() -> impl Strategy<Value = Vec<u8>> {
            prop::collection::vec(any::<u8>(), 0..8)
        }

        proptest! {
            // No persistence file. A unit test's would be written under `src/', and a
            // failure this finds belongs in the named tests above, with its input spelled
            // out, rather than in a seed that silently changes meaning with the generator.
            #![proptest_config(ProptestConfig {
                cases: 1024,
                failure_persistence: None,
                ..ProptestConfig::default()
            })]

            /// The same, across the one place a comint buffer is edited by somebody else.
            ///
            /// A prompt, the user's input with the newline comint gives it, and the
            /// command's output. However either stretch of output is cut, the buffer must
            /// read as if the input's newline had been the child's: the prompt as it was
            /// drawn, the input, and then the output exactly as a filter would show it on a
            /// fresh line with the prompt's rendition still set.
            ///
            /// That includes a prompt that left an open line with no text in it, such as
            /// `\t` or `abc\x1b[2K` on their own, where the buffer ends in nothing the
            /// text could be checked against and only the open line's place shows the
            /// input.
            #[test]
            fn output_after_typed_input_starts_a_line_however_it_is_cut(
                prompt in script(),
                input in "[a-z ]{0,8}",
                output in script(),
                prompt_cuts in cuts(),
                output_cuts in cuts(),
            ) {
                let input = input + "\n";
                let mut expected = Consumer::new();
                expected.feed(&prompt);
                let shown = expected.shown.clone();
                expected.feed("\n");
                expected.shown = shown;
                expected.type_input(&input);
                expected.feed(&output);

                let mut actual = Consumer::with_tiny_style_table();
                actual.feed_cut(&prompt, &prompt_cuts);
                actual.type_input(&input);
                actual.feed_cut(&output, &output_cuts);
                prop_assert_eq!(actual.shown, expected.shown);
            }

            #[test]
            fn cutting_the_output_into_reads_changes_nothing(script in script(), cuts in cuts()) {
                let mut whole = Consumer::new();
                whole.feed(&script);
                let mut pieces = Consumer::with_tiny_style_table();
                pieces.feed_cut(&script, &cuts);
                prop_assert_eq!(pieces.shown, whole.shown);
            }
        }
    }
}
