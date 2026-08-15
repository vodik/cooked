//! Where does the time go? Run with:
//!   cargo test --release --test throughput -- --ignored --nocapture

use cooked::emu::Term;
use std::time::Instant;

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
/// This measured allocator churn rather than parsing until scrollback stopped
/// retaining full-width grid rows: 200k un-drained rows dominated everything and made
/// "parse only" look slower than parse-and-drain, which is impossible. In a real
/// session the reader applies backpressure long before the backlog gets this large.
#[test]
#[ignore = "benchmark"]
fn feed_only() {
    for (label, data) in [
        ("plain, parse only", plain(200_000)),
        ("styled, parse only", styled(200_000)),
    ] {
        let mut term = Term::new(50, 200);
        timed(label, data.len(), || term.feed(&data));
        let delta = term.drain();
        println!("{:>44}({} rows backlogged)", "", delta.scrolled.len());
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
