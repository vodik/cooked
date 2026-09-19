//! The three units that meet at the seam, each with a type of its own.
//!
//! A terminal grid is measured in columns, an Emacs buffer in characters, and a `String`
//! in bytes, and the same row is a different number in each: `日本X` is five columns,
//! three characters and seven bytes. Every offset the core reports to Emacs is in
//! characters, every width is in columns, and [`Runs`](super::cell::Runs) indexes its own
//! text in bytes — so three numbers that must never be substituted for one another used
//! to share one type, `usize`.
//!
//! The one conversion between two of them is
//! [`chars_before`](super::cell::chars_before), which needs the row's cells to do its
//! work; nothing else here converts, because nothing else can. A number of one unit
//! therefore either stays that unit or passes through a named function, which is what
//! makes the seam's arithmetic checkable by the compiler rather than by a test named
//! after the last time it was got wrong.
//!
//! Each is a `#[repr(transparent)]` wrapper over `usize` with only same-unit arithmetic,
//! so the generated code is the code that was there before the wrapper.

/// Define one unit: a transparent `usize` that adds and subtracts only with itself.
///
/// The operations are deliberately few. There is no `Mul`, because a product of two
/// counts of the same unit is not a count of that unit; no `Add<usize>`, because a bare
/// number joining the arithmetic is how the units got mixed in the first place; and no
/// `From<usize>`, so that labelling a number costs a visible [`Chars::new`] at the point
/// where a reader can check the claim.
macro_rules! unit {
    ($(#[$attr:meta])* $vis:vis struct $name:ident;) => {
        $(#[$attr])*
        #[derive(Debug, Clone, Copy, Default, PartialEq, Eq, PartialOrd, Ord, Hash)]
        #[repr(transparent)]
        $vis struct $name(usize);

        const _: () = assert!(std::mem::size_of::<$name>() == std::mem::size_of::<usize>());

        #[allow(dead_code)]
        impl $name {
            $vis const ZERO: Self = Self(0);
            $vis const ONE: Self = Self(1);

            /// COUNT of this unit.
            ///
            /// The call is the claim: a reader checking that an offset is in the right
            /// unit looks here, so keep it next to whatever establishes the unit.
            $vis const fn new(count: usize) -> Self {
                Self(count)
            }

            /// The count itself, for indexing, comparing against a capacity, or crossing
            /// to Lisp.
            ///
            /// Not a conversion: it is the same quantity without its label, and adding it
            /// to another unit's count is the mistake this module exists to stop. Prefer a
            /// method that keeps the label where one will do.
            $vis const fn get(self) -> usize {
                self.0
            }

            /// This less RHS, or [`Self::ZERO`] if that is below zero.
            $vis const fn saturating_sub(self, rhs: Self) -> Self {
                Self(self.0.saturating_sub(rhs.0))
            }

            /// This less RHS, or `None` if that is below zero.
            $vis const fn checked_sub(self, rhs: Self) -> Option<Self> {
                match self.0.checked_sub(rhs.0) {
                    Some(count) => Some(Self(count)),
                    None => None,
                }
            }

            $vis const fn is_zero(self) -> bool {
                self.0 == 0
            }
        }

        impl std::ops::Add for $name {
            type Output = Self;

            fn add(self, rhs: Self) -> Self {
                Self(self.0 + rhs.0)
            }
        }

        impl std::ops::AddAssign for $name {
            fn add_assign(&mut self, rhs: Self) {
                self.0 += rhs.0;
            }
        }

        impl std::ops::Sub for $name {
            type Output = Self;

            fn sub(self, rhs: Self) -> Self {
                Self(self.0 - rhs.0)
            }
        }

        impl std::ops::SubAssign for $name {
            fn sub_assign(&mut self, rhs: Self) {
                self.0 -= rhs.0;
            }
        }

        impl std::iter::Sum for $name {
            fn sum<I: Iterator<Item = Self>>(iter: I) -> Self {
                iter.fold(Self::ZERO, std::ops::Add::add)
            }
        }

        impl std::fmt::Display for $name {
            fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
                self.0.fmt(f)
            }
        }

        /// The count, for a plist field or a list element; see [`Self::get`].
        impl<'e> $crate::env::IntoLisp<'e> for $name {
            fn into_lisp(
                self,
                env: &$crate::env::Env<'e>,
            ) -> $crate::env::Result<$crate::env::Value<'e>> {
                self.0.into_lisp(env)
            }
        }
    };
}

unit! {
    /// Characters of an Emacs buffer: what `point` counts, and the unit of every offset
    /// the core reports.
    ///
    /// One per cell that draws, plus one per combining mark riding a cell, and none for
    /// the second half of a wide character — so `日本X` is three of these across five
    /// columns, and `e\u{301}` is two across one. A newline Emacs holds between two rows
    /// is one as well, which is why [`Block`](crate::wire::Block)'s offsets count it.
    pub struct Chars;
}

unit! {
    /// Cells across the grid: what the child addresses and what a width is measured in.
    ///
    /// A wide character occupies two and a combining mark none, so this is the unit the
    /// width guard compares against Emacs' own idea of how wide a row is, and never an
    /// offset into buffer text.
    pub struct Cols;
}

unit! {
    /// UTF-8 bytes of a `String`, for the one place an offset indexes Rust's own storage
    /// rather than anything Emacs holds: [`Runs`](super::cell::Runs) keeps every run's
    /// text in one buffer and each run's start as a byte offset into it.
    pub struct Bytes;
}

impl Bytes {
    /// The bytes S occupies.
    pub(crate) fn of(s: &str) -> Self {
        Self(s.len())
    }
}

/// What the units guarantee at runtime, as opposed to what they guarantee at compile
/// time.
///
/// The compiler is the real test of this module: mixing two units, or adding a bare
/// number to one, does not compile, and nothing written here could catch that. What is
/// left to check is the two claims a reader has to take on trust -- that the wrappers are
/// free, and that the arithmetic they do allow is the arithmetic `usize` would have done.
#[cfg(test)]
mod tests {
    use super::*;

    /// Zero-cost, which is the whole reason these may be used on the print path: a
    /// `Chars` is a `usize` in registers and in a struct field, and a `Vec<Chars>` is a
    /// `Vec<usize>`.
    #[test]
    fn a_unit_is_laid_out_exactly_as_the_count_it_wraps() {
        assert_eq!(size_of::<Chars>(), size_of::<usize>());
        assert_eq!(align_of::<Chars>(), align_of::<usize>());
        assert_eq!(size_of::<Option<Cols>>(), size_of::<Option<usize>>());
        assert_eq!(size_of::<[Bytes; 4]>(), size_of::<[usize; 4]>());
    }

    #[test]
    fn same_unit_arithmetic_is_the_arithmetic_of_the_counts() {
        let (five, three) = (Chars::new(5), Chars::new(3));
        assert_eq!((five + three).get(), 8);
        assert_eq!((five - three).get(), 2);
        assert_eq!(three.saturating_sub(five), Chars::ZERO);
        assert_eq!(five.checked_sub(three), Some(Chars::new(2)));
        assert_eq!(five.checked_sub(Chars::new(6)), None);
        let mut running = Chars::ZERO;
        running += five;
        running -= Chars::ONE;
        assert_eq!(running.get(), 4);
        assert_eq!([five, three].into_iter().sum::<Chars>().get(), 8);
        assert!(Chars::ZERO.is_zero() && !Chars::ONE.is_zero());
        assert!(three < five && five.min(three) == three);
    }

    /// The bytes of a string are not its characters, which is the distinction `Bytes`
    /// exists to keep: `Runs` indexes its own text by the first and reports the second.
    #[test]
    fn the_bytes_of_a_string_are_not_its_characters() {
        assert_eq!(Bytes::of("日本X"), Bytes::new(7));
        assert_eq!(Bytes::of(""), Bytes::ZERO);
    }
}
