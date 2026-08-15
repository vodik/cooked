//! Hand-rolled bindings to the Emacs 28+ dynamic module ABI.
//!
//! Only the slots we use are typed; the rest are pointer-sized placeholders that
//! preserve `struct emacs_env_28`'s layout — the mirror ends at `make_unibyte_string`,
//! so that is as far as we may claim. A newer Emacs is fine, because the contract is
//! append-only and [`Env::REQUIRED_ABI`] only asks for at least our own size; an older
//! one is refused at load time rather than dereferenced past the end.
//!
//! Every entry point funnels through [`trampoline`], which converts panics and
//! [`Error`]s into Lisp signals so that nothing unwinds across the FFI boundary.

use std::ffi::{CString, c_char, c_int, c_void};
use std::marker::PhantomData;
use std::os::fd::RawFd;
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

#[repr(C)]
pub struct ValueTag {
    _opaque: [u8; 0],
}

/// An opaque handle to a Lisp object. Transparent over the pointer Emacs hands us, but a
/// distinct type so it cannot be dereferenced or confused with a real pointer.
#[repr(transparent)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Value(*mut ValueTag);

impl Value {
    const NULL: Self = Self(std::ptr::null_mut());
}

type Slot = *const c_void;

/// A pending non-local exit (signal or throw) on the Emacs side.
#[derive(Debug, Clone, Copy)]
pub struct Error;

pub type Result<T> = std::result::Result<T, Error>;

#[repr(C)]
pub struct Runtime {
    size: isize,
    private: *mut c_void,
    get_environment: unsafe extern "C" fn(*mut Runtime) -> *mut Raw,
}

impl Runtime {
    /// # Safety
    /// `self` must be the runtime handed to `emacs_module_init`.
    pub unsafe fn env(&mut self) -> Env<'_> {
        unsafe { Env::from_raw((self.get_environment)(self)) }
    }

    /// Whether the runtime is at least as large as the layout we mirror.
    ///
    /// Safe to ask unconditionally: `size` is the first member of every version of the
    /// struct, which is the entire point of it being there.
    pub fn compatible(&self) -> bool {
        self.size >= size_of::<Self>() as isize
    }
}

type FnPtr = unsafe extern "C" fn(*mut Raw, isize, *mut Value, *mut c_void) -> Value;

#[repr(C)]
pub struct Raw {
    size: isize,
    private: *mut c_void,
    make_global_ref: unsafe extern "C" fn(*mut Raw, Value) -> Value,
    free_global_ref: unsafe extern "C" fn(*mut Raw, Value),
    non_local_exit_check: unsafe extern "C" fn(*mut Raw) -> c_int,
    non_local_exit_clear: unsafe extern "C" fn(*mut Raw),
    non_local_exit_get: unsafe extern "C" fn(*mut Raw, *mut Value, *mut Value) -> c_int,
    non_local_exit_signal: unsafe extern "C" fn(*mut Raw, Value, Value),
    non_local_exit_throw: unsafe extern "C" fn(*mut Raw, Value, Value),
    make_function:
        unsafe extern "C" fn(*mut Raw, isize, isize, FnPtr, *const c_char, *mut c_void) -> Value,
    funcall: unsafe extern "C" fn(*mut Raw, Value, isize, *const Value) -> Value,
    intern: unsafe extern "C" fn(*mut Raw, *const c_char) -> Value,
    type_of: Slot,
    is_not_nil: unsafe extern "C" fn(*mut Raw, Value) -> bool,
    eq: unsafe extern "C" fn(*mut Raw, Value, Value) -> bool,
    extract_integer: unsafe extern "C" fn(*mut Raw, Value) -> i64,
    make_integer: unsafe extern "C" fn(*mut Raw, i64) -> Value,
    extract_float: Slot,
    make_float: Slot,
    copy_string_contents: unsafe extern "C" fn(*mut Raw, Value, *mut c_char, *mut isize) -> bool,
    make_string: unsafe extern "C" fn(*mut Raw, *const c_char, isize) -> Value,
    make_user_ptr: unsafe extern "C" fn(*mut Raw, Option<Finalizer>, *mut c_void) -> Value,
    get_user_ptr: unsafe extern "C" fn(*mut Raw, Value) -> *mut c_void,
    set_user_ptr: Slot,
    get_user_finalizer: unsafe extern "C" fn(*mut Raw, Value) -> Option<Finalizer>,
    set_user_finalizer: Slot,
    vec_get: Slot,
    vec_set: Slot,
    vec_size: Slot,
    should_quit: unsafe extern "C" fn(*mut Raw) -> bool,
    process_input: Slot,
    extract_time: Slot,
    make_time: Slot,
    extract_big_integer: Slot,
    make_big_integer: Slot,
    get_function_finalizer: Slot,
    set_function_finalizer: Slot,
    open_channel: unsafe extern "C" fn(*mut Raw, Value) -> c_int,
    make_interactive: Slot,
    make_unibyte_string: unsafe extern "C" fn(*mut Raw, *const c_char, isize) -> Value,
}

/// A borrowed Emacs environment. Valid only for the duration of one module call.
#[derive(Clone, Copy)]
pub struct Env<'e> {
    raw: *mut Raw,
    _life: PhantomData<&'e mut Raw>,
}

macro_rules! ffi {
    ($env:expr, $slot:ident $(, $arg:expr)* $(,)?) => {{
        let raw = $env.raw;
        let ret = unsafe { ((*raw).$slot)(raw $(, $arg)*) };
        $env.check().map(|()| ret)
    }};
}

impl<'e> Env<'e> {
    /// # Safety
    /// `raw` must be a live environment for the current module call.
    pub unsafe fn from_raw(raw: *mut Raw) -> Self {
        Self {
            raw,
            _life: PhantomData,
        }
    }

    fn check(&self) -> Result<()> {
        match unsafe { ((*self.raw).non_local_exit_check)(self.raw) } {
            0 => Ok(()),
            _ => Err(Error),
        }
    }

    pub fn intern(&self, name: &str) -> Result<Value> {
        let c = CString::new(name).map_err(|_| Error)?;
        ffi!(self, intern, c.as_ptr())
    }

    pub fn nil(&self) -> Value {
        self.intern("nil").unwrap_or(Value::NULL)
    }

    pub fn is_nil(&self, v: Value) -> bool {
        !unsafe { ((*self.raw).is_not_nil)(self.raw, v) }
    }

    pub fn eq(&self, a: Value, b: Value) -> bool {
        unsafe { ((*self.raw).eq)(self.raw, a, b) }
    }

    pub fn call(&self, func: &str, args: &[Value]) -> Result<Value> {
        let f = self.intern(func)?;
        ffi!(self, funcall, f, args.len() as isize, args.as_ptr())
    }

    pub fn list(&self, items: &[Value]) -> Result<Value> {
        self.call("list", items)
    }

    pub fn cons(&self, car: Value, cdr: Value) -> Result<Value> {
        self.call("cons", &[car, cdr])
    }

    /// Wrap `data` in an opaque Lisp user-pointer; Emacs' GC runs the destructor.
    pub fn user_ptr<T>(&self, data: T) -> Result<Value> {
        let boxed = Box::into_raw(Box::new(data)).cast::<c_void>();
        ffi!(self, make_user_ptr, Some(finalizer_of::<T>()), boxed).inspect_err(|_| {
            drop(unsafe { Box::from_raw(boxed.cast::<T>()) });
        })
    }

    /// Borrow a user-pointer *this module* created for `T`.
    ///
    /// Emacs signals for a value that is not a user-pointer at all, but it has no notion
    /// of what kind of thing a user-pointer holds — so without this check, handing
    /// `cooked--send` a user-pointer from some other dynamic module would reinterpret that
    /// module's memory as a `T`. The finalizer is the only identity Emacs carries, so it
    /// is the tag.
    pub fn get_user_ptr<T>(&self, v: Value) -> Result<&'e T> {
        // Propagate first: for a non-user-ptr this is already a pending
        // `wrong-type-argument`, which must not be overwritten with ours.
        //
        // `fn_addr_eq` rather than `==` because comparing function pointers is only as
        // meaningful as the guarantee that the two cannot be folded together — see
        // [`finalize`] for why they cannot be here. Note this only has to distinguish our
        // finalizer from *another module's*, and those live in a different shared object,
        // so nothing could fold them even in principle.
        let ours = ffi!(self, get_user_finalizer, v)?
            .is_some_and(|f| std::ptr::fn_addr_eq(f, finalizer_of::<T>()));
        if !ours {
            return Err(self.signal_wrong_type("cooked-session-p", v));
        }
        let p = ffi!(self, get_user_ptr, v)?;
        unsafe { p.cast::<T>().as_ref() }.ok_or(Error)
    }

    /// Writable file descriptor for a `make-pipe-process`; safe to use off-thread.
    pub fn open_channel(&self, pipe_process: Value) -> Result<RawFd> {
        ffi!(self, open_channel, pipe_process)
    }

    pub fn should_quit(&self) -> bool {
        unsafe { ((*self.raw).should_quit)(self.raw) }
    }

    pub fn signal(&self, symbol: &str, message: &str) -> Error {
        let build = || -> Result<(Value, Value)> {
            Ok((
                self.intern(symbol)?,
                self.list(&[message.into_lisp(self)?])?,
            ))
        };
        if let Ok((sym, data)) = build() {
            unsafe { ((*self.raw).non_local_exit_signal)(self.raw, sym, data) };
        }
        Error
    }

    /// `wrong-type-argument`, whose conventional data is `(PREDICATE VALUE)`.
    pub fn signal_wrong_type(&self, predicate: &str, value: Value) -> Error {
        let build = || -> Result<(Value, Value)> {
            Ok((
                self.intern("wrong-type-argument")?,
                self.list(&[self.intern(predicate)?, value])?,
            ))
        };
        if let Ok((sym, data)) = build() {
            unsafe { ((*self.raw).non_local_exit_signal)(self.raw, sym, data) };
        }
        Error
    }

    /// Size Emacs reports for its own `emacs_env`.
    pub fn abi_size(&self) -> isize {
        unsafe { (*self.raw).size }
    }

    /// What our [`Raw`] mirror needs to be safe to call through: the Emacs 28 layout.
    pub const REQUIRED_ABI: isize = size_of::<Raw>() as isize;

    /// The Emacs 25 prefix — enough to intern, funcall and signal, so a too-old Emacs can
    /// be told why it is being refused rather than only handed a number.
    pub const MINIMAL_ABI: isize = std::mem::offset_of!(Raw, should_quit) as isize;

    pub fn into_lisp<T: IntoLisp>(&self, v: T) -> Result<Value> {
        v.into_lisp(self)
    }

    pub fn from_lisp<T: FromLisp>(&self, v: Value) -> Result<T> {
        T::from_lisp(self, v)
    }

    /// Register `f` as the Lisp function `name`.
    pub fn defun(
        &self,
        name: &str,
        arity: std::ops::RangeInclusive<isize>,
        doc: &str,
        f: Defun,
    ) -> Result<()> {
        let doc = CString::new(doc).map_err(|_| Error)?;
        let func = ffi!(
            self,
            make_function,
            *arity.start(),
            *arity.end(),
            trampoline,
            doc.as_ptr(),
            f as *mut c_void,
        )?;
        self.call("defalias", &[self.intern(name)?, func]).map(drop)
    }
}

pub type Defun = fn(Env, &[Value]) -> Result<Value>;

type Finalizer = extern "C" fn(*mut c_void);

extern "C" fn finalize<T>(p: *mut c_void) {
    // `type_name` is load-bearing, not decoration. Identical-code-folding may merge two
    // monomorphisations whose bodies are byte-identical — and for two `Drop`-free types
    // of the same size, `Box::from_raw` plus drop glue is exactly that. Merging them
    // would collapse the distinct addresses `get_user_ptr` relies on, turning the type
    // tag back into the confusion it exists to prevent. One dead load, once per session.
    let _ = std::hint::black_box(std::any::type_name::<T>());
    drop(unsafe { Box::from_raw(p.cast::<T>()) });
}

/// The address identifying user-pointers this module made for `T`.
const fn finalizer_of<T>() -> Finalizer {
    finalize::<T>
}

unsafe extern "C" fn trampoline(
    raw: *mut Raw,
    n: isize,
    args: *mut Value,
    data: *mut c_void,
) -> Value {
    let env = unsafe { Env::from_raw(raw) };
    let f: Defun = unsafe { std::mem::transmute(data) };
    let args = match n {
        0 => &[][..],
        n => unsafe { slice::from_raw_parts(args, n as usize) },
    };
    match catch_unwind(AssertUnwindSafe(|| f(env, args))) {
        Ok(Ok(v)) => v,
        Ok(Err(Error)) => env.nil(),
        Err(panic) => {
            let msg = panic
                .downcast_ref::<&str>()
                .map(|s| (*s).to_owned())
                .or_else(|| panic.downcast_ref::<String>().cloned())
                .unwrap_or_else(|| "panic".to_owned());
            env.signal("cooked-panic", &msg);
            env.nil()
        }
    }
}

pub trait IntoLisp {
    fn into_lisp(self, env: &Env) -> Result<Value>;
}

pub trait FromLisp: Sized {
    fn from_lisp(env: &Env, v: Value) -> Result<Self>;
}

impl IntoLisp for Value {
    fn into_lisp(self, _: &Env) -> Result<Value> {
        Ok(self)
    }
}

impl IntoLisp for i64 {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        ffi!(env, make_integer, self)
    }
}

impl IntoLisp for usize {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        (self as i64).into_lisp(env)
    }
}

impl IntoLisp for u32 {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        i64::from(self).into_lisp(env)
    }
}

impl IntoLisp for bool {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        if self { env.intern("t") } else { Ok(env.nil()) }
    }
}

impl IntoLisp for &str {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        ffi!(env, make_string, self.as_ptr().cast(), self.len() as isize)
    }
}

impl IntoLisp for String {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        self.as_str().into_lisp(env)
    }
}

/// Byte strings become unibyte Lisp strings — no decoding, no corruption.
impl IntoLisp for &[u8] {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        ffi!(
            env,
            make_unibyte_string,
            self.as_ptr().cast(),
            self.len() as isize
        )
    }
}

impl<T: IntoLisp> IntoLisp for Option<T> {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        self.map_or_else(|| Ok(env.nil()), |v| v.into_lisp(env))
    }
}

impl<T: IntoLisp> IntoLisp for Vec<T> {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        let items = self
            .into_iter()
            .map(|v| v.into_lisp(env))
            .collect::<Result<Vec<_>>>()?;
        env.list(&items)
    }
}

impl IntoLisp for () {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        Ok(env.nil())
    }
}

impl FromLisp for i64 {
    fn from_lisp(env: &Env, v: Value) -> Result<Self> {
        ffi!(env, extract_integer, v)
    }
}

impl FromLisp for usize {
    fn from_lisp(env: &Env, v: Value) -> Result<Self> {
        i64::from_lisp(env, v)?
            .try_into()
            .map_err(|_| env.signal("args-out-of-range", "negative"))
    }
}

impl FromLisp for u16 {
    fn from_lisp(env: &Env, v: Value) -> Result<Self> {
        i64::from_lisp(env, v)?
            .try_into()
            .map_err(|_| env.signal("args-out-of-range", "not a u16"))
    }
}

impl FromLisp for bool {
    fn from_lisp(env: &Env, v: Value) -> Result<Self> {
        Ok(!env.is_nil(v))
    }
}

impl FromLisp for Vec<u8> {
    fn from_lisp(env: &Env, v: Value) -> Result<Self> {
        let mut len = 0isize;
        ffi!(
            env,
            copy_string_contents,
            v,
            std::ptr::null_mut(),
            &raw mut len
        )?;
        let mut buf = vec![0u8; len as usize];
        ffi!(
            env,
            copy_string_contents,
            v,
            buf.as_mut_ptr().cast(),
            &raw mut len
        )?;
        buf.pop();
        Ok(buf)
    }
}

impl FromLisp for String {
    fn from_lisp(env: &Env, v: Value) -> Result<Self> {
        String::from_utf8(Vec::from_lisp(env, v)?)
            .map_err(|_| env.signal("wrong-type-argument", "invalid utf-8"))
    }
}

impl<T: FromLisp> FromLisp for Option<T> {
    fn from_lisp(env: &Env, v: Value) -> Result<Self> {
        if env.is_nil(v) {
            Ok(None)
        } else {
            T::from_lisp(env, v).map(Some)
        }
    }
}

/// Declare that this module is GPL-compatible, as Emacs requires.
#[unsafe(no_mangle)]
pub static plugin_is_GPL_compatible: c_int = 1;

pub(crate) fn provide(env: &Env, feature: &str) -> Result<()> {
    let sym = env.intern(feature)?;
    env.call("provide", &[sym]).map(drop)
}

#[cfg(test)]
mod tests {
    use super::*;

    struct Dummy;

    #[test]
    fn each_type_gets_its_own_finalizer() {
        // The whole user-pointer type check rests on this. Two `Drop`-free types are
        // exactly the case identical-code-folding would merge, so assert it under the
        // release profile too — that is where it would bite.
        assert!(!std::ptr::fn_addr_eq(
            finalizer_of::<Dummy>(),
            finalizer_of::<u64>()
        ));
        assert!(std::ptr::fn_addr_eq(
            finalizer_of::<Dummy>(),
            finalizer_of::<Dummy>()
        ));
    }

    #[test]
    fn the_abi_prefix_is_ordered() {
        assert!(Env::MINIMAL_ABI > 0);
        assert!(Env::MINIMAL_ABI < Env::REQUIRED_ABI);
        assert_eq!(Env::REQUIRED_ABI as usize, size_of::<Raw>());
    }
}
