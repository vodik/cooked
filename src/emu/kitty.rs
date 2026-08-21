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

use super::image::{ImageFormat, ImageId, png_from_rgba, ppm_from_rgb};

/// Largest payload reassembled from a chunked transmission.
///
/// Chunks are capped at 4096 bytes by the protocol, so this is a bound on how many of
/// them one image may take rather than on any single APC.
pub const MAX_PAYLOAD: usize = 32 << 20;

/// What the child asked for. `a=` in the control data.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default)]
pub enum Action {
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
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Payload {
    /// `f=24`
    Rgb,
    /// `f=32`, the protocol's default.
    Rgba,
    /// `f=100`
    Png,
}

/// One parsed command, before its payload has been reassembled.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Command {
    pub action: Action,
    pub format: Payload,
    pub more: bool,
    /// `o=z` — the payload is zlib-deflated under its base64.
    pub compressed: bool,
    pub id: u32,
    pub px: (u32, u32),
    pub cells: (u16, u16),
    /// `q=1` suppresses success, `q=2` suppresses everything.
    pub quiet: u8,
    /// A capability named in the control data that this terminal does not implement.
    pub unsupported: Option<&'static str>,
}

impl Default for Command {
    fn default() -> Self {
        Self {
            action: Action::default(),
            format: Payload::Rgba,
            more: false,
            compressed: false,
            id: 0,
            px: (0, 0),
            cells: (0, 0),
            quiet: 0,
            unsupported: None,
        }
    }
}

impl Command {
    /// Parse the control data — everything before the `;` — of a `G` command.
    ///
    /// Unknown keys are ignored rather than refused, which is what the protocol asks
    /// for: it is extended by adding keys, and a terminal that failed on the first one
    /// it had not heard of would break on every new client. Keys naming a *capability*
    /// are different, and land in `unsupported`.
    pub fn parse(control: &str) -> Self {
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
                    }
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
                "i" => cmd.id = num(),
                "s" => cmd.px.0 = num(),
                "v" => cmd.px.1 = num(),
                "c" => cmd.cells.0 = num().min(u32::from(u16::MAX)) as u16,
                "r" => cmd.cells.1 = num().min(u32::from(u16::MAX)) as u16,
                "q" => cmd.quiet = num().min(255) as u8,
                _ => {}
            }
        }
        cmd
    }
}

/// What the terminal should do once a command's payload is complete.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Outcome {
    /// Nothing yet — more chunks are coming.
    Incomplete,
    /// Hand these bytes to the image store; display them if `display`.
    Image {
        format: ImageFormat,
        bytes: Vec<u8>,
        px: (u32, u32),
        cells: (u16, u16),
        client_id: u32,
        display: bool,
    },
    /// Place an image already transmitted under this id.
    Place(ImageId),
    /// Nothing to do, but the child may be owed an answer.
    Nothing,
}

/// Per-session protocol state: partly-received transmissions and the client's id space.
#[derive(Debug, Default)]
pub struct Kitty {
    /// The transmission being reassembled, if a chunked one is in flight.
    ///
    /// One at a time, which is what the protocol allows: a client must finish a chunked
    /// transmission before starting another.
    pending: Option<(Command, Vec<u8>)>,
    /// The child's own image ids, which are not ours — ours are content-addressed, so
    /// two clients reusing the same number cannot collide, and one client reusing a
    /// number for a different picture cannot alias.
    by_client: HashMap<u32, ImageId>,
}

impl Kitty {
    /// Note that CLIENT_ID now means the image we interned as OURS.
    pub fn bind(&mut self, client_id: u32, ours: ImageId) {
        if client_id != 0 {
            self.by_client.insert(client_id, ours);
        }
    }

    /// Take one APC payload, returning what the terminal should do about it.
    ///
    /// PAYLOAD is the whole APC body, `G` and all — the introducer is checked here
    /// rather than by the caller, because APC is a general escape and something else
    /// may one day be carried in it. Anything not addressed to `G` is not ours.
    pub fn feed(&mut self, payload: &[u8]) -> (Outcome, Option<Vec<u8>>) {
        let Some(payload) = payload.strip_prefix(b"G") else {
            return (Outcome::Nothing, None);
        };
        let (control, body) = match payload.iter().position(|&b| b == b';') {
            Some(at) => (&payload[..at], &payload[at + 1..]),
            None => (payload, &[][..]),
        };
        let control = String::from_utf8_lossy(control);

        // A continuation carries only `m=` and perhaps `q=`; the command it continues is
        // the one already in flight, whose format and geometry still apply.
        if let Some((cmd, buf)) = self.pending.take() {
            let more = Command::parse(&control).more;
            let mut buf = buf;
            if !append(&mut buf, body) {
                return (Outcome::Nothing, response(&cmd, Some("EBIG:payload")));
            }
            if more {
                self.pending = Some((cmd, buf));
                return (Outcome::Incomplete, None);
            }
            return self.finish(cmd, buf);
        }

        let cmd = Command::parse(&control);
        if let Some(why) = cmd.unsupported {
            return (Outcome::Nothing, response(&cmd, Some(why)));
        }
        match cmd.action {
            // A probe must leave no trace: answering is the whole of it.
            Action::Query => return (Outcome::Nothing, response(&cmd, None)),
            Action::Delete => {
                // The bytes are not ours to free — Emacs holds them for as long as the
                // buffer text showing them lives — so this only retires the child's name
                // for the picture. See the module comment in `image.rs`.
                self.by_client.remove(&cmd.id);
                return (Outcome::Nothing, response(&cmd, None));
            }
            Action::Put => {
                let found = self.by_client.get(&cmd.id).copied();
                return match found {
                    Some(id) => (Outcome::Place(id), response(&cmd, None)),
                    None => (Outcome::Nothing, response(&cmd, Some("ENOENT:image"))),
                };
            }
            Action::Transmit | Action::Display => {}
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
        // cannot be laid out, and one whose geometry outruns what actually arrived is not
        // describing the bytes it sent. Both are checked *before* converting, because the
        // conversion sizes its buffer from the geometry: `s=65535,v=65535` with a
        // four-byte payload is a 13GB allocation asked for by anything that can write to
        // the terminal, which `cat` of a hostile file is. Bounding it against the payload
        // needs no arbitrary maximum — `MAX_PAYLOAD` already bounds that.
        let bytes_per_pixel = match cmd.format {
            Payload::Png => 0,
            Payload::Rgb => 3,
            Payload::Rgba => 4,
        };
        if bytes_per_pixel != 0 {
            let needed = u64::from(cmd.px.0) * u64::from(cmd.px.1) * bytes_per_pixel;
            if needed == 0 || needed > raw.len() as u64 {
                return (Outcome::Nothing, response(&cmd, Some("EINVAL:dimensions")));
            }
        }
        let (format, bytes) = match cmd.format {
            Payload::Png => (ImageFormat::Png, raw),
            Payload::Rgb => (ImageFormat::Ppm, ppm_from_rgb(cmd.px, &raw)),
            Payload::Rgba => (ImageFormat::Png, png_from_rgba(cmd.px, &raw)),
        };
        (
            Outcome::Image {
                format,
                bytes,
                px: cmd.px,
                cells: cmd.cells,
                client_id: cmd.id,
                display: cmd.action == Action::Display,
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

/// Standard base64, rejecting anything that is not.
///
/// Whitespace is skipped because a payload split across chunks can pick up a newline
/// from a shell that echoed it, and dropping the picture over that would be a worse
/// answer than ignoring it.
fn decode_base64(input: &[u8]) -> Option<Vec<u8>> {
    let mut out = Vec::with_capacity(input.len() / 4 * 3);
    let (mut acc, mut bits) = (0u32, 0u32);
    for &byte in input {
        let value = match byte {
            b'A'..=b'Z' => u32::from(byte - b'A'),
            b'a'..=b'z' => u32::from(byte - b'a') + 26,
            b'0'..=b'9' => u32::from(byte - b'0') + 52,
            b'+' => 62,
            b'/' => 63,
            b'=' => continue,
            b' ' | b'\t' | b'\r' | b'\n' => continue,
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

#[cfg(test)]
mod tests {
    use super::*;

    fn b64(bytes: &[u8]) -> String {
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
        assert_eq!(cmd.px, (64, 32));
        assert_eq!(cmd.cells, (8, 4));
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
                px: (0, 0),
                cells: (0, 0),
                client_id: 3,
                display: true,
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
        // One pixel short is still short.
        let apc = format!("Ga=T,f=32,s=2,v=1,i=4;{}", b64(&[0; 7]));
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
        assert_eq!(k.feed(b"Ga=p,i=9").0, Outcome::Place(ImageId(42)));
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
}
