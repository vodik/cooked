//! `OSC` dispatch: semantic prompts (133), hyperlinks (8), text sizing (66), and the
//! marks they make.

use super::*;

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
        let Some(mark) = Self::parse_mark(payload) else {
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
            Mark::PromptStart => self.prompt_start = Some(at),
            Mark::CommandStart(_) => self.hand_over(),
            Mark::CommandEnd(_) => self.take_back(),
            Mark::PromptContinuation | Mark::PromptEnd => {}
        }
        self.events.push(Event::Mark(mark, at, id));
    }

    /// The mark PARAMS spell, or `None` for one cooked does not act on.
    ///
    /// The kind is matched whole rather than on its first byte, so `Dfoo` is not read as
    /// `D`. `A` is the only spelling of a prompt start: the proposal also allows `P`, but
    /// cooked implements no fresh-line behaviour to tell the two apart, and none of the
    /// integrations that reach it send `P`.
    fn parse_mark(payload: &[u8]) -> Option<Mark> {
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

    /// Name the mark at ANCHOR and leave it on the cell the anchor points at, which is on
    /// the primary screen, since [`State::semantic`] takes no mark on the alternate one.
    pub(super) fn take_mark(&mut self, at: Anchor) -> MarkId {
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
    pub(super) fn take_marks(&mut self) -> Vec<(MarkId, Anchor)> {
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
    ) -> impl Iterator<Item = (MarkId, Anchor)> {
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
        let (pen, cols) = (self.pen(), self.screen().width());
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
                Some((cluster, cells)) => self.text.restart(&cluster, Width::Measured(cells)),
                None => self.text.reset(),
            }
            return;
        }
        let width = usize::from(width);
        if width > cols {
            return;
        }
        self.evicting(|screen| screen.write_cluster(&text, width, pen));
        // Seeded with the *declared* width, not the measured one: that is where the cell
        // begins as far as the grid is concerned, so it is what [`Screen::join`] needs to
        // find it again.
        self.text.restart(&text, Width::Declared(width));
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

    pub(super) fn osc(&mut self, code: u16, payload: Option<&[u8]>, bell_terminated: bool) {
        let body = payload.unwrap_or_default();
        if code == 133 {
            self.semantic(body);
            return;
        }
        // Before the generic path, and returning: OSC 8 is grid state, and handing it to
        // Lisp as well would invite a second implementation there.
        if code == 8 {
            self.hyperlink(body);
            return;
        }
        // The same reasoning, more so: OSC 66 does not merely change grid state, it
        // *writes to the grid*. Its payload is text, and text belongs to one writer.
        if code == 66 {
            self.text_size(body);
            return;
        }
        // A hostile stream should not get to size our heap, and nothing legitimate -- a
        // title, a directory, a clipboard write -- comes close. 1337 carries a whole base64
        // image, so it gets the parser's own cap, `MAX_OSC_RAW`.
        let limit = if code == 1337 {
            crate::emu::parser::MAX_OSC_RAW
        } else {
            OSC_PAYLOAD_LIMIT
        };
        if body.len() > limit {
            return;
        }
        // Only `File=` is ours. The rest of iTerm2's private channel, such as `SetUserVar`,
        // goes on to Lisp as an `Event::Osc`.
        if code == 1337 && self.iterm_file(body) {
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
            code,
            parts,
            Terminator::from_bell(bell_terminated),
        ));
    }
}
