//! Where does the time go? Run with:
//!   cargo test --release --test throughput -- --ignored --nocapture

use cooked::emu::{BACKLOG_HIGH_WATER, Term};
use std::time::Instant;

/// Mirrors `session::READ_CHUNK`, which is private. Restated rather than exported: this
/// is a benchmark asserting it models the reader loop, and a constant that has to be
/// made public to be copied here would be public for no other reason.
const READ_CHUNK: usize = 64 * 1024;

fn timed(label: &str, bytes: usize, work: impl FnOnce()) {
    let start = Instant::now();
    work();
    let elapsed = start.elapsed();
    let mb = bytes as f64 / (1024.0 * 1024.0);
    println!(
        "{label:<34} {mb:6.1} MB in {:>7.1?}  =>  {:>7.0} MB/s",
        elapsed,
        mb / elapsed.as_secs_f64()
    );
}

/// Plain text, the `cat a big file` case.
fn plain(lines: usize) -> Vec<u8> {
    (0..lines)
        .flat_map(|i| {
            format!("line {i:06} the quick brown fox jumps over the lazy dog\r\n").into_bytes()
        })
        .collect()
}

/// Heavily coloured output, the `ls --color` / build-log case.
fn styled(lines: usize) -> Vec<u8> {
    (0..lines)
        .flat_map(|i| {
            format!(
                "\x1b[1;3{}mword\x1b[0m \x1b[38;2;10;20;30mrgb\x1b[0m plain {i}\r\n",
                i % 8
            )
            .into_bytes()
        })
        .collect()
}

/// Hyperlinked output, and the two shapes it comes in.
///
/// `distinct` links, cycled over `lines` rows. The two ends of that are the two things
/// `LinkStore` is asked to do, and they cost differently: one URI re-emitted per line
/// (`distinct == 1`) is pure reuse, while a fresh URI per line is pure interning, and
/// enough of them to pass `MAX_TRACKED_LINKS` is what puts the store in its steady state
/// of evicting one entry per insert.
fn hyperlinked(lines: usize, distinct: usize) -> Vec<u8> {
    (0..lines)
        .flat_map(|i| {
            let link = i % distinct.max(1);
            format!(
                "\x1b]8;;https://example.invalid/issue/{link:06}\x07issue {link}\x1b]8;;\x07 on line {i}\r\n"
            )
            .into_bytes()
        })
        .collect()
}

/// Full-screen repaint, the `htop` case: cursor addressing over the same cells.
fn repaint(frames: usize, rows: usize, cols: usize) -> Vec<u8> {
    let mut out = Vec::new();
    for frame in 0..frames {
        out.extend_from_slice(b"\x1b[H");
        for row in 1..=rows {
            out.extend_from_slice(format!("\x1b[{row};1H").as_bytes());
            out.extend_from_slice(format!("\x1b[4{}m", frame % 8).as_bytes());
            out.extend(std::iter::repeat_n(b'x', cols.saturating_sub(1)));
            out.extend_from_slice(b"\x1b[0m");
        }
    }
    out
}

/// Parsing with nothing collecting the output — what happens while Emacs is busy.
///
/// Backpressure is modelled rather than omitted, and that is the whole design of this
/// benchmark. Feeding all 200k lines in one call lets `pending_scrollback` reach 200k
/// entries, which is a state the reader thread makes unreachable: `Shared::read_loop`
/// stops reading the pty at `backlog() >= backlog_limit` and lets the child block in
/// `write`. So the un-throttled form measured heap growth, not parsing.
///
/// It measured it badly enough to invert the ordering: "parse only" came out
/// *slower* than parse-and-drain, which cannot be true of strictly less work. Reducing
/// evicted rows to runs in `State::archive` shrank the retained footprint but did not
/// bound it, and only the reader stopping bounds it. `perf stat` settles what the residue
/// was — 28,681 page faults against 3,826 for the draining variant, with instruction
/// counts within 2% of each other (10.18B vs 10.36B). Identical work, different memory:
/// the cost was the kernel handing over fresh pages, inside the timed region.
///
/// So the chunk size is `READ_CHUNK` and the backlog is sampled between chunks, both
/// matching `Shared::read_loop`, and a drain that trips the limit is thrown away —
/// `drop`, not consumption, because the premise is that Emacs is busy. The delta still
/// has to be built, which is the honest cost: in production backpressure is released by
/// Emacs draining, and that drain is not free either.
#[test]
#[ignore = "benchmark"]
fn feed_only() {
    for (label, data) in [
        ("plain, parse only", plain(200_000)),
        ("styled, parse only", styled(200_000)),
    ] {
        let mut term = Term::new(50, 200);
        let mut forced = 0usize;
        timed(label, data.len(), || {
            for piece in data.chunks(READ_CHUNK) {
                term.feed(piece);
                if term.backlog() >= BACKLOG_HIGH_WATER {
                    drop(term.drain());
                    forced += 1;
                }
            }
        });
        let delta = term.drain();
        println!(
            "{:>44}({} rows backlogged, {forced} drains forced by backpressure)",
            "",
            delta.scrolled.len()
        );
    }
}

/// Feeding plus draining, which is what a real session pays.
#[test]
#[ignore = "benchmark"]
fn feed_and_drain() {
    for (label, data, chunk) in [
        ("plain, drain every 64KB", plain(200_000), 64 * 1024),
        ("styled, drain every 64KB", styled(200_000), 64 * 1024),
    ] {
        let mut term = Term::new(50, 200);
        let mut runs = 0usize;
        timed(label, data.len(), || {
            for piece in data.chunks(chunk) {
                term.feed(piece);
                let delta = term.drain();
                runs += delta.rows.iter().map(|(_, r)| r.len()).sum::<usize>();
                runs += delta.scrolled.len();
            }
        });
        println!("{:>44}({runs} runs handed to Lisp)", "");
    }
}

/// The htop shape: every cell rewritten, drained once per frame.
#[test]
#[ignore = "benchmark"]
fn full_screen_repaint() {
    let data = repaint(2_000, 50, 200);
    let mut term = Term::new(50, 200);
    let mut rows = 0usize;
    timed("repaint, drain every frame", data.len(), || {
        for frame in data
            .split_inclusive(|b| *b == b'H')
            .collect::<Vec<_>>()
            .chunks(51)
        {
            for piece in frame {
                term.feed(piece);
            }
            rows += term.drain().rows.len();
        }
    });
    println!("{:>44}({rows} damaged rows handed to Lisp)", "");
}

/// What hyperlinks cost, which is a question about `LinkStore` rather than the parser.
///
/// Here because the other four benchmarks emit no `OSC 8` at all, so the store they all
/// share with the image path had no gate on it -- which is how an eviction that walked
/// every hash bucket, and so went quadratic once past `MAX_TRACKED_LINKS`, went unnoticed.
/// Both shapes are driven past that cap deliberately.
/// A kitty animation, in the shape `viu` actually sends: one full-resolution frame per
/// tick, the terminal asked to fit it with `c=`/`r=`, and the cursor walked back over the
/// picture so the next frame lands on top of it.
///
/// 826x647 RGBA is what the gif this was written for decodes to -- 2.1MB a frame, 2.8MB
/// once base64 has had it -- and the frames of a loop are byte-identical the second time
/// round, which is what makes content addressing worth anything here.
fn animation(frames: usize, w: u32, h: u32, cols: u16, rows: u16) -> Vec<Vec<u8>> {
    (0..frames)
        .map(|n| {
            let mut pixels = vec![0u8; (w * h * 4) as usize];
            // Enough to make every frame a distinct picture and no more: the payload is
            // what is being measured, not the decoder.
            pixels[0] = n as u8;
            pixels[1] = (n >> 8) as u8;
            // `\r` with the `CUU`: `a=T` leaves the cursor past the right edge of the
            // picture, so winding the rows back without also returning to column 0 lays
            // the next frame *beside* this one instead of over it -- which is not an
            // animation, and quietly turns this into a benchmark of a widening grid.
            let mut out =
                format!("\x1b[{rows}A\r\x1b_Gf=32,a=T,t=d,s={w},v={h},c={cols},r={rows};")
                    .into_bytes();
            out.extend_from_slice(b64(&pixels).as_bytes());
            out.extend_from_slice(b"\x1b\\");
            out
        })
        .collect()
}

fn b64(bytes: &[u8]) -> String {
    const ALPHABET: &[u8] = b"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    let mut out = String::with_capacity(bytes.len().div_ceil(3) * 4);
    for chunk in bytes.chunks(3) {
        let mut word = 0u32;
        for (i, &byte) in chunk.iter().enumerate() {
            word |= u32::from(byte) << (16 - 8 * i);
        }
        for i in 0..4 {
            if i <= chunk.len() {
                out.push(ALPHABET[((word >> (18 - 6 * i)) & 0x3F) as usize] as char);
            } else {
                out.push('=');
            }
        }
    }
    out
}

/// `mpv --vo=kitty`, which is a different animal from a gif player and worth its own
/// shape. Measured from a real capture: 800x450 raw RGB (`f=24`, so it becomes a PPM
/// rather than a PNG), 1.38MB a frame, chunked into 352 APCs of 4096 bytes, on the alt
/// screen, with `C=1` so the cursor does not move and `q=2` so nothing is replied to.
/// At 30fps that is 41MB/s arriving, sustained.
fn mpv_frames(frames: usize, w: u32, h: u32) -> Vec<Vec<u8>> {
    (0..frames)
        .map(|n| {
            let mut pixels = vec![0u8; (w * h * 3) as usize];
            pixels[0] = n as u8;
            pixels[1] = (n >> 8) as u8;
            let payload = b64(&pixels);
            let mut out = b"\x1b[0;0f".to_vec();
            let mut first = true;
            let mut rest = payload.as_str();
            while !rest.is_empty() {
                let take = rest.len().min(4096);
                let (chunk, tail) = rest.split_at(take);
                let more = u8::from(!tail.is_empty());
                if first {
                    out.extend_from_slice(
                        format!("\x1b_Ga=T,f=24,s={w},v={h},C=1,q=2,m={more};").as_bytes(),
                    );
                    first = false;
                } else {
                    out.extend_from_slice(format!("\x1b_Gm={more};").as_bytes());
                }
                out.extend_from_slice(chunk.as_bytes());
                out.extend_from_slice(b"\x1b\\");
                rest = tail;
            }
            out
        })
        .collect()
}

/// Where a video's time goes on our side of the boundary, and how much of it is ours.
///
/// The question this answers is whether a dropped frame is cooked's fault or Emacs'. Feed
/// alone is the parser, the base64, the PPM wrap and the content hash; feed-and-drain adds
/// the copy that crosses. Everything after that is Emacs decoding and scaling, which this
/// cannot see -- but if the numbers here are far above 41MB/s, it is not us.
#[test]
#[ignore = "benchmark"]
fn kitty_video() {
    let frames = mpv_frames(60, 800, 450);
    let fed: usize = frames.iter().map(Vec::len).sum();

    let mut term = Term::new(24, 80);
    term.feed(b"\x1b[?1049h");
    timed("mpv shape, parse only", fed, || {
        for frame in &frames {
            for piece in frame.chunks(READ_CHUNK) {
                term.feed(piece);
            }
        }
    });
    term.drain();

    let mut term = Term::new(24, 80);
    term.feed(b"\x1b[?1049h");
    let mut crossed = 0usize;
    timed("mpv shape, drain every frame", fed, || {
        for frame in &frames {
            for piece in frame.chunks(READ_CHUNK) {
                term.feed(piece);
            }
            crossed += term
                .drain()
                .images
                .iter()
                .map(|i| i.bytes.len())
                .sum::<usize>();
        }
    });
    let mb = crossed as f64 / (1024.0 * 1024.0);
    println!(
        "{:>44}({mb:.0} MB to Lisp, {:.2} MB per frame)",
        "",
        mb / frames.len() as f64
    );
}

/// What an animation costs Emacs, which is the only number that matters for it.
///
/// The child sets the frame rate and Emacs cannot be made to keep up with a 20fps stream
/// of two-megabyte pictures; what it can do is not be handed the frames it has already
/// missed. `BEHIND` is how many frames the child gets out while Emacs is busy with the
/// last one, so `behind=1` is a display keeping pace and `behind=4` is the case that
/// actually happens. The bytes-to-Lisp column is the whole point: it should track the
/// number of *drains*, not the number of frames.
#[test]
#[ignore = "benchmark"]
fn kitty_animation() {
    let frames = animation(30, 826, 647, 61, 23);
    let fed: usize = frames.iter().map(Vec::len).sum();
    for behind in [1usize, 2, 4, 8] {
        // Two loops, so the second one measures the content-addressed path.
        let mut term = Term::new(24, 80);
        let (mut crossed, mut drains, mut peak) = (0usize, 0usize, 0usize);
        timed(
            &format!("animation, {behind} frame(s) per drain"),
            fed * 2,
            || {
                for _ in 0..2 {
                    for batch in frames.chunks(behind) {
                        for frame in batch {
                            for piece in frame.chunks(READ_CHUNK) {
                                term.feed(piece);
                            }
                        }
                        let delta = term.drain();
                        crossed += delta.images.iter().map(|i| i.bytes.len()).sum::<usize>();
                        drains += 1;
                        peak = peak.max(delta.images.len());
                    }
                }
            },
        );
        println!(
            "{:>44}({drains} drains, {:.0} MB to Lisp, {peak} frames queued at worst)",
            "",
            crossed as f64 / (1024.0 * 1024.0)
        );
    }
}

#[test]
#[ignore = "benchmark"]
fn hyperlinks() {
    for (label, data) in [
        // Reuse, but of a store that is already full: one URI re-emitted per line with
        // several thousand others behind it. `distinct == 1` would exercise the same
        // code against a single entry, where any ordering is O(1) and a scan that had
        // crept back in would cost nothing measurable.
        (
            "OSC 8, one link reused, store full",
            [hyperlinked(8_000, 8_000), hyperlinked(200_000, 1)].concat(),
        ),
        ("OSC 8, 100k distinct links", hyperlinked(200_000, 100_000)),
    ] {
        let mut term = Term::new(50, 200);
        let mut links = 0usize;
        timed(label, data.len(), || {
            for piece in data.chunks(READ_CHUNK) {
                term.feed(piece);
                links += term.drain().links.len();
            }
        });
        println!("{:>44}({links} distinct URIs handed to Lisp)", "");
    }
}

/// How much does an OSC cost, given they arrive a handful of times per command?
#[test]
#[ignore = "benchmark"]
fn osc_dispatch() {
    let data: Vec<u8> = (0..200_000)
        .flat_map(|i| {
            format!("\x1b]133;A\x07$ \x1b]133;B\x07cmd\x1b]133;C\x07out{i}\r\n\x1b]133;D;0\x07")
                .into_bytes()
        })
        .collect();
    let mut term = Term::new(50, 200);
    timed("OSC 133, 800k sequences", data.len(), || {
        for piece in data.chunks(64 * 1024) {
            term.feed(piece);
            term.drain();
        }
    });
}
