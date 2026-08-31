//! `OSC` dispatch: semantic prompts (133), hyperlinks (8), and the marks they make.

use super::*;

impl State {
    pub(super) fn semantic(&mut self, params: &[&[u8]]) {
        let Some(kind) = params.get(1).and_then(|p| p.first()) else {
            return;
        };
        if !matches!(kind, b'A' | b'B' | b'C' | b'D' | b'P') {
            return;
        }
        // Anchored here, where the mark actually is in the stream. See [`Anchor`].
        let at = self.anchor();
        // And left on the cell, so that a rewrap can be told where it went. Allocated
        // before the match rather than per arm: every kind that gets an event gets an id,
        // and an arm that forgot to take one would be a mark Emacs could never be told
        // about again.
        let id = self.take_mark(at);
        self.events.push(match kind {
            // `A` and `P` are the same mark read twice. The proposal defines `A` as
            // shorthand for `P;k=i` and hangs the `k=` option off `P`; kitty spells the
            // secondary prompt `A;k=s` and never sends `P` at all. Accepting both costs
            // one arm, and picking only one would silently lose the continuation prompt
            // of whichever emitter we did not pick.
            b'A' | b'P' => {
                if Self::continues_prompt(params) {
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
            b'B' => Event::PromptEnd(at, id),
            b'C' => Event::CommandStart(at, id),
            b'D' => Event::CommandEnd(
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

    /// Whether an `A`/`P` mark says "this prompt continues the one before it".
    ///
    /// `k=` names the kind of prompt: `i` initial, `s` secondary — zsh's `PS2`, bash's
    /// `PS2` — `c` continuation, `r` the right-hand prompt. Only an initial prompt
    /// begins a command, so the test is "`k=` present and not `i`" rather than a list of
    /// the kinds we happen to have heard of: a kind we do not know is still not the
    /// start of a command, while guessing the other way loses the prompt marker for a
    /// whole multi-line construct.
    ///
    /// Options are read from `params[2..]`, which is where they arrive: `;` separates
    /// OSC parameters, so `133;A;k=s` is three of them.
    fn continues_prompt(params: &[&[u8]]) -> bool {
        params
            .iter()
            .skip(2)
            .filter_map(|opt| opt.strip_prefix(b"k=".as_slice()))
            .any(|kind| kind != b"i")
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
    /// Used twice per resize and nowhere else: once over the rows the rewrap pushed off
    /// the top, whose absolute numbers start where the eviction counter stood before they
    /// were archived, and once over the grid that came out of it.
    pub(super) fn marks_in<'a>(
        rows: impl Iterator<Item = &'a Row>,
        base: usize,
    ) -> impl Iterator<Item = (MarkId, Anchor)> {
        rows.enumerate().flat_map(move |(index, row)| {
            row.marks()
                .map(move |(col, id)| {
                    (
                        id,
                        Anchor {
                            row: base + index,
                            col,
                        },
                    )
                })
                .collect::<Vec<_>>()
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
