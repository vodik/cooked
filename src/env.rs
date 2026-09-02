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
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

#[repr(C)]
pub(crate) struct ValueTag {
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

pub(crate) type Result<T> = std::result::Result<T, Error>;

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

/// A symbol from the load-time table, named by the spelling it has in Lisp.
///
/// [`Env::intern`] costs a `CString` allocation, an FFI call and the
/// `non_local_exit_check` every [`ffi!`] does after it. That is the cost [`symbols!`]
/// exists to remove, and this is how a call site reaches the table without naming a
/// [`Sym`] variant -- so a symbol goes on being written as the word it is in Lisp.
///
/// The lookup is a `const` item, so a name missing from the table stops the build with
/// [`sym_index`]'s message rather than degrading to an `intern` nobody notices.
macro_rules! sym {
    ($env:expr, $name:literal) => {{
        const I: usize = $crate::env::sym_index($name);
        $env.sym_at(I)
    }};
}
pub(crate) use sym;

/// Generate [`IntoLisp`] for enums whose Lisp face is a symbol.
///
/// Each of these had a `fn as_str(self) -> &'static str` beside the enum and an
/// `env.intern(x.as_str())` at the boundary, which put the naming in the wrong place
/// twice over. The spelling is a fact about what crosses into Lisp, not about the
/// emulator, and interning it per drain is the cost [`symbols!`] exists to remove -- but
/// the enums live in `emu` and `pty`, which are plain Rust with no [`Env`] in sight and
/// no business naming a [`Sym`].
///
/// So the list moves to the boundary, where it is invoked once and generates both. There
/// is still exactly one spelling of each name; it is now in the module that sends it, and
/// on the symbol table like every other symbol.
macro_rules! lisp_enum {
    ($( $(#[doc = $doc:literal])* $t:ty { $($variant:ident => $name:literal),* $(,)? } )*) => {
        $($(#[doc = $doc])*
        impl $crate::env::IntoLisp for $t {
            fn into_lisp(self, env: &$crate::env::Env) -> $crate::env::Result<$crate::env::Value> {
                match self {
                    $(Self::$variant => $crate::env::sym!(env, $name)),*
                }
            }
        })*
    };
}
pub(crate) use lisp_enum;

/// Build a Lisp list, converting each element on the way.
///
/// The alternative is `env.list(&[..])` over an array the caller has already converted,
/// which is what this replaces: there every element carries its own `env.into_lisp(..)?`,
/// and the six that say something are read out of forty that do not.
///
/// Elements are anything [`IntoLisp`], which includes [`Value`] itself -- so a field that
/// had to be built beforehand sits in the same list as one converted in place.
///
/// Expands to an expression of `Result<Value>`, and the conversions use `?`, so it must
/// be written inside a function returning [`Result`].
macro_rules! list {
    ($env:expr, [ $($item:expr),* $(,)? ]) => {{
        // Annotated rather than inferred, so the two spellings of the same argument --
        // `env` and `&env`, both of which autoref their way to the same methods -- cannot
        // both compile. One shape, checked.
        let env: $crate::env::Env<'_> = $env;
        let items = [ $( env.into_lisp($item)? ),* ];
        env.list(&items)
    }};
}
pub(crate) use list;

/// Build a Lisp plist, written the way it reads on the other side.
///
/// [`list!`] with the keys interleaved, which is the whole difference: there the pairing
/// is a convention a flat array cannot enforce, so dropping one element shifts every key
/// onto the wrong value and nothing says so until Lisp reads it. Here a key without a
/// value does not parse.
///
/// Keys go through [`sym!`], so they cost an array index rather than an `intern` and a
/// key that is not in the symbol table stops the build.
macro_rules! plist {
    ($env:expr, { $($key:literal => $val:expr),* $(,)? }) => {{
        let env: $crate::env::Env<'_> = $env;
        $crate::env::list!(env, [ $( $crate::env::sym!(env, $key)?, $val ),* ])
    }};
}
pub(crate) use plist;

/// Symbols this module interns once, at load, and holds for the process' life.
///
/// `Env::intern` costs a `CString` allocation and two FFI calls -- the `intern` itself
/// and the `non_local_exit_check` every `ffi!` does after it. `list`, `cons` and `nil`
/// re-interned their own names on *every* call, and a drain makes tens of thousands of
/// them, so the name lookup dominated the work of building the reply.
macro_rules! symbols {
    ($($variant:ident => $name:literal),* $(,)?) => {
        /// A symbol resolved by array index rather than by interning.
        #[derive(Clone, Copy)]
        #[repr(usize)]
        pub enum Sym { $($variant),* }

        impl Sym {
            /// Indexed by the discriminant, so the two cannot drift: both come from the
            /// one list above.
            const NAMES: &'static [&'static str] = &[$($name),*];
        }
        // Most variants are never written as `Sym::Something`. They are here to give
        // their string a slot in `NAMES`, which `sym_index` searches by spelling on
        // behalf of `plist!` -- one table, reached two ways, rather than two tables whose
        // indices could disagree.
    };
}

symbols! {
    List => "list",
    Cons => "cons",
    Nil => "nil",
    T => "t",
    // The list walk in `lib.rs` calls these once per element of the environment alist,
    // which is the child's to grow.
    Car => "car",
    Cdr => "cdr",
    // Every `plist!` key in the module. They are interned once each here instead of once
    // each per drain, which is where fifteen of them were being rebuilt sixty times a
    // second. `sym_index` makes leaving one out a compile error rather than a silent
    // fallback, so this list cannot quietly fall behind the call sites.
    Scrolled => ":scrolled",
    Rows => ":rows",
    Height => ":height",
    Used => ":used",
    Head => ":head",
    Cursor => ":cursor",
    Marks => ":marks",
    Alt => ":alt",
    AppCursor => ":app-cursor",
    Keys => ":keys",
    Mode => ":mode",
    Images => ":images",
    Links => ":links",
    Events => ":events",
    Exit => ":exit",
    Intr => ":intr",
    Quit => ":quit",
    Susp => ":susp",
    Eof => ":eof",
    Isig => ":isig",
    // Every remaining symbol `lib.rs` writes as a literal, for the same reason the keys
    // above are here. The two deco kinds are the sharpest case: they were interned once
    // per decorated run of every damaged row of every frame, which is the per-character
    // consing `Deco` is packed to avoid, paid per run instead.
    Glyph => "glyph",
    Image => "image",
    // How an `Anchor` is spelled: a character offset into this drain's scrollback, or a
    // cell on the live grid.
    AtScrolled => "scrolled",
    AtScreen => "screen",
    // The event tags. One per event of every drain that has any.
    Bell => "bell",
    Osc => "osc",
    Mouse => "mouse",
    Reply => "reply",
    EraseScrollback => "erase-scrollback",
    DisplayCleared => "display-cleared",
    TitleStack => "title-stack",
    PromptStart => "prompt-start",
    PromptContinuation => "prompt-continuation",
    PromptEnd => "prompt-end",
    CommandStart => "command-start",
    CommandEnd => "command-end",
    // The `lisp_enum!` names. Each was interned from an `as_str` once per drain -- the
    // cursor shape, the key encoding and the line-discipline mode on every one, the
    // image format on every image transmitted.
    Cooked => "cooked",
    Raw => "raw",
    Secret => "secret",
    Block => "block",
    Underline => "underline",
    Bar => "bar",
    Legacy => "legacy",
    ModifyOtherKeys => "modify-other",
    Kitty => "kitty",
    Png => "png",
    Jpeg => "jpeg",
    Gif => "gif",
    // `pbm', not `ppm': it is the name of the Emacs image type that reads binary P6, and
    // that is what this string is for.
    Pbm => "pbm",
}

/// `a == b` for `&str`, in a const context.
const fn str_eq(a: &str, b: &str) -> bool {
    let (a, b) = (a.as_bytes(), b.as_bytes());
    if a.len() != b.len() {
        return false;
    }
    let mut i = 0;
    while i < a.len() {
        if a[i] != b[i] {
            return false;
        }
        i += 1;
    }
    true
}

/// Where `name` sits in [`Sym::NAMES`], resolved at compile time.
///
/// This is what lets [`sym!`] and [`plist!`] go on being written with the spelling they
/// put on the wire -- `":rows"`, matching the `(plist-get update :rows)` on the Lisp
/// side; `"prompt-start"`, matching the symbol Lisp dispatches the event on -- while
/// costing an array index rather than an `intern`. The `panic!` is in a `const` context,
/// so a name missing from the table above fails the build with that message pointing at
/// the call site; it can never degrade to a slow path nobody notices.
pub(crate) const fn sym_index(name: &str) -> usize {
    let mut i = 0;
    while i < Sym::NAMES.len() {
        if str_eq(Sym::NAMES[i], name) {
            return i;
        }
        i += 1;
    }
    panic!("this symbol is missing from `symbols!` in env.rs; add it there")
}

/// The interned symbols, as global references.
struct Symbols([Value; Sym::NAMES.len()]);

/// SAFETY: `Value` is a raw pointer, so `Symbols` is neither `Send` nor `Sync` on its
/// own, and a `static OnceLock<T>` needs both. Each is sound here for its own reason.
///
/// `Sync` -- shared reads from several threads -- because there is only ever one thread
/// that reads it. The table is *written* exactly once, inside `emacs_module_init`, before
/// any defun exists to be called and before this module has started a thread of its own,
/// with `OnceLock` providing the publication barrier. It is *read* only through
/// [`Env::sym`], and an `Env` is only ever held by the thread Emacs calls module
/// functions on -- which is why [`Env::from_raw`] is `unsafe` in the first place. cooked's
/// one background thread, `session.rs`'s reader, never touches Lisp at all: it parses
/// into a shared `Term` and writes a byte to a pipe, and has no `Env` to reach this with.
///
/// `Send` -- transfer to another thread -- because the only thing transfer could do to a
/// type that is otherwise never touched off the main thread is drop it somewhere
/// unexpected, and `Symbols` is a plain array of pointers with no `Drop`. Living in a
/// `static`, it is never dropped at all.
///
/// Neither claim licenses *calling* Emacs off the main thread. They cover holding the
/// symbols; using one still requires an `Env`, whose own contract is what keeps that
/// honest.
unsafe impl Sync for Symbols {}
unsafe impl Send for Symbols {}

/// Never freed, and that is deliberate rather than an omission: Emacs does not unload a
/// dynamic module, so these references are live for the process' lifetime by
/// construction and there is no teardown hook to release them from. It is a bounded leak
/// of one pointer per name above.
static SYMBOLS: std::sync::OnceLock<Symbols> = std::sync::OnceLock::new();

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

    /// A symbol from the load-time table; no allocation and no FFI call.
    ///
    /// Falls back to interning if the table is somehow not populated. That cannot happen
    /// through any path a user can reach -- `emacs_module_init` fills it before it
    /// registers a single defun -- but the fallback is one line and costs nothing on the
    /// path that matters, and the alternative is a panic in FFI code.
    pub fn sym(&self, s: Sym) -> Result<Value> {
        self.sym_at(s as usize)
    }

    /// [`Env::sym`] by raw index, for [`plist!`]'s compile-time lookup.
    pub fn sym_at(&self, index: usize) -> Result<Value> {
        match SYMBOLS.get() {
            Some(table) => Ok(table.0[index]),
            None => self.intern(Sym::NAMES[index]),
        }
    }

    /// Promote a value to one that outlives the call that produced it.
    fn global_ref(&self, v: Value) -> Result<Value> {
        ffi!(self, make_global_ref, v)
    }

    /// Fill [`SYMBOLS`]. Called once, from `emacs_module_init`.
    ///
    /// A second `module-load` of the same file runs `emacs_module_init` again and finds
    /// the table already set. Ignoring that is correct rather than merely tolerable: one
    /// process is one Emacs with one obarray, so the symbols already in the table name
    /// the very same objects a re-intern would find.
    pub fn intern_symbols(&self) -> Result<()> {
        let mut table = [Value::NULL; Sym::NAMES.len()];
        for (slot, name) in table.iter_mut().zip(Sym::NAMES) {
            *slot = self.global_ref(self.intern(name)?)?;
        }
        let _ = SYMBOLS.set(Symbols(table));
        Ok(())
    }

    pub fn nil(&self) -> Value {
        self.sym(Sym::Nil).unwrap_or(Value::NULL)
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

    /// [`Env::call`] for a function named in the symbol table, which is every function
    /// this module calls often enough for the name lookup to show.
    fn call_sym(&self, func: Sym, args: &[Value]) -> Result<Value> {
        let f = self.sym(func)?;
        ffi!(self, funcall, f, args.len() as isize, args.as_ptr())
    }

    pub fn list(&self, items: &[Value]) -> Result<Value> {
        self.call_sym(Sym::List, items)
    }

    pub fn cons(&self, car: Value, cdr: Value) -> Result<Value> {
        self.call_sym(Sym::Cons, &[car, cdr])
    }

    pub fn car(&self, cell: Value) -> Result<Value> {
        self.call_sym(Sym::Car, &[cell])
    }

    pub fn cdr(&self, cell: Value) -> Result<Value> {
        self.call_sym(Sym::Cdr, &[cell])
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
    /// The write end of a pipe process' channel, owned.
    ///
    /// Emacs hands over a descriptor that is ours to close, so this returns the type that
    /// says so. The `unsafe` sits three lines from the FFI call that establishes the
    /// contract, rather than at a caller who has to be told about it -- which is what
    /// leaves `session.rs` with no `unsafe` at all outside its tests.
    pub fn open_channel(&self, pipe_process: Value) -> Result<OwnedFd> {
        let raw: RawFd = ffi!(self, open_channel, pipe_process)?;
        // SAFETY: `open_channel` returns a descriptor the module owns and must close.
        Ok(unsafe { OwnedFd::from_raw_fd(raw) })
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

    #[allow(clippy::wrong_self_convention, reason = "converts `v`, not `self`")]
    pub fn into_lisp<T: IntoLisp>(&self, v: T) -> Result<Value> {
        v.into_lisp(self)
    }

    #[allow(clippy::wrong_self_convention, reason = "converts `v`, not `self`")]
    pub fn from_lisp<T: FromLisp>(&self, v: Value) -> Result<T> {
        T::from_lisp(self, v)
    }

    /// Optional argument `index`: `None` when it was not supplied, or was nil.
    ///
    /// A `&optional` Lisp argument can be absent or present-and-nil, and both mean the
    /// same thing to every caller here. Written out, that was five combinators --
    /// `.get(i).copied().map(..).transpose()?.flatten()` -- at each of four call sites.
    pub fn opt<T: FromLisp>(&self, args: &[Value], index: usize) -> Result<Option<T>> {
        match args.get(index) {
            Some(&v) if !self.is_nil(v) => T::from_lisp(self, v).map(Some),
            _ => Ok(None),
        }
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

pub(crate) type Defun = fn(Env, &[Value]) -> Result<Value>;

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

/// The narrow integers, which all widen to `i64` on the way out.
///
/// Written out, this widening was `i64::from(..)` at nineteen call sites in `lib.rs` --
/// and it is what forced `accessors!` to carry an `as CONV` escape hatch for the one
/// accessor whose method did not already return something the trait covered.
macro_rules! into_lisp_via_i64 {
    ($($t:ty),* $(,)?) => {
        $(impl IntoLisp for $t {
            fn into_lisp(self, env: &Env) -> Result<Value> {
                i64::from(self).into_lisp(env)
            }
        })*
    };
}

into_lisp_via_i64!(u8, u16, i32);

impl IntoLisp for u32 {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        i64::from(self).into_lisp(env)
    }
}

impl IntoLisp for bool {
    fn into_lisp(self, env: &Env) -> Result<Value> {
        if self { sym!(env, "t") } else { Ok(env.nil()) }
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
pub(crate) static plugin_is_GPL_compatible: c_int = 1;

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
        // `const` blocks: both sides are constants, so this is a property of the source
        // rather than of a run, and it should fail the build rather than wait for someone
        // to run the tests. The third cannot join them — `assert_eq!` is not const.
        const { assert!(Env::MINIMAL_ABI > 0) };
        const { assert!(Env::MINIMAL_ABI < Env::REQUIRED_ABI) };
        assert_eq!(Env::REQUIRED_ABI as usize, size_of::<Raw>());
    }
}
