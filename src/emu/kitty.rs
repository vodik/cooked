//! The kitty graphics protocol, as far as cooked speaks it.
//!
//! A command is `ESC _ G <control data> ; <payload> ESC \`, where the control data is
//! comma-separated `key=value` pairs and the payload is base64. The vendored parser in
//! [`super::parser`] exists to deliver these: upstream vte discards APC outright, which
//! is why this could not be reached at all before.
//!
//! What is implemented, and what is refused, is decided by one rule: a capability is
//! either honoured or *declined out loud*. The protocol has an error response for
//! exactly this, and a client that is told `ENOTSUPPORTED` can fall back, while a client
//! whose transmission is silently dropped shows the user nothing and cannot know why.
//!
//! Declined for now, each with that response: `t=f`/`t=t`/`t=s` (transmission by file,
//! temporary file or shared memory — reading paths a child names is a decision about
//! trust, not a decode), and the animation and unicode-placeholder extensions.

use std::collections::HashMap;

use super::image::{CellSize, ImageFormat, ImageId, PixelFormat, PixelSize, Pixels};

/// Largest payload reassembled from a chunked transmission.
///
/// Chunks are capped at 4096 bytes by the protocol, so this is a bound on how many of
/// them one image may take rather than on any single APC.
pub(crate) const MAX_PAYLOAD: usize = 32 << 20;

/// What the child asked for. `a=` in the control data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum Action {
    /// `a=t` — transmit, do not display. The protocol's default when `a=` is absent.
    #[default]
    Transmit,
    /// `a=T` — transmit and display at the cursor.
    Display,
    /// `a=p` — display something already transmitted, by its id.
    Put,
    /// `a=d` — the child is finished with an image.
    Delete,
    /// `a=q` — a capability probe, which must not store anything.
    Query,
}

/// How the payload's bytes are meant. `f=` in the control data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub(crate) enum Payload {
    /// `f=24`
    Rgb,
    /// `f=32`, the protocol's default.
    #[default]
    Rgba,
    /// `f=100`
    Png,
}

impl Payload {
    /// The pixel layout this payload is, or `None` if it is a file rather than pixels.
    fn pixels(self) -> Option<PixelFormat> {
        match self {
            Self::Rgb => Some(PixelFormat::Rgb),
            Self::Rgba => Some(PixelFormat::Rgba),
            Self::Png => None,
        }
    }
}

/// One parsed command, before its payload has been reassembled.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub(crate) struct Command {
    pub action: Action,
    pub format: Payload,
    pub more: bool,
    /// `o=z` — the payload is zlib-deflated under its base64.
    pub compressed: bool,
    pub id: u32,
    pub px: PixelSize,
    pub cells: CellSize,
    /// `q=1` suppresses success, `q=2` suppresses everything.
    pub quiet: u8,
    /// `C=1` — display the picture without moving the cursor. Spelled as the exception
    /// rather than as "should the cursor move", so the derived default is the protocol's
    /// default: absent `C=` moves it.
    pub freeze_cursor: bool,
    /// A capability named in the control data that this terminal does not implement.
    pub unsupported: Option<&'static str>,
    /// The action the control data *named*, as distinct from the one that applies.
    /// `None` when `a=` was absent, which is what a continuation chunk looks like: the
    /// protocol says a chunk after the first carries only `m` and perhaps `q`.
    ///
    /// Kept apart from `action` because that one has already had the protocol's default
    /// applied, so it cannot answer "did the child say so, or did we assume it?" — and
    /// that is the whole question [`Kitty::feed`] has to settle before deciding whether
    /// a payload continues a transfer or starts something else.
    pub explicit_action: Option<Action>,
    /// The id the control data named, `None` when `i=` was absent. Same distinction as
    /// `explicit_action` and for the same reason: on a chunk, an absent `i=` means "the
    /// transfer already in flight", while a *different* one means a different picture.
    pub explicit_id: Option<u32>,
}

impl Command {
    /// Parse the control data — everything before the `;` — of a `G` command.
    ///
    /// Unknown keys are ignored rather than refused, which is what the protocol asks
    /// for: it is extended by adding keys, and a terminal that failed on the first one
    /// it had not heard of would break on every new client. Keys naming a *capability*
    /// are different, and land in `unsupported`.
    pub(crate) fn parse(control: &str) -> Self {
        let mut cmd = Self::default();
        for pair in control.split(',') {
            let Some((key, value)) = pair.split_once('=') else {
                continue;
            };
            let num = || value.parse::<u32>().unwrap_or(0);
            match key {
                "a" => {
                    cmd.action = match value {
                        "t" => Action::Transmit,
                        "T" => Action::Display,
                        "p" => Action::Put,
                        "d" => Action::Delete,
                        "q" => Action::Query,
                        // An action we do not know is not a licence to guess at
                        // drawing something; fall back to the protocol's default.
                        _ => Action::Transmit,
                    };
                    // Recorded even for the unrecognised case above: the child *named* an
                    // action, and that it named one is the fact `feed` needs, separately
                    // from which one we resolved it to.
                    cmd.explicit_action = Some(cmd.action);
                }
                "f" => {
                    cmd.format = match value {
                        "24" => Payload::Rgb,
                        "100" => Payload::Png,
                        _ => Payload::Rgba,
                    }
                }
                "t" if value != "d" => cmd.unsupported = Some("ENOTSUPPORTED:medium"),
                // `z` is the only compression the protocol defines. Another letter is a
                // scheme from a newer spec, and guessing at it would render noise.
                "o" => match value {
                    "z" => cmd.compressed = true,
                    _ => cmd.unsupported = Some("ENOTSUPPORTED:compression"),
                },
                "U" => cmd.unsupported = Some("ENOTSUPPORTED:placeholder"),
                "m" => cmd.more = num() != 0,
                "i" => {
                    cmd.id = num();
                    cmd.explicit_id = Some(cmd.id);
                }
                "s" => cmd.px.w = num(),
                "v" => cmd.px.h = num(),
                // The protocol puts no upper bound on these, so each pins rather than
                // wrapping. Spelled out: a helper generic enough to cover both widths
                // needed a bespoke trait, which cost more to read than the three lines.
                "c" => cmd.cells.cols = u16::try_from(num()).unwrap_or(u16::MAX),
                "r" => cmd.cells.rows = u16::try_from(num()).unwrap_or(u16::MAX),
                "q" => cmd.quiet = u8::try_from(num()).unwrap_or(u8::MAX),
                // Only `C=1` freezes it. The protocol defines no other value, and
                // reading "anything but zero" would make a future one mean this.
                "C" => cmd.freeze_cursor = value == "1",
                _ => {}
            }
        }
        cmd
    }
}

/// What the terminal should do once a command's payload is complete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub(crate) enum Outcome {
    /// Nothing yet — more chunks are coming.
    Incomplete,
    /// Hand these bytes to the image store; display them if `display`.
    Image {
        format: ImageFormat,
        bytes: Vec<u8>,
        px: PixelSize,
        cells: CellSize,
        client_id: u32,
        display: bool,
        freeze_cursor: bool,
    },
    /// Place an image already transmitted under this id.
    Place { id: ImageId, freeze_cursor: bool },
    /// Nothing to do, but the child may be owed an answer.
    Nothing,
}

/// Per-session protocol state: partly-received transmissions and the client's id space.
#[derive(Debug, Default)]
pub(crate) struct Kitty {
    /// The transmission being reassembled, if a chunked one is in flight.
    ///
    /// One at a time, which is what the protocol allows: a client must finish a chunked
    /// transmission before starting another. A client that starts a second one anyway is
    /// caught by [`Command::explicit_id`] and told so, rather than having its two
    /// pictures spliced into one.
    ///
    /// Bounded by [`MAX_PAYLOAD`] but not by time: a client that begins a chunked
    /// transfer and then goes permanently silent holds this buffer until the session
    /// ends or another transmission displaces it. Reclaiming it sooner would need a
    /// deadline swept from somewhere that runs while the child is quiet — the reader
    /// thread's poll tick — since nothing here is called at all in the meantime.
    pending: Option<(Command, Vec<u8>)>,
    /// The child's own image ids, which are not ours — ours are content-addressed, so
    /// two clients reusing the same number cannot collide, and one client reusing a
    /// number for a different picture cannot alias.
    by_client: HashMap<u32, ImageId>,
}

impl Kitty {
    /// Note that CLIENT_ID now means the image we interned as OURS.
    pub(crate) fn bind(&mut self, client_id: u32, ours: ImageId) {
        if client_id != 0 {
            self.by_client.insert(client_id, ours);
        }
    }

    /// Every picture the child can still name, and so still ask to be placed.
    ///
    /// A transmission's bytes may be shed the moment nothing on the grid shows them --
    /// see `State::shed_unplaced_images` -- and a picture bound to an `i=` is the
    /// exception: `a=p` names one by id alone, with no bytes of its own, so the
    /// transmission that bound it is the only chance those bytes have to reach Emacs.
    pub(crate) fn bound_images(&self) -> impl Iterator<Item = ImageId> + '_ {
        self.by_client.values().copied()
    }

    /// Retire every client name for OURS, the picture having gone.
    ///
    /// Called when the store drops an image -- Emacs discarded its bytes, or the count
    /// cap retired it. A client that places it afterwards is told `ENOENT:image`, which
    /// is the true answer and the one it can act on by transmitting the picture again;
    /// keeping the name would instead leave `a=p` naming geometry nothing has.
    ///
    /// A scan of the map rather than a reverse index: it holds one entry per id the
    /// child has named, several clients can point at one picture (ids are
    /// content-addressed here and not there), and this runs when an image is forgotten
    /// rather than per transmission.
    pub(crate) fn forget(&mut self, ours: ImageId) {
        self.by_client.retain(|_, &mut id| id != ours);
    }

    /// Take one APC payload, returning what the terminal should do about it.
    ///
    /// PAYLOAD is the whole APC body, `G` and all — the introducer is checked here
    /// rather than by the caller, because APC is a general escape and something else
    /// may one day be carried in it. Anything not addressed to `G` is not ours.
    pub(crate) fn feed(&mut self, payload: &[u8]) -> (Outcome, Option<Vec<u8>>) {
        let Some(payload) = payload.strip_prefix(b"G") else {
            return (Outcome::Nothing, None);
        };
        let (control, body) = match payload.iter().position(|&b| b == b';') {
            Some(at) => (&payload[..at], &payload[at + 1..]),
            None => (payload, &[][..]),
        };
        let control = String::from_utf8_lossy(control);
        let cmd = Command::parse(&control);

        // Settled before anything is appended, because a transfer in flight otherwise
        // swallows whatever arrives next as though it were more of the picture.
        if self.pending.is_some() {
            // A probe, a delete and a place carry no payload and are never a chunk, so
            // they are answered where they stand and the transfer is left alone. Eating
            // one corrupts the image *and* misanswers the probe -- and `a=q` in
            // particular is defined to leave no trace, which being spliced into somebody
            // else's picture is not.
            if matches!(
                cmd.explicit_action,
                Some(Action::Query | Action::Delete | Action::Put)
            ) {
                return self.standalone(cmd);
            }
            // An explicit `i=` naming a *different* picture is a second transmission
            // rather than a chunk of this one. Told out loud, as the module's rule is,
            // and addressed to the transfer being abandoned rather than to the one
            // displacing it -- the client is owed an answer about the picture it will
            // now never get. A repeated or absent `i=' continues as before, so a sender
            // that restates its full control data on every chunk is unaffected; two
            // transfers sharing one id are indistinguishable from a continuation by any
            // means, and nothing here pretends otherwise.
            if let Some((stale, _)) = self
                .pending
                .take_if(|(pending, _)| cmd.explicit_id.is_some_and(|id| id != pending.id))
            {
                let refusal = response(&stale, Some("EINVAL:interleaved"));
                let (outcome, reply) = self.begin(cmd, body);
                // Both answers go back, in the order the two commands happened. Each is a
                // complete APC, so a client reading them apart is reading them the same
                // way it would have had they arrived in separate writes.
                return (outcome, join(refusal, reply));
            }
        }

        // A continuation carries only `m=` and perhaps `q=`; the command it continues is
        // the one already in flight, whose format and geometry still apply. Only `m=` is
        // read off the chunk itself -- everything else about the picture was settled by
        // the command that opened the transfer.
        if let Some((opened, mut buf)) = self.pending.take() {
            if !append(&mut buf, body) {
                return (Outcome::Nothing, response(&opened, Some("EBIG:payload")));
            }
            if cmd.more {
                self.pending = Some((opened, buf));
                return (Outcome::Incomplete, None);
            }
            return self.finish(opened, buf);
        }

        self.begin(cmd, body)
    }

    /// Answer a command that carries no payload, or `Nothing` if it is not one.
    ///
    /// Split out because these three are reachable from two places -- an ordinary
    /// command, and one arriving while a chunked transfer is in flight -- and the second
    /// path exists precisely so that they behave identically either way.
    fn standalone(&mut self, cmd: Command) -> (Outcome, Option<Vec<u8>>) {
        if let Some(why) = cmd.unsupported {
            return (Outcome::Nothing, response(&cmd, Some(why)));
        }
        match cmd.action {
            // A probe must leave no trace: answering is the whole of it.
            Action::Query => (Outcome::Nothing, response(&cmd, None)),
            Action::Delete => {
                // The bytes are not ours to free — Emacs holds them for as long as the
                // buffer text showing them lives — so this only retires the child's name
                // for the picture. See the module comment in `image.rs`.
                self.by_client.remove(&cmd.id);
                (Outcome::Nothing, response(&cmd, None))
            }
            Action::Put => match self.by_client.get(&cmd.id).copied() {
                Some(id) => (
                    Outcome::Place {
                        id,
                        freeze_cursor: cmd.freeze_cursor,
                    },
                    response(&cmd, None),
                ),
                // Never transmitted, or transmitted and since forgotten -- see
                // `Kitty::forget`. The two are one answer on purpose: what the client
                // can do about either is send the picture again.
                None => (Outcome::Nothing, response(&cmd, Some("ENOENT:image"))),
            },
            Action::Transmit | Action::Display => (Outcome::Nothing, None),
        }
    }

    /// Start a command that was not a continuation of anything.
    fn begin(&mut self, cmd: Command, body: &[u8]) -> (Outcome, Option<Vec<u8>>) {
        if let Some(why) = cmd.unsupported {
            return (Outcome::Nothing, response(&cmd, Some(why)));
        }
        if !matches!(cmd.action, Action::Transmit | Action::Display) {
            return self.standalone(cmd);
        }

        let mut buf = Vec::new();
        if !append(&mut buf, body) {
            return (Outcome::Nothing, response(&cmd, Some("EBIG:payload")));
        }
        if cmd.more {
            self.pending = Some((cmd, buf));
            return (Outcome::Incomplete, None);
        }
        self.finish(cmd, buf)
    }

    fn finish(&mut self, cmd: Command, base64: Vec<u8>) -> (Outcome, Option<Vec<u8>>) {
        let Some(raw) = decode_base64(&base64) else {
            return (Outcome::Nothing, response(&cmd, Some("EINVAL:base64")));
        };
        // `o=z` wraps the payload *under* its base64, so this is the order it unwinds in.
        // The limit is the same one that bounds an uncompressed transmission: what a
        // child may spend of our heap should not depend on how it chose to encode it.
        let raw = if cmd.compressed {
            match miniz_oxide::inflate::decompress_to_vec_zlib_with_limit(&raw, MAX_PAYLOAD) {
                Ok(raw) => raw,
                Err(_) => {
                    return (Outcome::Nothing, response(&cmd, Some("EINVAL:compression")));
                }
            }
        } else {
            raw
        };
        // Raw pixels carry no dimensions of their own, so a transmission that omits them
        // cannot be laid out at all, and one whose geometry runs far past what arrived is
        // not describing the bytes it sent. Both are checked *before* converting, because
        // the conversion sizes its buffer from the geometry: `s=65535,v=65535` with a
        // four-byte payload is a 13GB allocation asked for by anything that can write to
        // the terminal, which `cat` of a hostile file is. Bounding it against the payload
        // needs no arbitrary maximum — `MAX_PAYLOAD` already bounds that.
        //
        // What the check bounds is the *amplification* from payload to allocation, and it
        // used to be spelled as exact equality, which bounds it far more tightly than it
        // has to and refuses a picture that merely arrived short. That is not a
        // theoretical distinction: a Ctrl-C during an animation cuts the child's blocked
        // `write` part-way through, so the frame in flight lands a few kilobytes short of
        // the four megabytes it declared — and a frame refused places nothing, which
        // leaves the cursor at the picture's top-left, where the client parks it between
        // frames, for the shell's `ED` to erase the picture from. Both encoders below
        // already pad a short buffer rather than lie about its length, so the honest
        // answer is the one a terminal drawing that frame character by character would
        // have given: as much of the picture as actually arrived. A factor of two is the
        // loosest bound that is still a bound.
        //
        // A PNG is a file and carries its own size; only the raw layouts have geometry to
        // check. `Payload::pixels()` is `None` for exactly that case, which is what the
        // old `bytes_per_pixel = 0` sentinel was standing in for.
        let (format, bytes) = match cmd.format.pixels() {
            None => (ImageFormat::Png, raw),
            Some(layout) => {
                let pixels = Pixels::new(cmd.px, layout, raw);
                // `s=`/`v=` arrive as plain `u32` with no upper clamp (unlike `c=`/`r=`),
                // so this product is the one place a hostile pair of dimensions can
                // reach. It is computed in `u64` (see [`PixelSize::area`]), because
                // wrapping would let a crafted `s=`/`v=` near the `u32` extremes fold
                // back down to a small length that a tiny payload satisfies, while
                // `cmd.px` itself survived unclamped into the encoder.
                let needed = pixels.expected_len();
                if needed == 0 || needed > 2 * pixels.data.len() as u64 {
                    return (Outcome::Nothing, response(&cmd, Some("EINVAL:dimensions")));
                }
                pixels.encode()
            }
        };
        (
            Outcome::Image {
                format,
                bytes,
                px: cmd.px,
                cells: cmd.cells,
                client_id: cmd.id,
                display: cmd.action == Action::Display,
                freeze_cursor: cmd.freeze_cursor,
            },
            response(&cmd, None),
        )
    }
}

fn append(buf: &mut Vec<u8>, body: &[u8]) -> bool {
    if buf.len() + body.len() > MAX_PAYLOAD {
        return false;
    }
    buf.extend_from_slice(body);
    true
}

/// Two answers as one, for the one command that produces both.
///
/// Concatenated rather than picking a winner: an interleaved transmission owes the child
/// a refusal for the picture it abandoned *and* an answer for the one that displaced it,
/// and `q=` may already have silenced either.
fn join(first: Option<Vec<u8>>, second: Option<Vec<u8>>) -> Option<Vec<u8>> {
    match (first, second) {
        (Some(mut a), Some(b)) => {
            a.extend_from_slice(&b);
            Some(a)
        }
        (a, b) => a.or(b),
    }
}

/// The answer owed to the child, honouring `q=`.
///
/// `q=1` suppresses success and leaves errors, `q=2` suppresses both. A command with no
/// id gets no response either: the protocol keys the answer to `i=`, and one without it
/// is unaddressable.
fn response(cmd: &Command, error: Option<&str>) -> Option<Vec<u8>> {
    match (cmd.quiet, error) {
        (q, _) if q >= 2 => return None,
        (1, None) => return None,
        _ => {}
    }
    if cmd.id == 0 {
        return None;
    }
    let body = error.unwrap_or("OK");
    Some(format!("\x1b_Gi={};{}\x1b\\", cmd.id, body).into_bytes())
}

/// Standard base64, rejecting anything that is not — but lifting out what the *terminal*
/// injected rather than the child.
///
/// Whitespace is skipped because a payload split across chunks can pick up a newline
/// from a shell that echoed it, and dropping the picture over that would be a worse
/// answer than ignoring it.
///
/// A caret is skipped along with the byte after it, for a sharper version of the same
/// problem. `ECHOCTL` spells a control character as `^` plus one letter, and the line
/// discipline writes that echo into the pty's output the moment the key is pressed —
/// which, for a child blocked part-way through a multi-megabyte `write`, is *between two
/// pieces of that write*, and so inside the payload. Interrupting an animation is exactly
/// that case: `viu` streams a four-megabyte frame, `^C` lands a few kilobytes into one of
/// its 4096-byte chunks, and two bytes nobody transmitted would otherwise cost the whole
/// frame. `^` is not in the base64 alphabet, so it identifies the echo unambiguously, and
/// its partner byte — which usually *is* in the alphabet — goes with it, which is what
/// makes this a repair rather than a resynchronisation: the payload decodes byte for byte
/// as it was sent, with no shift.
///
/// Losing the frame is not a cosmetic matter, and this is the bug it was found through:
/// a transmission that is refused places nothing, so the cursor stays at the picture's
/// top-left, where the client left it between frames. The newline the client prints after
/// each frame then moves one row *into* the picture, and the shell's own `ED` on the way
/// to a new prompt erases everything below it. One row of the picture survives, and the
/// prompt sits in the hole.
///
/// Shared with the `OSC 1337` path in [`super::term`], which carries its image the same
/// way. It lives here because this is where it was first needed, and a second copy would
/// be a second set of edge cases.
pub(super) fn decode_base64(input: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len() / 4 * 3);
    let (mut acc, mut bits) = (0u32, 0u32);
    let mut at = 0;
    while at < input.len() {
        let byte = input[at];
        at += 1;
        let value = match byte {
            b'A'..=b'Z' => u32::from(byte - b'A'),
            b'a'..=b'z' => u32::from(byte - b'a') + 26,
            b'0'..=b'9' => u32::from(byte - b'0') + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => continue,
            b' ' | b'\t' | b'\r' | b'\n' => continue,
            // Both bytes of the echo, or only the caret when it landed on the very end
            // of a chunk and its partner is somebody else's problem.
            b'^' => {
                at += 1;
                continue;
            }
            _ => return None,
        };
        acc = (acc << 6) | value;
        bits += 6;
        if bits >= 8 {
            bits -= 8;
            out.push((acc >> bits) as u8);
        }
    }
    Some(out)
}

/// Standard base64, for tests that have to hand the parser a payload.
///
/// The inverse of [`decode_base64`] and beside it on purpose: both the kitty tests here
/// and the end-to-end ones in [`super::term`] need to encode a picture, and the two had
/// grown a byte-identical copy each.
#[cfg(test)]
pub(super) fn encode_base64(bytes: &[u8]) -> String {
    const SET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::new();
    for chunk in bytes.chunks(3) {
        let mut n = 0u32;
        for (i, b) in chunk.iter().enumerate() {
            n |= u32::from(*b) << (16 - 8 * i);
        }
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(SET[((n >> (18 - 6 * i)) & 63) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::encode_base64 as b64;
    use super::*;

    #[test]
    fn the_default_action_is_transmit_not_display() {
        // The protocol's default for a missing `a=` is `t`, and the difference shows:
        // defaulting to display would draw a picture the child only meant to store.
        assert_eq!(Command::parse("f=100,i=1").action, Action::Transmit);
    }

    #[test]
    fn an_apc_not_addressed_to_g_is_not_ours() {
        let mut k = Kitty::default();
        assert_eq!(k.feed(b"Zsomething-else").0, Outcome::Nothing);
        assert!(k.feed(b"Zsomething-else").1.is_none());
    }

    #[test]
    fn control_data_parses_into_a_command() {
        let cmd = Command::parse("a=T,f=100,s=64,v=32,i=7,c=8,r=4,q=1");
        assert_eq!(cmd.action, Action::Display);
        assert_eq!(cmd.format, Payload::Png);
        assert_eq!(cmd.px, PixelSize::new(64, 32));
        assert_eq!(cmd.cells, CellSize::new(8, 4));
        assert_eq!(cmd.id, 7);
        assert_eq!(cmd.quiet, 1);
        assert_eq!(cmd.unsupported, None);
    }

    #[test]
    fn an_unknown_key_is_ignored_but_an_unknown_capability_is_not() {
        // The protocol is extended by adding keys, so refusing the first unfamiliar one
        // would break on every newer client.
        assert_eq!(Command::parse("a=T,zz=9").unsupported, None);
        // A capability is different: silently ignoring it renders nothing and tells the
        // client nothing, so it is declined out loud.
        assert!(Command::parse("a=T,t=f").unsupported.is_some());
        // ...but a compression we *do* speak is not a refusal.
        assert_eq!(Command::parse("a=T,o=z").unsupported, None);
        assert!(Command::parse("a=T,o=z").compressed);
        // Another letter would be a scheme from a spec we have not read.
        assert!(Command::parse("a=T,o=q").unsupported.is_some());
    }

    /// `zlib.compress(b"PNGDATA" * 20, 9)` — 140 bytes into 18, a fixed-Huffman block.
    const DEFLATED: &[u8] = &[
        120, 218, 11, 240, 115, 119, 113, 12, 113, 12, 24, 12, 20, 0, 2, 187, 39, 237,
    ];

    #[test]
    fn a_compressed_transmission_is_inflated() {
        // What `icat` sends: kitty's own client compresses by default, so declining this
        // declined the reference implementation.
        let mut k = Kitty::default();
        let (outcome, reply) = k.feed(format!("Ga=T,f=100,o=z,i=3;{}", b64(DEFLATED)).as_bytes());
        match outcome {
            Outcome::Image { bytes, .. } => assert_eq!(bytes, b"PNGDATA".repeat(20)),
            other => panic!("{other:?}"),
        }
        assert_eq!(reply.unwrap(), b"\x1b_Gi=3;OK\x1b\\");
    }

    #[test]
    fn compression_unwinds_underneath_the_base64_not_over_it() {
        // The order matters and only one of the two produces a picture: `o=z` describes
        // the bytes the base64 *carries*, not the base64 itself.
        let mut k = Kitty::default();
        let (outcome, _) =
            k.feed(format!("Ga=T,f=24,s=2,v=1,o=z,i=1;{}", b64(DEFLATED)).as_bytes());
        match outcome {
            // Six bytes of RGB from the inflated 140, not from the 18 compressed ones.
            Outcome::Image { bytes, .. } => assert_eq!(&bytes[11..17], b"PNGDAT"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_payload_that_is_not_deflate_is_refused_rather_than_rendered() {
        let mut k = Kitty::default();
        let (outcome, reply) =
            k.feed(format!("Ga=T,f=100,o=z,i=8;{}", b64(b"not zlib")).as_bytes());
        assert_eq!(outcome, Outcome::Nothing);
        assert_eq!(reply.unwrap(), b"\x1b_Gi=8;EINVAL:compression\x1b\\");
    }

    #[test]
    fn a_corrupt_compressed_payload_does_not_become_half_a_picture() {
        // Truncation is the failure a chunked transmission actually suffers, and the
        // checksum is what distinguishes it from a complete one.
        let mut k = Kitty::default();
        let short = &DEFLATED[..DEFLATED.len() - 3];
        let (outcome, _) = k.feed(format!("Ga=T,f=100,o=z,i=9;{}", b64(short)).as_bytes());
        assert_eq!(outcome, Outcome::Nothing);
    }

    #[test]
    fn a_compressed_transmission_may_still_be_chunked() {
        // The two features compose: chunks reassemble into base64, which decodes into a
        // deflate stream. Nothing inflates until the last chunk has landed.
        let mut k = Kitty::default();
        let whole = b64(DEFLATED);
        let (first, rest) = whole.split_at(12);
        assert_eq!(
            k.feed(format!("Ga=T,f=100,o=z,i=2,m=1;{first}").as_bytes())
                .0,
            Outcome::Incomplete
        );
        match k.feed(format!("Gm=0;{rest}").as_bytes()).0 {
            Outcome::Image { bytes, .. } => assert_eq!(bytes, b"PNGDATA".repeat(20)),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_png_transmission_becomes_an_image() {
        let mut k = Kitty::default();
        let (outcome, reply) = k.feed(format!("Ga=T,f=100,i=3;{}", b64(b"PNGDATA")).as_bytes());
        assert_eq!(
            outcome,
            Outcome::Image {
                format: ImageFormat::Png,
                bytes: b"PNGDATA".to_vec(),
                px: PixelSize::new(0, 0),
                cells: CellSize::new(0, 0),
                client_id: 3,
                display: true,
                freeze_cursor: false,
            }
        );
        assert_eq!(reply.unwrap(), b"\x1b_Gi=3;OK\x1b\\");
    }

    #[test]
    fn a_chunked_transmission_is_reassembled() {
        let mut k = Kitty::default();
        let whole = b64(b"PNGDATAPNGDATA");
        let (first, rest) = whole.split_at(8);
        assert_eq!(
            k.feed(format!("Ga=T,f=100,i=1,m=1;{first}").as_bytes()).0,
            Outcome::Incomplete
        );
        let (outcome, _) = k.feed(format!("Gm=0;{rest}").as_bytes());
        match outcome {
            Outcome::Image { bytes, .. } => assert_eq!(bytes, b"PNGDATAPNGDATA"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_probe_arriving_mid_transfer_is_answered_without_eating_the_chunk() {
        // A capability probe is defined to leave no trace, and a transfer in flight used
        // to swallow one as though it were more of the picture -- which both corrupted
        // the image and answered the probe as the wrong command.
        let mut k = Kitty::default();
        let whole = b64(b"PNGDATAPNGDATA");
        let (first, rest) = whole.split_at(8);
        assert_eq!(
            k.feed(format!("Ga=T,f=100,i=1,m=1;{first}").as_bytes()).0,
            Outcome::Incomplete
        );

        let (outcome, reply) = k.feed(b"Ga=q,i=99;");
        assert_eq!(outcome, Outcome::Nothing);
        assert_eq!(reply.unwrap(), b"\x1b_Gi=99;OK\x1b\\");

        // ...and the picture is still exactly the one that was being sent.
        let (outcome, _) = k.feed(format!("Gm=0;{rest}").as_bytes());
        match outcome {
            Outcome::Image { bytes, .. } => assert_eq!(bytes, b"PNGDATAPNGDATA"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn a_second_picture_abandons_the_first_rather_than_splicing_into_it() {
        let mut k = Kitty::default();
        assert_eq!(
            k.feed(format!("Ga=T,f=100,i=1,m=1;{}", b64(b"FIRST")).as_bytes())
                .0,
            Outcome::Incomplete
        );

        // A different `i=` is a different picture, so the transfer in flight is dropped
        // -- and the client is told about the one it will now never get, addressed to
        // *that* id, alongside the answer for the one that displaced it.
        let (outcome, reply) = k.feed(format!("Ga=T,f=100,i=2;{}", b64(b"SECOND")).as_bytes());
        match outcome {
            Outcome::Image { bytes, .. } => assert_eq!(bytes, b"SECOND"),
            other => panic!("{other:?}"),
        }
        assert_eq!(
            reply.unwrap(),
            b"\x1b_Gi=1;EINVAL:interleaved\x1b\\\x1b_Gi=2;OK\x1b\\"
        );
    }

    #[test]
    fn a_chunk_restating_its_own_control_data_still_continues_the_transfer() {
        // The interleave check keys on an id that *differs*, precisely so that a sender
        // repeating its full control data on every chunk -- which the protocol permits
        // and some clients do -- is not mistaken for a second picture.
        let mut k = Kitty::default();
        let whole = b64(b"PNGDATAPNGDATA");
        let (first, rest) = whole.split_at(8);
        assert_eq!(
            k.feed(format!("Ga=T,f=100,i=4,m=1;{first}").as_bytes()).0,
            Outcome::Incomplete
        );
        let (outcome, _) = k.feed(format!("Ga=T,f=100,i=4,m=0;{rest}").as_bytes());
        match outcome {
            Outcome::Image { bytes, .. } => assert_eq!(bytes, b"PNGDATAPNGDATA"),
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn rgb_becomes_a_ppm_and_rgba_a_png() {
        let mut k = Kitty::default();
        let (outcome, _) = k.feed(format!("Ga=T,f=24,s=1,v=1,i=1;{}", b64(&[1, 2, 3])).as_bytes());
        match outcome {
            Outcome::Image { format, bytes, .. } => {
                assert_eq!(format, ImageFormat::Ppm);
                assert!(bytes.starts_with(b"P6\n1 1\n255\n"));
            }
            other => panic!("{other:?}"),
        }

        let (outcome, _) =
            k.feed(format!("Ga=T,f=32,s=1,v=1,i=2;{}", b64(&[1, 2, 3, 255])).as_bytes());
        match outcome {
            Outcome::Image { format, bytes, .. } => {
                assert_eq!(format, ImageFormat::Png);
                assert!(bytes.starts_with(b"\x89PNG"));
            }
            other => panic!("{other:?}"),
        }
    }

    #[test]
    fn raw_pixels_without_dimensions_are_refused_rather_than_guessed() {
        let mut k = Kitty::default();
        let (outcome, reply) = k.feed(format!("Ga=T,f=32,i=4;{}", b64(&[0; 4])).as_bytes());
        assert_eq!(outcome, Outcome::Nothing);
        assert_eq!(reply.unwrap(), b"\x1b_Gi=4;EINVAL:dimensions\x1b\\");
    }

    #[test]
    fn geometry_that_outruns_the_payload_is_refused_before_it_is_allocated() {
        // Four bytes claiming to be a 65535x65535 picture. Sizing the conversion buffer
        // from the geometry would ask for 13GB on behalf of anything that can write to
        // the terminal; the transmission has to account for the pixels it declares.
        let mut k = Kitty::default();
        for format in ["f=24", "f=32"] {
            let apc = format!("Ga=T,{format},s=65535,v=65535,i=4;{}", b64(&[0; 4]));
            let (outcome, reply) = k.feed(apc.as_bytes());
            assert_eq!(outcome, Outcome::Nothing, "{format}");
            assert_eq!(reply.unwrap(), b"\x1b_Gi=4;EINVAL:dimensions\x1b\\");
        }
        // Short by less than half is drawn as far as it got: a frame cut off by the
        // signal that stopped the child is a partial picture, not a malformed one.
        let apc = format!("Ga=T,f=32,s=2,v=1,i=4;{}", b64(&[0; 7]));
        assert!(matches!(k.feed(apc.as_bytes()).0, Outcome::Image { .. }));
        // Half of one pixel is not most of a two-pixel picture.
        let apc = format!("Ga=T,f=32,s=2,v=1,i=4;{}", b64(&[0; 3]));
        assert_eq!(k.feed(apc.as_bytes()).0, Outcome::Nothing);
        // Exactly enough is enough, and trailing slack is the client's business.
        let apc = format!("Ga=T,f=32,s=2,v=1,i=4;{}", b64(&[0; 8]));
        assert!(matches!(k.feed(apc.as_bytes()).0, Outcome::Image { .. }));
        let apc = format!("Ga=T,f=32,s=2,v=1,i=5;{}", b64(&[0; 12]));
        assert!(matches!(k.feed(apc.as_bytes()).0, Outcome::Image { .. }));
    }

    #[test]
    fn a_compressed_transmission_cannot_outrun_its_geometry_either() {
        // The cheapest way to ask for a large allocation is a small compressed payload,
        // so the check has to sit after the inflate rather than before it.
        let mut k = Kitty::default();
        let apc = format!("Ga=T,f=32,o=z,s=65535,v=65535,i=7;{}", b64(DEFLATED));
        let (outcome, reply) = k.feed(apc.as_bytes());
        assert_eq!(outcome, Outcome::Nothing);
        assert_eq!(reply.unwrap(), b"\x1b_Gi=7;EINVAL:dimensions\x1b\\");
    }

    #[test]
    fn placing_an_unknown_id_says_so() {
        let mut k = Kitty::default();
        let (outcome, reply) = k.feed(b"Ga=p,i=9");
        assert_eq!(outcome, Outcome::Nothing);
        assert_eq!(reply.unwrap(), b"\x1b_Gi=9;ENOENT:image\x1b\\");
    }

    #[test]
    fn placing_a_bound_id_finds_it_again() {
        let mut k = Kitty::default();
        k.bind(9, ImageId(42));
        assert_eq!(
            k.feed(b"Ga=p,i=9").0,
            Outcome::Place {
                id: ImageId(42),
                freeze_cursor: false,
            }
        );
    }

    #[test]
    fn c_says_whether_the_cursor_moves() {
        assert!(!Command::parse("a=T,i=1").freeze_cursor);
        assert!(Command::parse("a=T,i=1,C=1").freeze_cursor);
        assert!(!Command::parse("a=T,i=1,C=0").freeze_cursor);
    }

    #[test]
    fn a_query_leaves_no_trace_but_is_answered() {
        let mut k = Kitty::default();
        let (outcome, reply) = k.feed(b"Ga=q,i=5,s=1,v=1");
        assert_eq!(outcome, Outcome::Nothing);
        assert_eq!(reply.unwrap(), b"\x1b_Gi=5;OK\x1b\\");
        // ...and it did not become a placeable image.
        assert_eq!(k.feed(b"Ga=p,i=5").0, Outcome::Nothing);
    }

    #[test]
    fn quiet_levels_suppress_the_right_answers() {
        let mut k = Kitty::default();
        // q=1 keeps errors and drops successes.
        assert!(k.feed(b"Ga=q,i=1,q=1").1.is_none());
        assert!(k.feed(b"Ga=p,i=1,q=1").1.is_some());
        // q=2 drops both.
        assert!(k.feed(b"Ga=p,i=1,q=2").1.is_none());
    }

    #[test]
    fn a_command_without_an_id_is_unaddressable_and_gets_no_reply() {
        let mut k = Kitty::default();
        assert!(k.feed(b"Ga=q").1.is_none());
    }

    #[test]
    fn a_malformed_payload_is_refused_rather_than_rendered() {
        let mut k = Kitty::default();
        let (outcome, reply) = k.feed(b"Ga=T,f=100,i=6;not*base64");
        assert_eq!(outcome, Outcome::Nothing);
        assert_eq!(reply.unwrap(), b"\x1b_Gi=6;EINVAL:base64\x1b\\");
    }

    #[test]
    fn base64_round_trips_and_tolerates_wrapping() {
        let data: Vec<u8> = (0u8..=255).collect();
        let encoded = b64(&data);
        assert_eq!(decode_base64(encoded.as_bytes()).unwrap(), data);
        let wrapped = encoded
            .as_bytes()
            .chunks(20)
            .map(|c| String::from_utf8_lossy(c).into_owned())
            .collect::<Vec<_>>()
            .join("\n");
        assert_eq!(decode_base64(wrapped.as_bytes()).unwrap(), data);
    }

    #[test]
    fn an_echoed_control_character_is_lifted_back_out_of_a_payload() {
        let data: Vec<u8> = (0u8..=255).collect();
        let encoded = b64(&data);
        // `ECHOCTL`'s spelling of Ctrl-C, spliced in where the line discipline put it:
        // part-way through, between two pieces of the child's blocked write. Both bytes
        // go, so what is left decodes to the original rather than to the original
        // shifted six bits from here down.
        let (head, tail) = encoded.split_at(101);
        let echoed = format!("{head}^C{tail}");
        assert_eq!(decode_base64(echoed.as_bytes()).unwrap(), data);
    }

    #[test]
    fn a_caret_at_the_very_end_of_a_payload_takes_nothing_with_it() {
        let data = b"pixels".to_vec();
        let echoed = format!("{}^", b64(&data));
        assert_eq!(decode_base64(echoed.as_bytes()).unwrap(), data);
    }
}
