//! `OSC` dispatch: semantic prompts (133), hyperlinks (8), text sizing (66), the colour
//! queries answered from the palette Emacs reports, and the marks they make.

use super::*;

/// One colour as Emacs measures it: three channels of sixteen bits.
///
/// That is what `color-values' answers and what xterm's `rgb:RRRR/GGGG/BBBB' spells, so a
/// colour crosses from Lisp and goes out to the child with no rescaling anywhere.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub(crate) struct Rgb {
    pub(crate) r: u16,
    pub(crate) g: u16,
    pub(crate) b: u16,
}

impl std::fmt::Display for Rgb {
    /// xterm's answer to a colour query, and the only place a colour is spelled for the
    /// child: Lisp owns the values and this owns the form.
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "rgb:{:04x}/{:04x}/{:04x}", self.r, self.g, self.b)
    }
}

/// Which colour one of the `OSC 10` to `OSC 19` codes asks about.
///
/// The same ten as `cooked--osc-color-sources', which is where the values come from:
/// 13 and 14 are the mouse pointer, 15, 16 and 18 the Tektronix window xterm has and we
/// do not, 17 and 19 the selection. The core keeps their order and not their meaning,
/// except for the two DECSCNM exchanges; see [`Palette::color`].
/// The discriminants are the codes themselves, so the slot a code names and the place
/// its colour sits in the pushed table are one fact rather than two.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
#[repr(u16)]
pub(crate) enum Slot {
    Foreground = 10,
    Background = 11,
    Cursor = 12,
    PointerForeground = 13,
    PointerBackground = 14,
    TekForeground = 15,
    TekBackground = 16,
    HighlightBackground = 17,
    TekCursor = 18,
    HighlightForeground = 19,
}

impl Slot {
    /// The slots in the order their codes run, which is the order Lisp pushes them in;
    /// `slots_are_the_codes_in_order` holds the two together.
    pub(super) const ALL: [Slot; 10] = [
        Slot::Foreground,
        Slot::Background,
        Slot::Cursor,
        Slot::PointerForeground,
        Slot::PointerBackground,
        Slot::TekForeground,
        Slot::TekBackground,
        Slot::HighlightBackground,
        Slot::TekCursor,
        Slot::HighlightForeground,
    ];

    /// The lowest code that names a slot, so the table is indexed by `code - FIRST`.
    const FIRST: u16 = Slot::Foreground as u16;

    /// Where this slot's colour sits in the table Lisp pushed.
    fn index(self) -> usize {
        usize::from(self as u16 - Self::FIRST)
    }
}

impl TryFrom<u16> for Slot {
    type Error = ();

    /// The slot `OSC CODE` asks about, for a CODE in 10 to 19 and nothing else.
    ///
    /// A chained query walks past 19 -- `OSC 19 ; ? ; ?` asks about a code that names
    /// nothing -- and that field is answered by silence, which is what the Lisp handler
    /// this replaced always did with it.
    fn try_from(code: u16) -> Result<Self, Self::Error> {
        let index = code.checked_sub(Self::FIRST).ok_or(())?;
        Self::ALL.get(usize::from(index)).copied().ok_or(())
    }
}

/// The colours Emacs draws with, as the child is to be told them.
///
/// Held so that every colour query can be answered where it arrives, the way
/// [`State::color_scheme`](super::State#structfield.color_scheme) lets `CSI ? 996 n` be.
/// A theme-aware program probes for the background in its first instant, and answering
/// from Lisp cost that probe a wake, a drain and a reply batch, behind
/// `cooked-min-redisplay-interval' when the screen was busy.
///
/// Lisp owns the values and pushes the whole table -- at the spawn, on a theme change,
/// and whenever the frame's cursor colour moves; see `cooked--sync-palette'. Empty until
/// it does, and a slot nothing has reported is answered with silence rather than by
/// asking Lisp, which is what `cooked--osc-color' does with a colour it cannot resolve.
/// So a bare [`Term`] with no session behind it answers no colour query at all.
///
/// [`Slot::Foreground`] and [`Slot::Background`] are the colours the buffer *draws*,
/// DECSCNM not applied: reverse video swaps the pair for a query as it does for the
/// screen, and the swap is made at the query, because the mode is the child's to change
/// between two pushes. A remap an `OSC 11` set made is already in them, that being what
/// Lisp draws with.
#[derive(Debug, Clone)]
pub(crate) struct Palette {
    defaults: [Option<Rgb>; Slot::ALL.len()],
    /// The 256 indexed colours, by index: the sixteen ANSI ones as the theme's
    /// `ansi-color-' faces resolve them, and the xterm cube and grey ramp above them.
    indexed: Box<[Option<Rgb>; 256]>,
}

impl Default for Palette {
    fn default() -> Self {
        Self {
            defaults: [None; Slot::ALL.len()],
            indexed: Box::new([None; 256]),
        }
    }
}

impl Palette {
    /// The palette Lisp pushed: DEFAULTS in [`Slot::ALL`] order, INDEXED by index.
    ///
    /// Either may run short, and what is left over stays unheld rather than becoming a
    /// colour: a caller with half a table has half an answer, and the other half is
    /// silence.
    pub(crate) fn new(
        defaults: impl IntoIterator<Item = Option<Rgb>>,
        indexed: impl IntoIterator<Item = Option<Rgb>>,
    ) -> Self {
        let mut palette = Self::default();
        for (slot, color) in palette.defaults.iter_mut().zip(defaults) {
            *slot = color;
        }
        for (slot, color) in palette.indexed.iter_mut().zip(indexed) {
            *slot = color;
        }
        palette
    }

    /// The colour SLOT holds, exchanging the two defaults when REVERSED.
    ///
    /// Under DECSCNM xterm answers with the colours it is drawing rather than the ones it
    /// was given, and so do we: a child that turned mode 5 on and asks for the background
    /// is told the foreground. The Tektronix pair is deliberately not exchanged -- it
    /// names a window that does not exist here and reads the defaults as they stand,
    /// which is what `cooked--child-color' does with it.
    fn color(&self, slot: Slot, reversed: bool) -> Option<Rgb> {
        let slot = match (slot, reversed) {
            (Slot::Foreground, true) => Slot::Background,
            (Slot::Background, true) => Slot::Foreground,
            (slot, _) => slot,
        };
        self.defaults[slot.index()]
    }
}

/// What one colour sequence asks of the terminal.
///
/// Both halves matter to the caller: the bytes are what the child is owed, and `sets`
/// is why a sequence can still be Lisp's business, since whether a set is honoured is
/// policy (`cooked-allow-color-set') and the answer to a `?` after it depends on that.
pub(crate) struct ColorQuery {
    /// The replies the query fields are owed, framed and concatenated in order.
    pub(crate) answer: Vec<u8>,
    /// Whether any field asked to *change* a colour rather than read one.
    pub(crate) sets: bool,
}

impl State {
    /// What the colour sequence `OSC CODE ; FIELDS` asks for, or `None` for an OSC that
    /// asks about no colour at all.
    ///
    /// The one walker over a colour sequence, shared by the two ways one is answered: the
    /// core answers a plain query where it arrives, and `cooked--answer-color-query' asks
    /// for the answer to a sequence that also held a set, once Lisp has applied or
    /// refused it. So there is one reading of the fields and one formatter, and a reply
    /// keeps its place in the order either way.
    ///
    /// A field nobody can answer -- a palette index that is not a number, a code past 19,
    /// a colour Lisp has not reported -- contributes nothing and does not disturb the
    /// fields around it, which is what the Lisp handlers this replaced did with it.
    pub(super) fn color_query<'a>(
        &self,
        code: u16,
        fields: impl Iterator<Item = &'a [u8]>,
        terminator: Terminator,
    ) -> Option<ColorQuery> {
        let mut query = ColorQuery {
            answer: Vec::new(),
            sets: false,
        };
        let reversed = self.modes.reverse_screen;
        let mut reply = |code: u16, payload: &str| {
            if let Some(bytes) = reply::osc_reply(code, payload, terminator) {
                query.answer.extend_from_slice(&bytes);
            }
        };
        if code == PALETTE {
            // `INDEX ; SPEC` per entry, so a field with no partner asks nothing. A set is
            // not reported: OSC 4 sets are declined whatever the policy says, for the
            // reason `ccc' and `initc' give in terminfo/cooked.ti -- Emacs owns colour,
            // and a per-buffer 256-entry palette is the wrong seam.
            let fields: Vec<&[u8]> = fields.collect();
            for pair in fields.chunks_exact(2) {
                let Some(index) = query_index(pair) else {
                    continue;
                };
                if let Some(color) = self.palette.indexed[usize::from(index)] {
                    reply(PALETTE, &format!("{index};{color}"));
                }
            }
            return Some(query);
        }
        Slot::try_from(code).ok()?;
        for (offset, spec) in fields.enumerate() {
            // Each field is about the next code along: `OSC 10 ; ? ; ?` asks for the
            // foreground and then the background.
            let Ok(code) = u16::try_from(offset).map(|offset| code + offset) else {
                break;
            };
            if spec != b"?" {
                query.sets = true;
                continue;
            }
            if let Ok(slot) = Slot::try_from(code)
                && let Some(color) = self.palette.color(slot, reversed)
            {
                reply(code, &color.to_string());
            }
        }
        Some(query)
    }
}

/// The palette index PAIR asks about, if it is a query for one this can read.
///
/// The Lisp handler this replaced read the index with `[0-9]\{1,3\}' and then refused
/// anything over 255, which is what parsing it as a `u8` says in one step.
fn query_index(pair: &[&[u8]]) -> Option<u8> {
    (pair[1] == b"?")
        .then(|| std::str::from_utf8(pair[0]).ok()?.parse().ok())
        .flatten()
}

/// `OSC 4`, the indexed palette, which is read as pairs rather than as one colour per
/// code.
const PALETTE: u16 = 4;

/// An OSC payload cut at each `;`, which is how every colour sequence is laid out.
///
/// The same split Lisp is handed as `parts', so the two ways into [`State::color_query`]
/// -- the payload as it arrives and the fields Lisp hands back -- read the same fields.
pub(crate) fn split_fields(payload: &[u8]) -> impl Iterator<Item = &[u8]> {
    payload.split(|&b| b == b';')
}

/// BYTES cut at the first `;`: the field before it, and everything after it.
///
/// Everything, because the parser hands an OSC payload over whole and a URI, a path or a
/// piece of text can contain semicolons of its own. With no `;` the second half is empty.
pub(crate) fn split_field(bytes: &[u8]) -> (&[u8], &[u8]) {
    match memchr::memchr(b';', bytes) {
        Some(at) => (&bytes[..at], &bytes[at + 1..]),
        None => (bytes, &[]),
    }
}

/// The destination an OSC 8 PAYLOAD names, `PARAMS ; URI`, if it passes
/// [`validated_text`]. Empty for the OSC 8 that closes a link.
///
/// PARAMS is ignored. The only one anybody sends is `id=`, and content-addressing
/// already answers what it is for; see [`LinkStore::intern`].
pub(crate) fn hyperlink_uri(payload: &[u8]) -> Option<String> {
    validated_text(split_field(payload).1, MAX_URI_LEN)
}

/// BYTES as text, if they are UTF-8 of at most MAX bytes with no control character in
/// them.
///
/// For a payload Emacs will act on rather than display: a hyperlink's destination reaches
/// `browse-url`, and a working directory becomes `default-directory`. A newline or an
/// `ESC` inside either is not something anybody meant, so the payload is refused whole
/// rather than trimmed. The length is checked here because the grid's OSC 8 and the
/// comint filter's OSC 7 both return before any generic payload limit applies.
pub(crate) fn validated_text(bytes: &[u8], max: usize) -> Option<String> {
    if bytes.len() > max {
        return None;
    }
    let text = std::str::from_utf8(bytes).ok()?;
    (!text::has_control(text)).then(|| text.to_owned())
}

impl Mark {
    /// The mark an OSC 133 PAYLOAD spells, or `None` for one cooked does not act on.
    ///
    /// The kind is matched whole rather than on its first byte, so `Dfoo` is not read as
    /// `D`. `A` is the only spelling of a prompt start: the proposal also allows `P`, but
    /// cooked implements no fresh-line behaviour to tell the two apart, and none of the
    /// integrations that reach it send `P`.
    pub(super) fn parse(payload: &[u8]) -> Option<Mark> {
        let (letter, options) = split_field(payload);
        let mut options = options.split(|&b| b == b';');
        match letter {
            b"A" => Self::prompt_kind(options),
            b"B" => Some(Mark::PromptEnd),
            // A command line that is too long or not text still leaves a `C`: the mark is
            // the part Emacs cannot do without, and the command line is a courtesy.
            b"C" => Some(Mark::CommandStart(Self::cmdline(options))),
            b"D" => Some(Mark::CommandEnd(
                options
                    .next()
                    .and_then(|p| std::str::from_utf8(p).ok())
                    .and_then(|s| s.parse().ok()),
            )),
            _ => None,
        }
    }

    /// Which prompt an `A` mark announces, or `None` for one that is neither.
    ///
    /// `k=` names it: `i` initial, `s` secondary (zsh's and bash's `PS2`), `c`
    /// continuation, and `r` the prompt drawn on the right of the input line. Absent or
    /// empty means `i`, which is the proposal's default and what cooked's own snippets
    /// rely on.
    ///
    /// A right-hand prompt is neither: it starts no command, so it must not move the prompt
    /// marker, and it must not be read as a `PS2`, because no `B` follows it and Emacs
    /// would wait at `prompt` for good. An unknown kind is dropped the same way, since
    /// dropping changes no state.
    ///
    /// OPTIONS is what followed the letter, cut at each `;`. Other emitters' options -- kitty's `click_events=`, Ghostty's
    /// `redraw=` -- are not `k=` and leave the prompt initial.
    fn prompt_kind<'a>(mut options: impl Iterator<Item = &'a [u8]>) -> Option<Mark> {
        let kind = options.find_map(|opt| opt.strip_prefix(b"k=".as_slice()));
        match kind {
            None | Some(b"" | b"i") => Some(Mark::PromptStart),
            Some(b"s" | b"c") => Some(Mark::PromptContinuation),
            Some(_) => None,
        }
    }

    /// The command line a `C` mark carries, from `cmdline_url=`.
    ///
    /// This is what the shell is about to run, in its own words, and the only account that
    /// survives where Emacs has none: a line the shell kept, or the far end of an `ssh`.
    /// Where Emacs has one it still wins, since `cooked-line-submitted-input` is what
    /// Emacs *sent* and this is what the shell parsed.
    ///
    /// `cmdline_url=` and not kitty's `cmdline=`, which holds `printf %q` output that only
    /// that shell can unquote, so `ls -la` arrives as `ls\ -la`. Percent-encoding has one
    /// reading, and fish 4 already sends it.
    ///
    /// Capped at [`MAX_CMDLINE_LEN`] because this returns before `osc_dispatch`'s generic
    /// limit. Control characters are dropped, except the newline a multi-line construct
    /// contains and a tab.
    fn cmdline<'a>(mut options: impl Iterator<Item = &'a [u8]>) -> Option<String> {
        let raw = options.find_map(|opt| opt.strip_prefix(b"cmdline_url=".as_slice()))?;
        if raw.len() > MAX_CMDLINE_LEN {
            return None;
        }
        let decoded = Self::percent_decode(raw);
        let text: String = String::from_utf8_lossy(&decoded)
            .chars()
            .filter(|c| !c.is_control() || *c == '\n' || *c == '\t')
            .collect();
        (!text.is_empty()).then_some(text)
    }

    /// `%XX` back into bytes, leaving anything that is not a complete escape alone.
    ///
    /// Lenient on purpose: a trailing `%` or a `%g7` is a malformed sender rather than an
    /// attack, and passing the bytes through unchanged shows the user what arrived. The
    /// result is bytes rather than a string because a multi-byte character arrives as one
    /// `%XX` per byte and only reassembles once they are all back.
    fn percent_decode(raw: &[u8]) -> Vec<u8> {
        let mut out = Vec::with_capacity(raw.len());
        let mut rest = raw;
        while let Some((&first, tail)) = rest.split_first() {
            match (first, tail) {
                (b'%', [hi, lo, ..]) if let Some(byte) = crate::emu::bytes::hex_byte(*hi, *lo) => {
                    out.push(byte);
                    rest = &tail[2..];
                }
                _ => {
                    out.push(first);
                    rest = tail;
                }
            }
        }
        out
    }
}

impl State {
    /// OSC 133: a shell's semantic mark, anchored where it fell in the stream.
    ///
    /// Dropped while the alternate screen is up. Its rows never become buffer text, so
    /// a mark there has no line to name: the alternate screen scrolls without
    /// scrollback and the mark cannot move with its row, so after `seq 1 60` a prompt
    /// mark from a shell inside tmux names a line of output. It would be filed with a
    /// command record all the same, and `cooked-previous-command` and the fringe would
    /// point at that line, or, once the primary screen is back, at whatever transcript
    /// text the position has come to hold.
    pub(super) fn semantic(&mut self, payload: &[u8]) {
        if self.shown.is_alternate() {
            return;
        }
        // Parsed before a mark is taken, so an ignored mark leaves no id on the grid that
        // Emacs is never told about.
        let Some(mark) = Mark::parse(payload) else {
            return;
        };
        let at = self.anchor();
        // Left on the cell as well, so that a rewrap can be told where it went.
        let id = self.take_mark(at);
        // Only an initial prompt moves `prompt_start`. A continuation prompt is the same
        // command still being typed, so the prompt it began at is the one
        // `clear_to_prompt` must keep and the one Emacs files the command record under.
        // The command marks move the input modes; see [`State::take_back`].
        match mark {
            Mark::PromptStart => self.prompt_start = Some(id),
            Mark::CommandStart(_) => self.hand_over(),
            Mark::CommandEnd(_) => self.take_back(),
            Mark::PromptContinuation | Mark::PromptEnd => {}
        }
        self.events.push(Queued::Mark(mark, at, id));
    }

    /// Name the mark at ANCHOR and leave it on the cell the anchor points at, which is on
    /// the primary screen, since [`State::semantic`] takes no mark on the alternate one.
    pub(super) fn take_mark(&mut self, at: Anchor<Cols>) -> MarkId {
        let id = MarkId::from_index(self.next_mark);
        self.next_mark = self.next_mark.wrapping_add(1);
        if let Some(row) = at.row.checked_sub(self.evicted_total) {
            self.screens.primary.mark(row, at.col, id);
        }
        id
    }

    /// Where every mark Emacs may be holding a stale marker for is now, or nothing.
    ///
    /// Nothing on a drain where nothing moved, at the cost of one boolean test. Otherwise
    /// -- a resize, a redraw, or an eviction -- it is the marks that left the grid,
    /// recorded as they went, plus every mark still on it. The walk skips a row with no
    /// attachments on a null check.
    pub(super) fn take_marks(&mut self) -> Vec<(MarkId, Anchor<Chars>)> {
        if !self.marks_dirty {
            return Vec::new();
        }
        self.marks_dirty = false;
        let mut marks = std::mem::take(&mut self.evicted_marks);
        marks.extend(Self::marks_in(
            self.screens.primary.rows(),
            self.evicted_total,
        ));
        marks
    }

    /// Every mark ROWS carry, numbered from absolute row BASE, each at the characters of
    /// its row's text before it; see [`Delta::marks`].
    ///
    /// Used by [`State::take_marks`] over the live primary grid. Rows that left the grid
    /// carry their marks out in [`Departed`](crate::emu::screen::Departed) instead. Lazy,
    /// so a row without marks allocates nothing.
    pub(super) fn marks_in<'a>(
        rows: impl Iterator<Item = RowRef<'a>>,
        base: usize,
    ) -> impl Iterator<Item = (MarkId, Anchor<Chars>)> {
        rows.enumerate().flat_map(move |(index, row)| {
            row.into_marks().map(move |(col, id)| {
                (
                    id,
                    Anchor {
                        row: base + index,
                        col: row.chars_before(col),
                    },
                )
            })
        })
    }

    /// `OSC 8 ; PARAMS ; URI ST` — open a hyperlink, or close the one that is open.
    ///
    /// An empty URI closes, and apart from a reset nothing else does; see [`PenState`]
    /// for why an SGR reset must not.
    ///
    /// The URI goes through [`hyperlink_uri`], so one containing a `;` arrives whole and
    /// one carrying a control character or longer than [`MAX_URI_LEN`] is refused.
    pub(super) fn hyperlink(&mut self, payload: &[u8]) {
        let Some(uri) = hyperlink_uri(payload) else {
            return;
        };
        if uri.is_empty() {
            self.pen.set_link(None);
            return;
        }
        if self.links.is_full() {
            self.collect_links();
        }
        let (id, fresh) = self.links.intern(&uri);
        if fresh {
            self.pending_links.push((id, uri));
        }
        self.pen.set_link(Some(id));
    }

    /// `OSC 66 ; METADATA ; TEXT ST` — kitty's [text sizing protocol], width only.
    ///
    /// The escape carries its own text: the payload is what gets printed, capped by the
    /// spec at 4096 bytes. `METADATA` is a colon-separated list of `key=value` pairs.
    ///
    /// **`w=N` is honoured; `s`, `n`, `d`, `v` and `h` are parsed and dropped.** The spec
    /// allows exactly that: "It is possible for a terminal to implement only the width part
    /// of this spec and ignore the scale part... In such cases `s` defaults to 1." Scale
    /// would mean rendering at a multiple of the font size, and Emacs lays text out at the
    /// frame's own character height.
    ///
    /// Width is the part clients need: the client says how many cells a piece of text
    /// occupies, and that number reaches Emacs intact through
    /// [`Run::cols`](crate::emu::cell::Run::cols).
    ///
    /// **Nothing is declined out loud, because the protocol has no reply.** A client
    /// detects support by printing `w=2` text between two `CPR` queries and checking that
    /// the cursor moved two cells, so getting the cursor arithmetic right is the whole of
    /// the answer; a client probing `s=2` sees one cell and correctly concludes that scale
    /// is unsupported.
    ///
    /// [text sizing protocol]: https://sw.kovidgoyal.net/kitty/text-sizing-protocol/
    pub(super) fn text_size(&mut self, payload: &[u8]) {
        let (meta, raw) = split_field(payload);
        let Some(width) = Self::text_size_width(meta) else {
            return;
        };
        // The cap is the spec's own; see [`MAX_TEXT_SIZE_LEN`].
        if raw.len() > MAX_TEXT_SIZE_LEN {
            return;
        }
        // Lossy, as the spec asks: ill-formed UTF-8 becomes `U+FFFD` rather than dropping
        // the escape. Controls are stripped, since a newline cannot be part of a block
        // standing on a stated number of cells.
        let text: String = String::from_utf8_lossy(raw)
            .chars()
            .filter(|c| !c.is_control())
            .collect();
        if text.is_empty() {
            return;
        }
        let (pen, cols) = (self.pen(), Cols::new(self.screen().width()));
        // "If the multicell block is larger than the screen size in either dimension,
        // the terminal must discard the character." Drawing part of it would move the
        // cursor by something other than the declared width.
        if width == 0 {
            // `w=0` is "split it up as you normally would", so it is the ordinary
            // printing path with the payload standing in for the stream — one cell per
            // grapheme cluster, at the width the cluster measures.
            let mut last = None;
            for (cluster, cells) in text::clusters(&text) {
                if cells > cols {
                    continue;
                }
                self.evicting(|screen| screen.write_cluster(cluster, cells, pen));
                last = Some((cluster.to_owned(), cells));
            }
            // The cursor is left on the last block drawn, so a combining mark arriving
            // next joins it rather than opening a cell of its own.
            match last {
                Some((cluster, cells)) => self.text.restart(&cluster, Width::measured(cells)),
                None => self.text.reset(),
            }
            return;
        }
        let width = Cols::new(usize::from(width));
        if width > cols {
            return;
        }
        self.evicting(|screen| screen.write_cluster(&text, width, pen));
        // Seeded with the *declared* width, not the measured one: that is where the cell
        // begins as far as the grid is concerned, so it is what [`Screen::join`] needs to
        // find it again.
        self.text.restart(&text, Width::declared(width));
    }

    /// The `w=` value, or `None` if the metadata is not something to act on.
    ///
    /// Unknown keys are ignored, since a protocol grows by adding keys and an unfamiliar one
    /// means a newer sender. A known key with a value out of range means a broken sender,
    /// and the whole escape is dropped rather than guessing at a width.
    fn text_size_width(meta: &[u8]) -> Option<u8> {
        let mut width = 0;
        for pair in meta.split(|b| *b == b':') {
            if pair.is_empty() {
                continue;
            }
            let (key, value) = pair.split_at(pair.iter().position(|b| *b == b'=')?);
            let value: u8 = std::str::from_utf8(&value[1..]).ok()?.parse().ok()?;
            let ok = match key {
                b"s" => (1..=7).contains(&value),
                b"w" => {
                    width = value;
                    value <= 7
                }
                b"n" | b"d" => value <= 15,
                b"v" | b"h" => value <= 2,
                // Not ours, and not an error either. See above.
                _ => true,
            };
            if !ok {
                return None;
            }
        }
        Some(width)
    }

    pub(super) fn osc(&mut self, code: OscCode, payload: Option<&[u8]>, bell_terminated: bool) {
        let body = payload.unwrap_or_default();
        if code == OscCode::SEMANTIC_PROMPT {
            self.semantic(body);
            return;
        }
        // Before the generic path, and returning: OSC 8 is grid state, and handing it to
        // Lisp as well would invite a second implementation there.
        if code == OscCode::HYPERLINK {
            self.hyperlink(body);
            return;
        }
        // The same reasoning, more so: OSC 66 does not merely change grid state, it
        // *writes to the grid*. Its payload is text, and text belongs to one writer.
        if code == OscCode::TEXT_SIZE {
            self.text_size(body);
            return;
        }
        // A hostile stream should not get to size our heap, and nothing legitimate -- a
        // title, a directory, a clipboard write -- comes close. 1337 carries a whole base64
        // image, so it gets the parser's own cap, `MAX_OSC_RAW`.
        let limit = if code == OscCode::ITERM {
            crate::emu::parser::MAX_OSC_RAW
        } else {
            OSC_PAYLOAD_LIMIT
        };
        if body.len() > limit {
            return;
        }
        // Only `File=` is ours. The rest of iTerm2's private channel, such as `SetUserVar`,
        // goes on to Lisp as an `Event::Osc`.
        if code == OscCode::ITERM && self.iterm_file(body) {
            return;
        }
        // A colour query is answered here and raises no event, so a start-up probe costs
        // the child nothing but the reply. Two things still go to Lisp: a sequence
        // holding a *set*, since whether it is honoured is policy and the answer to a `?`
        // after it turns on that, and any query arriving while such a sequence is still
        // unhandled, which would otherwise be answered with the colour being replaced.
        // Lisp comes back through `cooked--answer-color-query', so the bytes are still
        // this walker's; see [`State::color_query`].
        // The indexed palette is answered whatever else is in flight: an `OSC 4` set is
        // declined whatever the policy says, so no sequence Lisp has yet to handle can
        // move an entry. The ten defaults can be moved by such a sequence, so a query for
        // one goes to Lisp behind it rather than answering the colour being replaced.
        if let Some(query) = self.color_query(
            code.get(),
            split_fields(body),
            Terminator::from_bell(bell_terminated),
        ) && !query.sets
            && (code.get() == PALETTE || !self.palette_pending)
        {
            if !query.answer.is_empty() {
                self.push_reply(Reply::answer(query.answer));
            }
            return;
        }
        // Lisp takes the payload as fields, which is how every OSC it handles is laid
        // out. At most [`MAX_OSC_FIELDS`], the last of which keeps whatever semicolons
        // are left, so a payload of nothing but `;` is not a list a megabyte long. None
        // at all for an OSC with no `;`, which is how `OSC 112 ST` differs from
        // `OSC 112 ; ST`.
        //
        // Handed over lossily rather than dropped: a mangled title is better than a
        // silently vanished one, and callers can validate.
        let parts = payload
            .into_iter()
            .flat_map(|body| body.splitn(MAX_OSC_FIELDS, |&b| b == b';'))
            .map(|p| String::from_utf8_lossy(p).into_owned())
            .collect();
        self.push_for_lisp(Event::Osc(
            code.get(),
            parts,
            Terminator::from_bell(bell_terminated),
        ));
    }
}
