//! `OSC` dispatch: semantic prompts (133), hyperlinks (8), and the marks they make.

use super::*;

impl State {
    pub(super) fn semantic(&mut self, params: &[&[u8]]) {
        // Matched whole, not on the first byte. `params.get(1).and_then(|p| p.first())`
        // read `Dfoo` as a `D`, which is a parser agreeing with a sender that means
        // something else -- and the kinds are single letters, so exactness is free.
        let Some(kind) = params.get(1).copied() else {
            return;
        };
        // `A` only. The proposal also spells this mark `P`, and Ghostty sends that one
        // to avoid `A`'s implied fresh line -- but cooked implements no fresh-line
        // behaviour, so the two would be the same mark to it, and nothing on this wire
        // sends `P` anyway: cooked's own snippets emit `A`, fish 4 emits `A`, and
        // kitty's and Ghostty's integrations gate themselves on environment variables
        // cooked never sets and that no `ssh` carries. One spelling end to end.
        let prompt = kind == b"A";
        if !prompt && !matches!(kind, b"B" | b"C" | b"D") {
            return;
        }
        // Decided before a mark is taken, because "ignore this" has to leave *no* trace:
        // an id allocated for an event that is never pushed is a mark on the grid Emacs
        // is never told about, which a later rewrap would then carry around for nobody.
        let kind_of_prompt = prompt.then(|| Self::prompt_kind(params));
        if kind_of_prompt == Some(PromptKind::Other) {
            return;
        }
        // Read before the mark is taken, so that a `C` carrying a command line that is
        // too long or not text is still a `C`: the mark is the part Emacs cannot do
        // without, and the command line is a courtesy on top of it.
        let cmdline = (kind == b"C").then(|| Self::cmdline(params)).flatten();
        // Anchored here, where the mark actually is in the stream. See [`Anchor`].
        let at = self.anchor();
        // And left on the cell, so that a rewrap can be told where it went. Allocated
        // before the match rather than per arm: every kind that gets an event gets an id,
        // and an arm that forgot to take one would be a mark Emacs could never be told
        // about again.
        let id = self.take_mark(at);
        self.events.push(match kind {
            b"A" => {
                if kind_of_prompt == Some(PromptKind::Continuation) {
                    // Deliberately *not* moving `prompt_start`. A continuation prompt is
                    // the same command still being typed, so the prompt it began at is
                    // the one `clear_to_prompt` must keep and the one Emacs files the
                    // command record under -- taking the last continuation line instead
                    // would start the record halfway through the construct.
                    Event::PromptContinuation(at, id)
                } else {
                    self.prompt_start = Some(at);
                    Event::PromptStart(at, id)
                }
            }
            b"B" => Event::PromptEnd(at, id),
            b"C" => Event::CommandStart(cmdline, at, id),
            b"D" => Event::CommandEnd(
                params
                    .get(2)
                    .and_then(|p| std::str::from_utf8(p).ok())
                    .and_then(|s| s.parse().ok()),
                at,
                id,
            ),
            _ => return,
        });
    }

    /// What kind of prompt an `A` mark is announcing.
    ///
    /// `k=` names it: `i` initial, `s` secondary — zsh's and bash's `PS2` — `c`
    /// continuation, `r` the prompt drawn on the *right* of the input line. Absent, or
    /// present but empty, means `i`: the proposal gives the kind that default, and an
    /// emitter writing `k=` with nothing after it is not announcing a new kind. cooked's
    /// own snippets rely on that default and send a bare `A` for an initial prompt.
    ///
    /// Three answers rather than the boolean this used to be, because `r` belongs to
    /// neither. A right-hand prompt is decoration beside an input area cooked already
    /// owns: it starts no command, so it must not move the prompt marker, and it
    /// continues nothing, so it must not be read as a `PS2` either. Read as a
    /// continuation it was a session-ending bug -- no `B` follows a right prompt, so
    /// Emacs went to `prompt` and never came back, and the input line was gone for good.
    ///
    /// A kind nobody here has heard of joins `r` rather than joining `s`. The safe
    /// answer for an unknown mark is to change no state at all, and both of the other
    /// two answers change state.
    ///
    /// Options are read from `params[2..]`, which is where they arrive: `;` separates
    /// OSC parameters, so `133;A;k=s` is three of them. Every other option any emitter
    /// sends -- kitty's `click_events=`, Ghostty's `redraw=` and `cl=`, ble.sh's
    /// `aid=` -- is not a `k=` and so leaves the answer at `Initial`.
    fn prompt_kind(params: &[&[u8]]) -> PromptKind {
        let Some(kind) = params
            .iter()
            .skip(2)
            .find_map(|opt| opt.strip_prefix(b"k=".as_slice()))
        else {
            return PromptKind::Initial;
        };
        match kind {
            b"" | b"i" => PromptKind::Initial,
            b"s" | b"c" => PromptKind::Continuation,
            _ => PromptKind::Other,
        }
    }

    /// The command line a `C` mark carries, from `cmdline_url=`.
    ///
    /// This is what the shell is about to run, said by the shell itself, and it is the
    /// only account of it that survives the cases where Emacs has none: a prompt whose
    /// line the shell kept, a program reading input of its own, the far end of an `ssh`.
    /// Where Emacs does have one, this still wins — `cooked--submitted-input` is what
    /// Emacs *sent*, assembled by hand across the lines of a multi-line construct, while
    /// this is what the shell parsed.
    ///
    /// `cmdline_url=` and not kitty's `cmdline=`. The two carry the same thing and
    /// kitty's is the older spelling, but it holds `printf %q` output — shell quoting,
    /// which only that shell can undo, so `ls -la` arrives as `ls\ -la`. Guessing at an
    /// unquoting would put the guess in the command record and there would be no way to
    /// tell it from the truth. Percent-encoding has one reading, and it is what fish 4
    /// already sends: a fish doing its own marking gets this for free.
    ///
    /// Capped at [`MAX_CMDLINE_LEN`] because this arm returns before `osc_dispatch`'s
    /// generic limit, the same way [`State::hyperlink`] is. Control characters are
    /// dropped, except the newline that a multi-line construct genuinely contains and
    /// the tab that can be typed into one.
    fn cmdline(params: &[&[u8]]) -> Option<String> {
        let raw = params
            .iter()
            .skip(2)
            .find_map(|opt| opt.strip_prefix(b"cmdline_url=".as_slice()))?;
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
        let hex = |b: u8| (b as char).to_digit(16);
        let mut out = Vec::with_capacity(raw.len());
        let mut rest = raw;
        while let Some((&first, tail)) = rest.split_first() {
            match (first, tail) {
                (b'%', [hi, lo, ..]) if let (Some(hi), Some(lo)) = (hex(*hi), hex(*lo)) => {
                    out.push((hi * 16 + lo) as u8);
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

    /// Name the mark at ANCHOR and leave it on the cell the anchor points at.
    ///
    /// Nothing is attached while the alternate screen is up. That grid is a running
    /// program's frame: its rows never become buffer text, they are dropped rather than
    /// archived when the program leaves, and Emacs' marker for such a mark points into
    /// the primary's text underneath. There is nothing there a rewrap could move.
    pub(super) fn take_mark(&mut self, at: Anchor) -> MarkId {
        let id = MarkId(self.next_mark);
        self.next_mark = self.next_mark.wrapping_add(1);
        if !self.on_alt
            && let Some(row) = at.row.checked_sub(self.evicted_total)
        {
            self.primary.mark(row, at.col, id);
        }
        id
    }

    /// Where every mark Emacs may be holding a stale marker for is now, or nothing.
    ///
    /// Nothing on a drain where nothing moved, which is the overwhelming case and costs
    /// one boolean test. Otherwise -- a resize, a redraw, or any drain that evicted a row
    /// -- it is the marks that left the grid meanwhile, recorded as they went, plus every
    /// mark still on it, read now. The grid walk is bounded by the screen's height and
    /// skips a row with no attachments on a null check, so the cost is a scan of a few
    /// dozen pointers on drains that were already rewriting rows.
    pub(super) fn take_marks(&mut self) -> Vec<(MarkId, Anchor)> {
        if !self.marks_dirty {
            return Vec::new();
        }
        self.marks_dirty = false;
        let mut marks = std::mem::take(&mut self.evicted_marks);
        marks.extend(Self::marks_in(self.primary.rows(), self.evicted_total));
        marks
    }

    /// Every mark ROWS carry, numbered from absolute row BASE.
    ///
    /// One caller: [`State::take_marks`], over the live primary grid, on a drain that
    /// something moved. Rows that *left* the grid no longer come through here — they
    /// carry their own marks out in [`Departed`](crate::emu::screen::Departed), recorded
    /// as they went, and `take_marks` merges the two.
    ///
    /// Lazy throughout. This used to `collect` inside the `flat_map`, which cost a `Vec`
    /// per row scanned whether or not the row carried a single mark — and while it was
    /// also on the eviction path, that was a `Vec` per scrolled line.
    pub(super) fn marks_in<'a>(
        rows: impl Iterator<Item = &'a Row>,
        base: usize,
    ) -> impl Iterator<Item = (MarkId, Anchor)> {
        rows.enumerate().flat_map(move |(index, row)| {
            row.marks().map(move |(col, id)| {
                (
                    id,
                    Anchor {
                        row: base + index,
                        col,
                    },
                )
            })
        })
    }

    /// `OSC 8 ; PARAMS ; URI ST` — open a hyperlink, or close the one that is open.
    ///
    /// An empty URI closes. That is the only thing that does, apart from a reset: see
    /// [`State::link`] for why an SGR reset must not, which is the mistake this
    /// implementation is one line away from at all times.
    ///
    /// PARAMS is ignored wholesale. The only one anybody sends is `id=`, and
    /// content-addressing already answers what it is for — see [`LinkStore::intern`].
    ///
    /// The URI is rejoined rather than taken as `params[2]`: `;` separates OSC
    /// parameters, so a URI containing an unescaped one arrives pre-split. It is
    /// refused outright if it carries a control character — the payload reaches
    /// `browse-url` in Emacs, and a URI with a newline in it is not a destination
    /// anybody meant — or if it is longer than [`MAX_URI_LEN`]. Length is checked here
    /// because this arm returns before `osc_dispatch`'s generic payload limit.
    pub(super) fn hyperlink(&mut self, params: &[&[u8]]) {
        let mut uri = Vec::new();
        for (at, part) in params.iter().skip(2).enumerate() {
            if at != 0 {
                uri.push(b';');
            }
            uri.extend_from_slice(part);
        }
        if uri.is_empty() {
            self.link = None;
            return;
        }
        if uri.len() > MAX_URI_LEN {
            return;
        }
        let Ok(uri) = std::str::from_utf8(&uri) else {
            return;
        };
        if uri.chars().any(|c| c.is_control() || c == '\u{7f}') {
            return;
        }
        let (id, fresh) = self.links.intern(uri);
        if fresh {
            self.pending_links.push((id, uri.to_owned()));
        }
        self.link = Some(id);
    }

    pub(super) fn osc(&mut self, params: &[&[u8]], bell_terminated: bool) {
        let Some(code) = params.first().and_then(|p| std::str::from_utf8(p).ok()) else {
            return;
        };
        if code == "133" {
            self.semantic(params);
            return;
        }
        // Before the generic numeric path, and returning rather than falling through:
        // OSC 8 is grid state, so handing it to Lisp as an `Event::Osc` as well would
        // invite a second, disagreeing implementation of it up there.
        if code == "8" {
            self.hyperlink(params);
            return;
        }
        let Ok(code) = code.parse::<u16>() else {
            return;
        };
        // A hostile stream should not get to size our heap for us, and nothing
        // legitimate — title, working directory, hyperlink, clipboard — comes close.
        // 1337 is the exception and needs its own bound, because what it carries is a
        // whole base64 image; the parser has already capped it at `MAX_OSC_RAW`.
        let limit = if code == 1337 {
            crate::emu::parser::MAX_OSC_RAW
        } else {
            OSC_PAYLOAD_LIMIT
        };
        if params[1..].iter().map(|p| p.len()).sum::<usize>() > limit {
            return;
        }
        // Only `File=` is ours. `OSC 1337` is iTerm2's whole private channel —
        // `SetUserVar`, `CurrentDir`, `ShellIntegrationVersion` — and swallowing all of
        // it would quietly close a door Lisp can already reach through `Event::Osc`.
        if code == 1337 && self.iterm_file(params) {
            return;
        }
        // Payloads are handed over lossily rather than dropped: a mangled title is
        // better than a silently vanished one, and callers can validate.
        let parts = params[1..]
            .iter()
            .map(|p| String::from_utf8_lossy(p).into_owned())
            .collect();
        self.events.push(Event::Osc(code, parts, bell_terminated));
    }
}
