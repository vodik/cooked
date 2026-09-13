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
//! `cooked-process.el' already runs a *headless* session for `compile' and friends, and
//! reusing it here was the obvious move and the wrong one. A grid retires a row when the
//! row scrolls off the top of it, so a session eight rows tall hands its consumer the
//! first line when the ninth arrives. That is a fine trade for a build log and a fatal
//! one for a shell, where it would leave you sitting eight lines behind your own prompt.
//!
//! So this is a third mode, between a grid and ghostel's pass-everything-through: **one
//! row of cells, and no rows at all above or below it**. A line retires the instant its
//! `\n` arrives, which is no latency at all, and the open line is emitted at the end of
//! every feed, so an unterminated prompt (`read -p', `$ ') shows up the moment it is
//! written rather than when the next line ends.
//!
//! ## Why a line buffer rather than passing CR and BS through
//!
//! Passing them through is what ghostel's `comint_filter.zig' does, and cooked's own
//! `cooked-process.el' documented why that is wrong before ghostel existed:
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
//! `CSI P', `CSI @' -- for about sixty lines over passing them through, and leaves the
//! consumer with text that says what the child meant. `cooked-comint-mode' therefore
//! sets `comint-inhibit-carriage-motion', which is one fewer pass over every chunk as
//! well as the removal of a wrong one.
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
//! case at every prompt), the caller says so by passing `retract: false`, and this falls
//! back to appending only what is new. See [`Stream::flush`] for what that costs.

use super::cell::{BLANK, CONTINUATION, Cell, Color, Run, Style};
use super::link::{LinkId, LinkStore, MAX_URI_LEN};
use super::parser::{Params, Parser, Perform};
use super::sgr;
use super::term::osc::validated_text;
use super::text::{Segmenter, Step};

/// Columns one logical line may reach before it is retired to keep it bounded.
///
/// A line buffer has no width to stop it growing, and a child that never sends a
/// newline is not hypothetical -- `find / -print0' is one, and a corrupted stream is
/// another. 64k columns is far past any line a person will read and far short of
/// anything that costs a modern machine a thought, and hitting it retires the line as if
/// a newline had arrived, which is the failure mode that loses nothing.
const MAX_LINE_COLUMNS: usize = 1 << 16;

/// Where a tab stop falls. Fixed at eight rather than a table of them, because `CSI H`
/// (HTS) sets a stop on the *screen* this does not have; see the module docs.
const TAB_WIDTH: usize = 8;

/// One column of the open line.
///
/// [`Cell`] is the grid's own cell -- a character and a rendition -- and the other three
/// fields are what the grid keeps in a side table per row (see
/// [`Extras`](super::cell::Extras)). They ride the column here instead: a side table
/// buys the grid a smaller `Cell` across tens of thousands of them, and there is exactly
/// one line here.
#[derive(Debug, Clone, PartialEq, Eq)]
struct Column {
    cell: Cell,
    /// Zero-width characters -- combining marks, variation selectors -- riding this
    /// column, in stream order. `None` for the overwhelming majority of columns.
    marks: Option<Box<str>>,
    /// `SGR 58`, the underline's own colour.
    underline: Color,
    /// The `OSC 8` hyperlink this column is part of, if any.
    link: Option<LinkId>,
}

impl Default for Column {
    fn default() -> Self {
        Self::blank(Style::default())
    }
}

impl Column {
    fn blank(style: Style) -> Self {
        Self {
            cell: Cell::blank(style),
            marks: None,
            underline: Color::Default,
            link: None,
        }
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
        self.cell.style == next.cell.style
            && self.underline == next.underline
            && self.link == next.link
    }
}

/// What one [`Filter::feed`] produced.
#[derive(Debug, Default)]
pub(crate) struct Emission {
    /// Characters to delete immediately before the insertion point before inserting
    /// [`Emission::runs`]. Always zero when the caller passed `retract: false`.
    pub(crate) retract: usize,
    /// The styled text, in the shape the grid's renderer already takes.
    pub(crate) runs: Vec<Run>,
    /// The last `OSC 7` the chunk carried, if any: the child's working directory as of
    /// the end of it. Last rather than every one, because the consumer of this is
    /// `default-directory', which only has room for the answer.
    pub(crate) directory: Option<String>,
}

impl Emission {
    fn clear(&mut self) {
        self.retract = 0;
        self.runs.clear();
        self.directory = None;
    }

    /// Whether anything at all needs to reach Emacs.
    pub(crate) fn is_empty(&self) -> bool {
        self.retract == 0 && self.runs.is_empty() && self.directory.is_none()
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
    /// conversation every time a command is entered. A `false` here never loses text; it
    /// costs the ability to correct text already shown. See [`Stream::flush`].
    ///
    /// The parser is resumable, so a chunk ending in the middle of an escape sequence
    /// costs nothing and needs no buffering here: the next call continues it. That is
    /// the whole reason to own a VT parser rather than a regexp, and the reason a
    /// rendition set in one chunk still colours text in the next.
    pub(crate) fn feed(&mut self, bytes: &[u8], retract: bool) {
        self.stream.out.clear();
        self.stream.retract_allowed = retract;
        self.stream.flushed = false;
        self.parser.advance(&mut self.stream, bytes);
        // The open line, every time: a prompt that never ends in a newline has to arrive
        // when it is written, not when the next line is. Whatever this hands over is
        // remembered as provisional, and the next feed reconciles against it.
        self.stream.flush(false);
    }

    /// What the last [`Filter::feed`] produced.
    ///
    /// Separate from `feed` rather than returned by it, so that the emission can be read
    /// beside [`Filter::uri`]: turning a link span into something Emacs can act on means
    /// holding the runs and asking the store about them at the same time, and a `&mut`
    /// borrow that outlived the feed would forbid exactly that.
    pub(crate) fn emission(&self) -> &Emission {
        &self.stream.out
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
    /// Whether this feed's caller can still see [`Stream::emitted`] where it left it.
    retract_allowed: bool,
    /// Whether anything has been flushed during this feed, which is what makes
    /// [`Stream::emitted`] stale rather than authoritative.
    flushed: bool,
    seg: Segmenter,
    pen: Style,
    underline: Color,
    link: Option<LinkId>,
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

    /// Blank COUNT columns from AT with the pen's background, the `bce` rule.
    fn erase(&mut self, at: usize, count: usize) {
        self.pad(at + count);
        let pen = self.pen;
        for column in &mut self.line[at..at + count] {
            *column = Column::blank(pen);
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
                self.line[base] = Column::blank(style);
            }
        }
        if at + 1 < self.line.len() && self.line[at + 1].is_continuation() {
            let style = self.line[at + 1].cell.style;
            self.line[at + 1] = Column::blank(style);
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
        self.line[self.col] = Column {
            cell: Cell {
                ch,
                style: self.pen,
            },
            marks: None,
            underline: self.underline,
            link: self.link,
        };
        // The columns a wide character stands on beyond its first hold no character of
        // their own and contribute no text, but they do carry the rendition, so that a
        // background painted under a CJK character covers both halves of it.
        for offset in 1..width {
            self.line[self.col + offset] = Column {
                cell: Cell {
                    ch: CONTINUATION,
                    style: self.pen,
                },
                marks: None,
                underline: self.underline,
                link: self.link,
            };
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
                self.line[base + offset] = Column {
                    cell: Cell {
                        ch: CONTINUATION,
                        style: self.line[base].cell.style,
                    },
                    marks: None,
                    underline: self.line[base].underline,
                    link: self.line[base].link,
                };
            }
            self.col = self.col.max(base + after);
        }
        self.seg.settle(after);
    }

    // -- retirement and emission -------------------------------------------------

    /// Hand the open line over as a finished line and start an empty one.
    fn retire(&mut self) {
        self.flush(true);
        self.line.clear();
        self.emitted.clear();
        self.col = 0;
        self.base = None;
    }

    /// Hand over whatever of the open line Emacs has not got, and remember what that
    /// leaves it holding. NEWLINE closes the line off.
    ///
    /// The reconciliation is the whole of this function, and there are two versions of
    /// it because there are two things the caller can know.
    ///
    /// **When the emitted text is still the last thing in the buffer** (`retract:
    /// true`), the two lines are compared and the emission starts at the first column
    /// they differ on: everything after that point is retracted and re-sent. A progress
    /// bar rewriting `[###   ] 42%` into `[####  ] 51%` retracts eight characters, not
    /// the line, and `printf 'abcdefghij\rXYZ'` retracts ten and sends `XYZdefghij` --
    /// the overwrite semantics this filter exists for.
    ///
    /// **When it is not** (`retract: false`), nothing before the insertion point may be
    /// touched, so only the columns past what was already emitted can be sent. That is
    /// exactly right for the case it exists for -- comint has inserted the user's input
    /// after our prompt, and the child's next act is to finish the line the prompt was
    /// on -- and it is lossy for one case that is not: a child that *rewrites* an open
    /// line after the user has typed. There the rewrite is dropped rather than shown
    /// twice, up to the point where the new line grows past the old one. Losing an
    /// update is recoverable and duplicating a prompt is not, which is why it falls this
    /// way; the caller can always make it moot by verifying, which is what
    /// `cooked-comint--emit' does.
    fn flush(&mut self, newline: bool) {
        let common = if self.retract_allowed {
            self.line
                .iter()
                .zip(&self.emitted)
                .take_while(|(a, b)| a == b)
                .count()
        } else {
            // Not a prefix comparison: the emitted columns are immovable whether or not
            // they are still true, so the only thing that can be said is what comes
            // after them.
            self.emitted.len().min(self.line.len())
        };
        let retract = self.emitted[common.min(self.emitted.len())..]
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
            let mut text = String::with_capacity(at - start);
            for column in columns {
                if column.is_continuation() {
                    continue;
                }
                text.push(column.cell.ch);
                if let Some(marks) = &column.marks {
                    text.push_str(marks);
                }
            }
            self.out.runs.push(Run {
                text,
                cols: columns.len(),
                style: columns[0].cell.style,
                deco: None,
                underline: columns[0].underline,
                link: columns[0].link,
            });
        }
    }

    /// Close a line off.
    ///
    /// In a run of its own, in the default rendition, and that is not tidiness: a face
    /// with a background on a newline paints the rest of the screen line in Emacs, so a
    /// line the child ended while a background was set would draw a coloured bar out to
    /// the window edge.
    fn push_newline(&mut self) {
        self.out.runs.push(Run {
            text: "\n".to_string(),
            cols: 0,
            style: Style::default(),
            deco: None,
            underline: Color::Default,
            link: None,
        });
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
            let plain = rest
                .as_bytes()
                .iter()
                .take_while(|&&b| (0x20..0x7f).contains(&b))
                .count();
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
            let (pen, underline, link) = (self.pen, self.underline, self.link);
            for (offset, c) in rest[..plain].chars().enumerate() {
                self.line[self.col + offset] = Column {
                    cell: Cell { ch: c, style: pen },
                    marks: None,
                    underline,
                    link,
                };
            }
            self.col += plain;
            self.base = Some(self.col - 1);
            // The run bypassed the segmenter, so the segmenter is told what it missed:
            // the last character placed is what a combining mark arriving next has to
            // find. See `State::print_str', which does the same and explains the one
            // `Prepend' case this declines.
            let last = rest[..plain].chars().next_back().unwrap_or(BLANK);
            let mut buf = [0u8; 4];
            self.seg.restart(last.encode_utf8(&mut buf), 1, false);
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
            'm' => sgr::apply(params, &mut self.pen, &mut self.underline),
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
                let (pen, at) = (self.pen, self.col);
                self.line
                    .splice(at..at, std::iter::repeat_n(Column::blank(pen), n));
            }
            // Everything else, and it is most of the table: cursor addressing between
            // rows, scroll regions, erase-in-display, modes, reports, the alternate
            // screen. See the module docs -- a line buffer that half-implemented these
            // would be a grid with holes in it.
            _ => {}
        }
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
            self.underline = Color::Default;
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
                self.text.push_str(&run.text);
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
                self.text.push_str(&run.text);
            }
            &self.text
        }
    }

    fn runs(bytes: &str) -> Vec<Run> {
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
        let text: String = emission.runs.iter().map(|r| r.text.as_str()).collect();
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
        let text: String = emission.runs.iter().map(|r| r.text.as_str()).collect();
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
        assert_eq!(emission.runs[0].style.fg, Color::Indexed(1));
    }

    #[test]
    fn an_escape_sequence_split_across_chunks_still_arrives() {
        let mut filter = Filter::new();
        filter.feed(b"\x1b[3", true);
        assert!(filter.emission().is_empty());
        filter.feed(b"1mred\n", true);
        let emission = filter.emission();
        assert_eq!(emission.runs[0].text, "red");
        assert_eq!(emission.runs[0].style.fg, Color::Indexed(1));
    }

    #[test]
    fn the_newline_closing_a_styled_line_carries_no_style() {
        // Otherwise a background painted by the child runs to the window's edge.
        let runs = runs("\x1b[41mred\n");
        assert_eq!(runs.last().unwrap().text, "\n");
        assert_eq!(runs.last().unwrap().style, Style::default());
    }

    #[test]
    fn a_run_breaks_where_the_rendition_does() {
        let runs = runs("plain\x1b[1mbold\x1b[0mplain\n");
        let texts: Vec<&str> = runs.iter().map(|r| r.text.as_str()).collect();
        assert_eq!(texts, ["plain", "bold", "plain", "\n"]);
    }

    #[test]
    fn a_rewritten_column_carries_the_rendition_it_was_rewritten_in() {
        // The line buffer holds cells, not a string with spans over it, which is what
        // makes a partial overwrite in a new colour come out right.
        let runs = runs("\x1b[31mabcdef\r\x1b[32mXY\n");
        let coloured: Vec<(&str, Color)> =
            runs.iter().map(|r| (r.text.as_str(), r.style.fg)).collect();
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
        let linked: Vec<&Run> = runs.iter().filter(|r| r.link.is_some()).collect();
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
        assert_eq!(runs[0].text, "e\u{301}");
        assert_eq!(runs[0].cols, 1);
    }

    #[test]
    fn a_combining_mark_with_nothing_before_it_is_dropped() {
        let runs = runs("\u{301}x\n");
        let text: String = runs.iter().map(|r| r.text.as_str()).collect();
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
    fn an_unsynced_feed_still_shows_what_the_line_grows_by() {
        let mut buffer = Buffer::new();
        assert_eq!(buffer.feed("part"), "part");
        buffer.text.push('!');
        assert_eq!(buffer.feed_unsynced("ial\n"), "part!ial\n");
    }

    #[test]
    fn a_line_that_never_ends_is_retired_before_it_can_grow_without_bound() {
        let mut filter = Filter::new();
        let chunk = "x".repeat(MAX_LINE_COLUMNS + 16);
        filter.feed(chunk.as_bytes(), true);
        let emission = filter.emission();
        let text: String = emission.runs.iter().map(|r| r.text.as_str()).collect();
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
}
