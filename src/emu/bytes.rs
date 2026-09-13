//! Small operations on the raw bytes that escape sequences carry.

/// The byte two ASCII hex digits spell, either case, or `None` if either is not one.
pub(crate) fn hex_byte(hi: u8, lo: u8) -> Option<u8> {
    let digit = |b: u8| (b as char).to_digit(16);
    // Two digits below 16 make at most 255, so the narrowing cannot lose anything.
    Some((digit(hi)? * 16 + digit(lo)?) as u8)
}

/// Append as much of BYTES to BUF as keeps BUF within LIMIT, returning whether any of
/// BYTES was left out.
///
/// For a string sequence collected across reads, where a child chooses the length. What
/// the caller does with an overrun differs -- a sixel keeps the top of its picture, an
/// XTGETTCAP request cuts back to its last whole name -- so this only reports it.
pub(crate) fn extend_bounded(buf: &mut Vec<u8>, bytes: &[u8], limit: usize) -> bool {
    let room = limit.saturating_sub(buf.len());
    let taken = bytes.len().min(room);
    buf.extend_from_slice(&bytes[..taken]);
    taken < bytes.len()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn hex_byte_reads_either_case_and_refuses_anything_else() {
        assert_eq!(hex_byte(b'5', b'4'), Some(0x54));
        assert_eq!(hex_byte(b'f', b'F'), Some(0xff));
        assert_eq!(hex_byte(b'g', b'0'), None);
    }

    #[test]
    fn extend_bounded_stops_at_the_limit_and_says_so() {
        let mut buf = b"ab".to_vec();
        assert!(!extend_bounded(&mut buf, b"cd", 4));
        assert!(extend_bounded(&mut buf, b"ef", 5));
        assert_eq!(buf, b"abcde");
        assert!(extend_bounded(&mut buf, b"g", 5));
        assert_eq!(buf, b"abcde");
    }
}
