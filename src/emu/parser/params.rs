//! Fixed size parameters list with optional subparameters.

use core::fmt::{self, Debug, Formatter};

pub(crate) const MAX_PARAMS: usize = 32;

#[derive(Default)]
pub struct Params {
    /// Number of subparameters for each parameter.
    ///
    /// For each entry in the `params` slice, this stores the length of the
    /// param as number of subparams at the same index as the param in the
    /// `params` slice.
    ///
    /// At the subparam positions the length will always be `0`.
    subparams: [u8; MAX_PARAMS],

    /// All parameters and subparameters.
    params: [u16; MAX_PARAMS],

    /// Number of suparameters in the current parameter.
    current_subparams: u8,

    /// Total number of parameters and subparameters.
    len: usize,
}

impl Params {
    /// Number of parameters *and* subparameters stored.
    ///
    /// Deliberately not the number of groups [`Params::iter`] yields: `38:2::1:2:3` is one
    /// parameter with five subparameters, so this is 6 and `iter().count()` is 1. Named
    /// `flat_len` rather than `len` because the two read as interchangeable otherwise, and
    /// a caller that wants the parameter count wants `iter`.
    #[inline]
    pub fn flat_len(&self) -> usize {
        self.len
    }

    /// Returns `true` if there are no parameters present.
    #[inline]
    pub fn is_empty(&self) -> bool {
        self.len == 0
    }

    /// Returns an iterator over all parameters and subparameters.
    #[inline]
    pub fn iter(&self) -> ParamsIter<'_> {
        ParamsIter::new(self)
    }

    /// Parameter `index`, defaulting to `fallback` when absent, empty or zero.
    ///
    /// The CSI convention in one place: a parameter that is omitted or written `0` means
    /// "use the default", so a caller never has to test for either. This was a free
    /// function in `term`, called at 37 sites with the `&Params` it belongs on.
    pub fn arg(&self, index: usize, fallback: usize) -> usize {
        self.iter()
            .nth(index)
            .and_then(|p| p.first().copied())
            .filter(|v| *v != 0)
            .map_or(fallback, usize::from)
    }

    /// Parameter `index` as a zero-based coordinate: [`Params::arg`] with a default of 1,
    /// less one.
    ///
    /// The rows and columns in a CSI are 1-based and the grid's are not, so nearly every
    /// positioning parameter needed this. Written out, it was `arg(params, 0, 1) - 1` and
    /// needed a comment arguing that the literal default made the subtraction safe; here
    /// the saturation is in the one place, and there is no argument to keep true.
    pub fn coord(&self, index: usize) -> usize {
        self.arg(index, 1).saturating_sub(1)
    }

    /// Returns `true` if there is no more space for additional parameters.
    #[inline]
    pub(crate) fn is_full(&self) -> bool {
        self.len == MAX_PARAMS
    }

    /// Clear all parameters.
    #[inline]
    pub(crate) fn clear(&mut self) {
        self.current_subparams = 0;
        self.len = 0;
    }

    /// Add an additional parameter.
    #[inline]
    pub(crate) fn push(&mut self, item: u16) {
        self.put(item, false);
    }

    /// Add an additional subparameter to the current parameter.
    #[inline]
    pub(crate) fn extend(&mut self, item: u16) {
        self.put(item, true);
    }

    /// Store `item`, either starting a parameter or continuing one.
    #[inline]
    fn put(&mut self, item: u16, subparam: bool) {
        self.subparams[self.len - self.current_subparams as usize] = self.current_subparams + 1;
        self.params[self.len] = item;
        self.current_subparams = if subparam {
            self.current_subparams + 1
        } else {
            0
        };
        self.len += 1;
    }
}

impl<'a> IntoIterator for &'a Params {
    type IntoIter = ParamsIter<'a>;
    type Item = &'a [u16];

    fn into_iter(self) -> Self::IntoIter {
        self.iter()
    }
}

/// Immutable subparameter iterator.
pub struct ParamsIter<'a> {
    params: &'a Params,
    index: usize,
}

impl<'a> ParamsIter<'a> {
    fn new(params: &'a Params) -> Self {
        Self { params, index: 0 }
    }
}

impl<'a> Iterator for ParamsIter<'a> {
    type Item = &'a [u16];

    fn next(&mut self) -> Option<Self::Item> {
        if self.index >= self.params.flat_len() {
            return None;
        }

        // Get all subparameters for the current parameter.
        let num_subparams = self.params.subparams[self.index];
        let param = &self.params.params[self.index..self.index + num_subparams as usize];

        // Jump to the next parameter.
        self.index += num_subparams as usize;

        Some(param)
    }

    fn size_hint(&self) -> (usize, Option<usize>) {
        let remaining = self.params.flat_len() - self.index;
        (remaining, Some(remaining))
    }
}

impl Debug for Params {
    fn fmt(&self, f: &mut Formatter<'_>) -> fmt::Result {
        write!(f, "[")?;

        for (i, param) in self.iter().enumerate() {
            if i != 0 {
                write!(f, ";")?;
            }

            for (i, subparam) in param.iter().enumerate() {
                if i != 0 {
                    write!(f, ":")?;
                }

                subparam.fmt(f)?;
            }
        }

        write!(f, "]")
    }
}
