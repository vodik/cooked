//! Classification of box-drawing and block-element characters into a compact shape
//! descriptor, so the Lisp side can rasterize them from the descriptor instead of
//! trusting the font glyph — the same reason VTE, Kitty and Alacritty stopped trusting
//! the font for this Unicode range: glyph-to-glyph inconsistency across fonts breaks
//! borders in full-screen programs (htop, ranger, fzf) that rely on these characters
//! connecting exactly.
//!
//! Scope: light/heavy/double lines and their junctions (U+2500-U+254B, U+2550-U+256C),
//! rounded corners (U+256D-U+2570), true diagonals and half-length "stub" lines
//! (U+2571-U+257F), and block elements/shades/quadrants (U+2580-U+259F) — every
//! assigned codepoint in the Box Drawing and Block Elements blocks.

use Weight::{Double as D, Heavy as H, Light as L, None as Z};

/// Line weight, or the absence of an edge.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Weight {
    None,
    Light,
    Heavy,
    Double,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Edge {
    Up,
    Down,
    Left,
    Right,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Direction {
    Up,
    Down,
    Left,
    Right,
    /// A solid block covering the whole cell (U+2588).
    Full,
    /// One of the three shade densities (U+2591-2593) — a dither pattern, not a
    /// filled rectangle, so `fraction` here is a 1-3 density level, not eighths.
    Shade,
    /// One of the ten 2x2 quadrant glyphs (U+2596-259F) — `fraction` here is a
    /// 4-bit mask (upper-left=1, upper-right=2, lower-left=4, lower-right=8), not a
    /// single fill amount.
    Quadrant,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Kind {
    Line,
    Block,
}

const KIND_BLOCK: u16 = 1 << 15;
const ARC: u16 = 1 << 8;
/// U+2571 ╱: a straight line from the bottom-left corner to the top-right.
const DIAG_FORWARD: u16 = 1 << 9;
/// U+2572 ╲: a straight line from the top-left corner to the bottom-right.
const DIAG_BACKWARD: u16 = 1 << 10;
/// How many dashes the stroke breaks into: 0 solid, 1 double, 2 triple, 3 quadruple.
/// Stored as a code rather than the count so it fits the two bits the layout has left;
/// `BoxGlyph::dashes` hands out the count so no caller has to know that.
const DASH_SHIFT: u16 = 11;
const DASH_MASK: u16 = 0b11 << DASH_SHIFT;

/// Compact classification of a box-drawing or block-element glyph, packed into 16
/// bits so a `Run` can carry one per character without a large side allocation.
/// Hand-rolled like `Attrs` (cell.rs) rather than pulled in from a crate — this
/// project takes only libc/nix/unicode-width/vte as direct dependencies.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Hash)]
pub struct BoxGlyph(u16);

impl BoxGlyph {
    fn line(up: Weight, down: Weight, left: Weight, right: Weight) -> Self {
        Self(
            weight_bits(up)
                | (weight_bits(down) << 2)
                | (weight_bits(left) << 4)
                | (weight_bits(right) << 6),
        )
    }

    fn arc(up: Weight, down: Weight, left: Weight, right: Weight) -> Self {
        Self(Self::line(up, down, left, right).0 | ARC)
    }

    /// A line broken into `dashes` segments — 2, 3 or 4, the only counts Unicode
    /// defines. Any other value would be a caller bug, so it is asserted rather than
    /// silently clamped: a wrong code here is a wrong glyph on screen, not a panic the
    /// emulator could recover from.
    fn dashed(up: Weight, down: Weight, left: Weight, right: Weight, dashes: u8) -> Self {
        let code = match dashes {
            2 => 1,
            3 => 2,
            4 => 3,
            _ => unreachable!("Unicode defines only 2-, 3- and 4-dash lines"),
        };
        Self(Self::line(up, down, left, right).0 | (code << DASH_SHIFT))
    }

    fn block(direction: Direction, fraction: u8) -> Self {
        Self(KIND_BLOCK | direction_bits(direction) | (u16::from(fraction) << 3))
    }

    fn slash(forward: bool, backward: bool) -> Self {
        Self((if forward { DIAG_FORWARD } else { 0 }) | (if backward { DIAG_BACKWARD } else { 0 }))
    }

    pub const fn bits(self) -> u16 {
        self.0
    }

    pub fn kind(self) -> Kind {
        if self.0 & KIND_BLOCK != 0 {
            Kind::Block
        } else {
            Kind::Line
        }
    }

    /// Whether a `Line`-kind corner should be drawn as a quarter-circle rather than a
    /// mitered right angle. Only ever set on the four rounded-corner codepoints, which
    /// would otherwise be bit-identical to their square-corner counterparts.
    pub fn is_arc(self) -> bool {
        self.kind() == Kind::Line && self.0 & ARC != 0
    }

    /// Whether a `Line`-kind glyph is a true corner-to-corner diagonal (U+2571-2573)
    /// rather than an edge-based shape. `edge`/`is_arc` are meaningless when this is
    /// true — the two representations don't overlap on any real codepoint.
    pub fn is_diagonal(self) -> bool {
        self.kind() == Kind::Line && self.0 & (DIAG_FORWARD | DIAG_BACKWARD) != 0
    }

    /// `(forward, backward)`: which of the two diagonal strokes (╱ and ╲) a
    /// `Line`-kind glyph draws. Both true only for U+2573 ╳. Meaningless unless
    /// `is_diagonal` is true.
    pub fn diagonal(self) -> (bool, bool) {
        (self.0 & DIAG_FORWARD != 0, self.0 & DIAG_BACKWARD != 0)
    }

    /// Weight of one edge of a `Line`-kind glyph. Meaningless (always `None`) for
    /// `Block`-kind glyphs.
    pub fn edge(self, edge: Edge) -> Weight {
        let shift = match edge {
            Edge::Up => 0,
            Edge::Down => 2,
            Edge::Left => 4,
            Edge::Right => 6,
        };
        weight_from_bits((self.0 >> shift) & 0b11)
    }

    /// How many dashes a `Line`-kind glyph's stroke breaks into: 0 for a solid line,
    /// otherwise 2, 3 or 4. Unicode only ever dashes a plain horizontal or vertical
    /// line, never a junction, corner or arc. Meaningless (always 0) for `Block`-kind
    /// glyphs.
    pub fn dashes(self) -> u8 {
        match (self.0 & DASH_MASK) >> DASH_SHIFT {
            1 => 2,
            2 => 3,
            3 => 4,
            _ => 0,
        }
    }

    /// Fill direction of a `Block`-kind glyph. Meaningless (always `Up`) for
    /// `Line`-kind glyphs.
    pub fn direction(self) -> Direction {
        direction_from_bits(self.0 & 0b111)
    }

    /// Fill amount of a `Block`-kind glyph: eighths (1-8) for a directional fill,
    /// a 1-3 density level for `Direction::Shade`, or a 4-bit quadrant mask for
    /// `Direction::Quadrant`. Meaningless (always 0) for `Line`-kind glyphs.
    pub fn fraction(self) -> u8 {
        ((self.0 >> 3) & 0b1111) as u8
    }
}

fn weight_bits(w: Weight) -> u16 {
    match w {
        Weight::None => 0,
        Weight::Light => 1,
        Weight::Heavy => 2,
        Weight::Double => 3,
    }
}

fn weight_from_bits(bits: u16) -> Weight {
    match bits {
        1 => Weight::Light,
        2 => Weight::Heavy,
        3 => Weight::Double,
        _ => Weight::None,
    }
}

fn direction_bits(d: Direction) -> u16 {
    match d {
        Direction::Up => 0,
        Direction::Down => 1,
        Direction::Left => 2,
        Direction::Right => 3,
        Direction::Full => 4,
        Direction::Shade => 5,
        Direction::Quadrant => 6,
    }
}

fn direction_from_bits(bits: u16) -> Direction {
    match bits {
        1 => Direction::Down,
        2 => Direction::Left,
        3 => Direction::Right,
        4 => Direction::Full,
        5 => Direction::Shade,
        6 => Direction::Quadrant,
        _ => Direction::Up,
    }
}

/// Structured shape for a box-drawing or block-element codepoint, or `None` for
/// anything the emulator renders as plain glyph-shaped text.
pub fn classify(ch: char) -> Option<BoxGlyph> {
    match ch {
        '\u{2500}'..='\u{254F}' => classify_line(ch),
        '\u{2550}'..='\u{256C}' => classify_double_line(ch),
        '\u{256D}'..='\u{2570}' => classify_arc(ch),
        '\u{2571}'..='\u{2573}' => classify_diagonal(ch),
        '\u{2574}'..='\u{257F}' => classify_stub(ch),
        '\u{2580}'..='\u{259F}' => classify_block(ch),
        _ => None,
    }
}

/// U+2500-U+254F: light/heavy horizontal & vertical lines, corners, T-junctions and
/// crosses, in every light/heavy combination the block defines. Verified against the
/// Unicode Box Drawing chart.
///
/// The dashed variants carry a dash count alongside their weight rather than
/// collapsing onto the solid line they otherwise match. The dashed codepoints are not
/// contiguous — the triple/quadruple families sit at U+2504-250B, but the double-dash
/// family was appended later at U+254C-254F, past the junctions — which is why this
/// arm runs to 254F while the double-line block still starts at 2550.
fn classify_line(ch: char) -> Option<BoxGlyph> {
    // Handled first: these are the only codepoints here that are not a plain
    // (up, down, left, right) tuple.
    if let Some(glyph) = classify_dashed_line(ch) {
        return Some(glyph);
    }
    let (up, down, left, right) = match ch {
        '\u{2500}' => (Z, Z, L, L),
        '\u{2501}' => (Z, Z, H, H),
        '\u{2502}' => (L, L, Z, Z),
        '\u{2503}' => (H, H, Z, Z),
        // U+2504-250B are the triple/quadruple dashes — see `classify_dashed_line`.
        '\u{250C}' => (Z, L, Z, L),
        '\u{250D}' => (Z, L, Z, H),
        '\u{250E}' => (Z, H, Z, L),
        '\u{250F}' => (Z, H, Z, H),
        '\u{2510}' => (Z, L, L, Z),
        '\u{2511}' => (Z, L, H, Z),
        '\u{2512}' => (Z, H, L, Z),
        '\u{2513}' => (Z, H, H, Z),
        '\u{2514}' => (L, Z, Z, L),
        '\u{2515}' => (L, Z, Z, H),
        '\u{2516}' => (H, Z, Z, L),
        '\u{2517}' => (H, Z, Z, H),
        '\u{2518}' => (L, Z, L, Z),
        '\u{2519}' => (L, Z, H, Z),
        '\u{251A}' => (H, Z, L, Z),
        '\u{251B}' => (H, Z, H, Z),
        '\u{251C}' => (L, L, Z, L),
        '\u{251D}' => (L, L, Z, H),
        '\u{251E}' => (H, L, Z, L),
        '\u{251F}' => (L, H, Z, L),
        '\u{2520}' => (H, H, Z, L),
        '\u{2521}' => (H, L, Z, H),
        '\u{2522}' => (L, H, Z, H),
        '\u{2523}' => (H, H, Z, H),
        '\u{2524}' => (L, L, L, Z),
        '\u{2525}' => (L, L, H, Z),
        '\u{2526}' => (H, L, L, Z),
        '\u{2527}' => (L, H, L, Z),
        '\u{2528}' => (H, H, L, Z),
        '\u{2529}' => (H, L, H, Z),
        '\u{252A}' => (L, H, H, Z),
        '\u{252B}' => (H, H, H, Z),
        '\u{252C}' => (Z, L, L, L),
        '\u{252D}' => (Z, L, H, L),
        '\u{252E}' => (Z, L, L, H),
        '\u{252F}' => (Z, L, H, H),
        '\u{2530}' => (Z, H, L, L),
        '\u{2531}' => (Z, H, H, L),
        '\u{2532}' => (Z, H, L, H),
        '\u{2533}' => (Z, H, H, H),
        '\u{2534}' => (L, Z, L, L),
        '\u{2535}' => (L, Z, H, L),
        '\u{2536}' => (L, Z, L, H),
        '\u{2537}' => (L, Z, H, H),
        '\u{2538}' => (H, Z, L, L),
        '\u{2539}' => (H, Z, H, L),
        '\u{253A}' => (H, Z, L, H),
        '\u{253B}' => (H, Z, H, H),
        '\u{253C}' => (L, L, L, L),
        '\u{253D}' => (L, L, H, L),
        '\u{253E}' => (L, L, L, H),
        '\u{253F}' => (L, L, H, H),
        '\u{2540}' => (H, L, L, L),
        '\u{2541}' => (L, H, L, L),
        '\u{2542}' => (H, H, L, L),
        '\u{2543}' => (H, L, H, L),
        '\u{2544}' => (H, L, L, H),
        '\u{2545}' => (L, H, H, L),
        '\u{2546}' => (L, H, L, H),
        '\u{2547}' => (H, L, H, H),
        '\u{2548}' => (L, H, H, H),
        '\u{2549}' => (H, H, H, L),
        '\u{254A}' => (H, H, L, H),
        '\u{254B}' => (H, H, H, H),
        _ => return None,
    };
    Some(BoxGlyph::line(up, down, left, right))
}

/// The twelve dashed lines: three dash counts x two weights x two orientations. Each
/// is otherwise identical to the solid line of the same weight and orientation, so the
/// dash count is the only thing distinguishing (say) U+2504 ┄ from U+2500 ─.
fn classify_dashed_line(ch: char) -> Option<BoxGlyph> {
    let (up, down, left, right, dashes) = match ch {
        '\u{2504}' => (Z, Z, L, L, 3), // ┄
        '\u{2505}' => (Z, Z, H, H, 3), // ┅
        '\u{2506}' => (L, L, Z, Z, 3), // ┆
        '\u{2507}' => (H, H, Z, Z, 3), // ┇
        '\u{2508}' => (Z, Z, L, L, 4), // ┈
        '\u{2509}' => (Z, Z, H, H, 4), // ┉
        '\u{250A}' => (L, L, Z, Z, 4), // ┊
        '\u{250B}' => (H, H, Z, Z, 4), // ┋
        '\u{254C}' => (Z, Z, L, L, 2), // ╌
        '\u{254D}' => (Z, Z, H, H, 2), // ╍
        '\u{254E}' => (L, L, Z, Z, 2), // ╎
        '\u{254F}' => (H, H, Z, Z, 2), // ╏
        _ => return None,
    };
    Some(BoxGlyph::dashed(up, down, left, right, dashes))
}

/// U+2550-U+256C: the double-line block, and its single/double mixed corners,
/// T-junctions and cross. Same representation as `classify_line`, just reusing the
/// `Weight::Double` value those codepoints never need.
fn classify_double_line(ch: char) -> Option<BoxGlyph> {
    let (up, down, left, right) = match ch {
        '\u{2550}' => (Z, Z, D, D),
        '\u{2551}' => (D, D, Z, Z),
        '\u{2552}' => (Z, L, Z, D),
        '\u{2553}' => (Z, D, Z, L),
        '\u{2554}' => (Z, D, Z, D),
        '\u{2555}' => (Z, L, D, Z),
        '\u{2556}' => (Z, D, L, Z),
        '\u{2557}' => (Z, D, D, Z),
        '\u{2558}' => (L, Z, Z, D),
        '\u{2559}' => (D, Z, Z, L),
        '\u{255A}' => (D, Z, Z, D),
        '\u{255B}' => (L, Z, D, Z),
        '\u{255C}' => (D, Z, L, Z),
        '\u{255D}' => (D, Z, D, Z),
        '\u{255E}' => (L, L, Z, D),
        '\u{255F}' => (D, D, Z, L),
        '\u{2560}' => (D, D, Z, D),
        '\u{2561}' => (L, L, D, Z),
        '\u{2562}' => (D, D, L, Z),
        '\u{2563}' => (D, D, D, Z),
        '\u{2564}' => (Z, D, L, L),
        '\u{2565}' => (Z, L, D, D),
        '\u{2566}' => (Z, D, D, D),
        '\u{2567}' => (D, Z, L, L),
        '\u{2568}' => (L, Z, D, D),
        '\u{2569}' => (D, Z, D, D),
        '\u{256A}' => (D, D, L, L),
        '\u{256B}' => (L, L, D, D),
        '\u{256C}' => (D, D, D, D),
        _ => return None,
    };
    Some(BoxGlyph::line(up, down, left, right))
}

/// U+256D-U+2570: rounded corners — same edge pairs as their square-corner
/// counterparts (U+250C/2510/2518/2514), with `ARC` set so the renderer draws a
/// quarter-circle instead of a mitered right angle.
fn classify_arc(ch: char) -> Option<BoxGlyph> {
    let (up, down, left, right) = match ch {
        '\u{256D}' => (Z, L, Z, L), // ╭ same pair as ┌
        '\u{256E}' => (Z, L, L, Z), // ╮ same pair as ┐
        '\u{256F}' => (L, Z, L, Z), // ╯ same pair as ┘
        '\u{2570}' => (L, Z, Z, L), // ╰ same pair as └
        _ => return None,
    };
    Some(BoxGlyph::arc(up, down, left, right))
}

/// U+2571-U+2573: true corner-to-corner diagonals — not expressible as edges, so
/// these are the only codepoints using the `DIAG_FORWARD`/`DIAG_BACKWARD` bits
/// rather than the four edge-weight fields.
fn classify_diagonal(ch: char) -> Option<BoxGlyph> {
    let (forward, backward) = match ch {
        '\u{2571}' => (true, false), // ╱
        '\u{2572}' => (false, true), // ╲
        '\u{2573}' => (true, true),  // ╳
        _ => return None,
    };
    Some(BoxGlyph::slash(forward, backward))
}

/// U+2574-U+257F: half-length "stub" lines — plain `Line` glyphs, exactly like
/// `classify_line`, just with only one or two of the four edges set. Unicode never
/// pairs a stub with `Weight::Double`, so only light/heavy appear here.
fn classify_stub(ch: char) -> Option<BoxGlyph> {
    let (up, down, left, right) = match ch {
        '\u{2574}' => (Z, Z, L, Z), // ╴ light left
        '\u{2575}' => (L, Z, Z, Z), // ╵ light up
        '\u{2576}' => (Z, Z, Z, L), // ╶ light right
        '\u{2577}' => (Z, L, Z, Z), // ╷ light down
        '\u{2578}' => (Z, Z, H, Z), // ╸ heavy left
        '\u{2579}' => (H, Z, Z, Z), // ╹ heavy up
        '\u{257A}' => (Z, Z, Z, H), // ╺ heavy right
        '\u{257B}' => (Z, H, Z, Z), // ╻ heavy down
        '\u{257C}' => (Z, Z, L, H), // ╼ light left, heavy right
        '\u{257D}' => (L, H, Z, Z), // ╽ light up, heavy down
        '\u{257E}' => (Z, Z, H, L), // ╾ heavy left, light right
        '\u{257F}' => (H, L, Z, Z), // ╿ heavy up, light down
        _ => return None,
    };
    Some(BoxGlyph::line(up, down, left, right))
}

/// U+2580-U+259F: half/eighth blocks, full block, the three shade densities, and the
/// ten 2x2 quadrant glyphs.
fn classify_block(ch: char) -> Option<BoxGlyph> {
    use Direction::{Down, Full, Left, Quadrant, Right, Shade, Up};
    let (direction, fraction) = match ch {
        '\u{2580}' => (Up, 4),
        '\u{2581}' => (Down, 1),
        '\u{2582}' => (Down, 2),
        '\u{2583}' => (Down, 3),
        '\u{2584}' => (Down, 4),
        '\u{2585}' => (Down, 5),
        '\u{2586}' => (Down, 6),
        '\u{2587}' => (Down, 7),
        '\u{2588}' => (Full, 8),
        '\u{2589}' => (Left, 7),
        '\u{258A}' => (Left, 6),
        '\u{258B}' => (Left, 5),
        '\u{258C}' => (Left, 4),
        '\u{258D}' => (Left, 3),
        '\u{258E}' => (Left, 2),
        '\u{258F}' => (Left, 1),
        '\u{2590}' => (Right, 4),
        '\u{2591}' => (Shade, 1),
        '\u{2592}' => (Shade, 2),
        '\u{2593}' => (Shade, 3),
        '\u{2594}' => (Up, 1),
        '\u{2595}' => (Right, 1),
        '\u{2596}' => (Quadrant, 0b0100), // lower-left
        '\u{2597}' => (Quadrant, 0b1000), // lower-right
        '\u{2598}' => (Quadrant, 0b0001), // upper-left
        '\u{2599}' => (Quadrant, 0b1101), // upper-left, lower-left, lower-right
        '\u{259A}' => (Quadrant, 0b1001), // upper-left, lower-right
        '\u{259B}' => (Quadrant, 0b0111), // upper-left, upper-right, lower-left
        '\u{259C}' => (Quadrant, 0b1011), // upper-left, upper-right, lower-right
        '\u{259D}' => (Quadrant, 0b0010), // upper-right
        '\u{259E}' => (Quadrant, 0b0110), // upper-right, lower-left
        '\u{259F}' => (Quadrant, 0b1110), // upper-right, lower-left, lower-right
        _ => return None,
    };
    Some(BoxGlyph::block(direction, fraction))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn non_box_drawing_chars_classify_to_none() {
        assert_eq!(classify('a'), None);
        assert_eq!(classify(' '), None);
    }

    #[test]
    fn classifies_light_lines() {
        let horizontal = classify('\u{2500}').unwrap();
        assert_eq!(horizontal.kind(), Kind::Line);
        assert_eq!(horizontal.edge(Edge::Left), Weight::Light);
        assert_eq!(horizontal.edge(Edge::Right), Weight::Light);
        assert_eq!(horizontal.edge(Edge::Up), Weight::None);
        assert_eq!(horizontal.edge(Edge::Down), Weight::None);

        let vertical = classify('\u{2502}').unwrap();
        assert_eq!(vertical.edge(Edge::Up), Weight::Light);
        assert_eq!(vertical.edge(Edge::Down), Weight::Light);
        assert_eq!(vertical.edge(Edge::Left), Weight::None);
    }

    #[test]
    fn classifies_heavy_cross() {
        let cross = classify('\u{254B}').unwrap();
        for edge in [Edge::Up, Edge::Down, Edge::Left, Edge::Right] {
            assert_eq!(cross.edge(edge), Weight::Heavy);
        }
    }

    #[test]
    fn dashed_lines_keep_their_weight_and_carry_a_dash_count() {
        for (ch, dashes) in [
            ('\u{254C}', 2), // ╌
            ('\u{2504}', 3), // ┄
            ('\u{2508}', 4), // ┈
        ] {
            let glyph = classify(ch).unwrap();
            assert_eq!(glyph.dashes(), dashes, "{ch:?}");
            assert_eq!(glyph.edge(Edge::Left), Weight::Light, "{ch:?}");
            assert_eq!(glyph.edge(Edge::Right), Weight::Light, "{ch:?}");
            assert_eq!(glyph.edge(Edge::Up), Weight::None, "{ch:?}");
        }

        // The heavy and vertical members of each family differ only as expected.
        let heavy = classify('\u{2505}').unwrap(); // ┅
        assert_eq!(heavy.dashes(), 3);
        assert_eq!(heavy.edge(Edge::Left), Weight::Heavy);

        let vertical = classify('\u{254F}').unwrap(); // ╏
        assert_eq!(vertical.dashes(), 2);
        assert_eq!(vertical.edge(Edge::Up), Weight::Heavy);
        assert_eq!(vertical.edge(Edge::Left), Weight::None);
    }

    // The bug this field exists to fix: every dashed line used to be bit-identical to
    // the solid line of the same weight, so the distinction was lost in the emulator
    // and the renderer could not have drawn a dash even in principle.
    #[test]
    fn dashed_lines_are_distinct_from_their_solid_counterpart_and_each_other() {
        let solid = classify('\u{2500}').unwrap(); // ─
        let double = classify('\u{254C}').unwrap(); // ╌
        let triple = classify('\u{2504}').unwrap(); // ┄
        let quadruple = classify('\u{2508}').unwrap(); // ┈
        assert_eq!(solid.dashes(), 0);
        assert_ne!(solid, double);
        assert_ne!(double, triple);
        assert_ne!(triple, quadruple);
    }

    // U+254C-254F sit past the junctions rather than beside the other dashes, and used
    // to fall in the gap between this block's two classified ranges — unclassified, so
    // rendered with the font while everything around them was a generated bitmap.
    #[test]
    fn the_double_dash_family_past_the_junctions_is_classified() {
        for ch in ['\u{254C}', '\u{254D}', '\u{254E}', '\u{254F}'] {
            assert!(classify(ch).is_some(), "{ch:?} must classify");
        }
        // ...without swallowing the double-line block that starts immediately after.
        assert_eq!(classify('\u{2550}').unwrap().edge(Edge::Left), Weight::Double);
        assert_eq!(classify('\u{2550}').unwrap().dashes(), 0);
    }

    #[test]
    fn classifies_double_lines() {
        let double_corner = classify('\u{2554}').unwrap(); // ╔
        assert_eq!(double_corner.edge(Edge::Down), Weight::Double);
        assert_eq!(double_corner.edge(Edge::Right), Weight::Double);
        assert_eq!(double_corner.edge(Edge::Up), Weight::None);

        let mixed = classify('\u{2552}').unwrap(); // ╒ down single, right double
        assert_eq!(mixed.edge(Edge::Down), Weight::Light);
        assert_eq!(mixed.edge(Edge::Right), Weight::Double);
    }

    #[test]
    fn rounded_corners_set_the_arc_flag_and_match_their_square_counterpart() {
        let round = classify('\u{256D}').unwrap(); // ╭
        let square = classify('\u{250C}').unwrap(); // ┌
        assert!(round.is_arc());
        assert!(!square.is_arc());
        assert_eq!(round.edge(Edge::Down), square.edge(Edge::Down));
        assert_eq!(round.edge(Edge::Right), square.edge(Edge::Right));
    }

    #[test]
    fn classifies_half_and_full_blocks() {
        let full = classify('\u{2588}').unwrap();
        assert_eq!(full.kind(), Kind::Block);
        assert_eq!(full.direction(), Direction::Full);
        assert_eq!(full.fraction(), 8);

        let lower_half = classify('\u{2584}').unwrap();
        assert_eq!(lower_half.direction(), Direction::Down);
        assert_eq!(lower_half.fraction(), 4);

        let left_eighth = classify('\u{258F}').unwrap();
        assert_eq!(left_eighth.direction(), Direction::Left);
        assert_eq!(left_eighth.fraction(), 1);
    }

    #[test]
    fn classifies_shade_levels_distinctly() {
        let light = classify('\u{2591}').unwrap();
        let medium = classify('\u{2592}').unwrap();
        let dark = classify('\u{2593}').unwrap();
        assert_eq!(light.direction(), Direction::Shade);
        assert_eq!(medium.direction(), Direction::Shade);
        assert_eq!(dark.direction(), Direction::Shade);
        assert_eq!(light.fraction(), 1);
        assert_eq!(medium.fraction(), 2);
        assert_eq!(dark.fraction(), 3);
        assert_ne!(light, medium);
        assert_ne!(medium, dark);
    }

    #[test]
    fn classifies_quadrant_glyphs_as_a_bitmask() {
        let upper_left = classify('\u{2598}').unwrap();
        assert_eq!(upper_left.direction(), Direction::Quadrant);
        assert_eq!(upper_left.fraction(), 0b0001);

        let three_quadrants = classify('\u{2599}').unwrap(); // ▙
        assert_eq!(three_quadrants.fraction(), 0b1101);
    }

    #[test]
    fn classifies_diagonals() {
        let forward = classify('\u{2571}').unwrap(); // ╱
        assert!(forward.is_diagonal());
        assert_eq!(forward.diagonal(), (true, false));

        let backward = classify('\u{2572}').unwrap(); // ╲
        assert_eq!(backward.diagonal(), (false, true));

        let cross = classify('\u{2573}').unwrap(); // ╳
        assert_eq!(cross.diagonal(), (true, true));

        // A diagonal has no edges at all — the two representations never overlap.
        for edge in [Edge::Up, Edge::Down, Edge::Left, Edge::Right] {
            assert_eq!(forward.edge(edge), Weight::None);
        }
        assert!(!forward.is_arc());
    }

    #[test]
    fn classifies_stub_lines_as_single_edge_lines() {
        let left = classify('\u{2574}').unwrap(); // ╴ light left
        assert!(!left.is_diagonal());
        assert_eq!(left.edge(Edge::Left), Weight::Light);
        assert_eq!(left.edge(Edge::Right), Weight::None);
        assert_eq!(left.edge(Edge::Up), Weight::None);
        assert_eq!(left.edge(Edge::Down), Weight::None);

        let mixed = classify('\u{257C}').unwrap(); // ╼ light left, heavy right
        assert_eq!(mixed.edge(Edge::Left), Weight::Light);
        assert_eq!(mixed.edge(Edge::Right), Weight::Heavy);
    }
}
