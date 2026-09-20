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

use std::any::TypeId;
use std::ffi::{CString, c_char, c_int, c_void};
use std::marker::PhantomData;
use std::os::fd::{FromRawFd, OwnedFd, RawFd};
use std::panic::{AssertUnwindSafe, catch_unwind};
use std::slice;

#[repr(C)]
pub(crate) struct ValueTag {
    _opaque: [u8; 0],
}

/// An opaque handle to a Lisp object, borrowed from the [`Env`] that produced it.
///
/// Transparent over the pointer Emacs hands us, but a distinct type so it cannot be
/// dereferenced or confused with a real pointer.
///
/// The lifetime is the environment's. Emacs roots the objects a module call sees for the
/// length of that call and no longer, so a handle kept past the call names whatever the
/// collector has since put there; the pointer itself says nothing about that, and the
/// lifetime is what makes the compiler say it instead. A defun is therefore written
/// `fn(Env<'e>, &[Value<'e>]) -> Result<Value<'e>>`, with `'e` fresh per call, and a
/// `Value` has nowhere to go but back to Emacs.
///
/// The one Lisp object that really does outlive its call is a global reference, and it
/// is not a `Value` at all but a [`Global`], which has to be bound to an environment
/// before it can be used as a handle again.
///
/// `PhantomData` rather than a field of substance, so this stays `#[repr(transparent)]`
/// over the pointer: `funcall` is handed `&[Value]` as the array of `emacs_value` it
/// expects, and [`trampoline`] reads Emacs' argument array back as one.
#[repr(transparent)]
#[derive(Clone, Copy, PartialEq, Eq)]
pub struct Value<'e>(*mut ValueTag, PhantomData<&'e ValueTag>);

impl Value<'_> {
    const NULL: Self = Self(std::ptr::null_mut(), PhantomData);
}

/// A Lisp object Emacs roots for the module, rather than for the length of one call.
///
/// A global reference outlives the environment that made it, so there is no lifetime to
/// carry and no `Value` to be had until one is supplied: [`Global::in_env`] is the only
/// way back to a handle, and it borrows the environment it is handed. That is the whole
/// of the type -- a `Global` cannot be passed to Emacs, compared, or read, so the claim
/// that this object is rooted is made once, in [`Env::global_ref`], and cannot be made
/// anywhere else by writing a lifetime down.
///
/// Nothing frees one. [`SYMBOLS`] is the only holder, and it is never torn down, so
/// there is no `free_global_ref` here and no machinery to decide when it would be safe
/// to call.
struct Global(*mut ValueTag);

impl Global {
    const NULL: Self = Self(std::ptr::null_mut());

    /// This object as a handle belonging to `env`.
    ///
    /// Sound for any environment: the object is rooted for longer than any of them, so
    /// borrowing it for the length of one call asks for less than it has.
    fn in_env<'e>(&self, _: &Env<'e>) -> Value<'e> {
        Value(self.0, PhantomData)
    }
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

type FnPtr =
    for<'a> unsafe extern "C" fn(*mut Raw, isize, *mut Value<'a>, *mut c_void) -> Value<'a>;

/// A handle Emacs has just made, not yet tied to the environment that asked for it.
///
/// The slots that *make* a value are handed none, so the mirror has no input lifetime to
/// borrow the answer from and C offers nothing in its place. Letting each of those forty
/// slots name a lifetime of its own would be forty chances to name the wrong one; they
/// answer this instead, and [`Fresh::in_env`] is the one step that ties such a handle to
/// the call that asked for it. A [`Global`] is the same trick for the other direction:
/// an object with no lifetime, usable only once an environment is supplied.
#[repr(transparent)]
struct Fresh(*mut ValueTag);

impl Fresh {
    /// Tie this handle to `env`, which is the environment Emacs made it in.
    fn in_env<'e>(self, _: &Env<'e>) -> Value<'e> {
        Value(self.0, PhantomData)
    }
}

/// Emacs' `struct emacs_env_28`, slot for slot.
///
/// A slot that is handed an `emacs_value` is written `for<'a>`: which environment a
/// handle belongs to is the caller's to say, and C says nothing either way, so
/// instantiating `'a` is how each [`Env`] method below hands its own `'e` to the values
/// it passes and takes back. A slot that only makes one -- `intern`, `make_integer` --
/// has no handle to borrow from and answers a [`Fresh`] instead.
#[repr(C)]
pub struct Raw {
    size: isize,
    private: *mut c_void,
    make_global_ref: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>) -> Value<'a>,
    free_global_ref: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>),
    non_local_exit_check: unsafe extern "C" fn(*mut Raw) -> c_int,
    non_local_exit_clear: unsafe extern "C" fn(*mut Raw),
    non_local_exit_get:
        for<'a> unsafe extern "C" fn(*mut Raw, *mut Value<'a>, *mut Value<'a>) -> c_int,
    non_local_exit_signal: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>, Value<'a>),
    non_local_exit_throw: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>, Value<'a>),
    make_function:
        unsafe extern "C" fn(*mut Raw, isize, isize, FnPtr, *const c_char, *mut c_void) -> Fresh,
    funcall:
        for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>, isize, *const Value<'a>) -> Value<'a>,
    intern: unsafe extern "C" fn(*mut Raw, *const c_char) -> Fresh,
    type_of: Slot,
    is_not_nil: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>) -> bool,
    eq: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>, Value<'a>) -> bool,
    extract_integer: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>) -> i64,
    make_integer: unsafe extern "C" fn(*mut Raw, i64) -> Fresh,
    extract_float: Slot,
    make_float: Slot,
    copy_string_contents:
        for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>, *mut c_char, *mut isize) -> bool,
    make_string: unsafe extern "C" fn(*mut Raw, *const c_char, isize) -> Fresh,
    make_user_ptr: unsafe extern "C" fn(*mut Raw, Option<Finalizer>, *mut c_void) -> Fresh,
    get_user_ptr: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>) -> *mut c_void,
    set_user_ptr: Slot,
    get_user_finalizer: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>) -> Option<Finalizer>,
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
    open_channel: for<'a> unsafe extern "C" fn(*mut Raw, Value<'a>) -> c_int,
    make_interactive: Slot,
    make_unibyte_string: unsafe extern "C" fn(*mut Raw, *const c_char, isize) -> Fresh,
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
/// `non_local_exit_check` every [`ffi!`] does after it. That is the cost `symbols!`
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
/// emulator, and interning it per drain is the cost `symbols!` exists to remove -- but
/// the enums live in `emu` and `pty`, which are plain Rust with no [`Env`] in sight and
/// no business naming a [`Sym`].
///
/// So the list moves to the boundary, where it is invoked once and generates both. There
/// is still exactly one spelling of each name; it is now in the module that sends it, and
/// on the symbol table like every other symbol.
macro_rules! lisp_enum {
    ($( $(#[doc = $doc:literal])* $t:ty { $($variant:ident => $name:literal),* $(,)? } )*) => {
        $($(#[doc = $doc])*
        impl<'e> $crate::env::IntoLisp<'e> for $t {
            fn into_lisp(
                self,
                env: &$crate::env::Env<'e>,
            ) -> $crate::env::Result<$crate::env::Value<'e>> {
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
        // Most variants are never named by a `Sym::` path in code. They are here to give
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
    // What `input_kind` in `lib.rs` asks about the event being handled, on every
    // keystroke the user sends to a child: the variable's value, and whether it is a
    // cons. Three names, interned three times a keypress before they were here.
    SymbolValue => "symbol-value",
    LastInputEvent => "last-input-event",
    Consp => "consp",
    // How `to_key` and `symbol_name` read the key Lisp named, on the same keystroke:
    // once for the key itself and once more for each of its modifiers.
    Symbolp => "symbolp",
    SymbolName => "symbol-name",
    // Every `plist!` key in the module. They are interned once each here instead of once
    // each per drain, which is where fifteen of them were being rebuilt sixty times a
    // second. `sym_index` makes leaving one out a compile error rather than a silent
    // fallback, so this list cannot quietly fall behind the call sites.
    Scrolled => ":scrolled",
    Promoted => ":promoted",
    Shifts => ":shifts",
    Rows => ":rows",
    Edits => ":edits",
    Height => ":height",
    Width => ":width",
    Used => ":used",
    Head => ":head",
    Cursor => ":cursor",
    Reverse => ":reverse",
    ReverseToggles => ":reverse-toggles",
    Marks => ":marks",
    Alt => ":alt",
    AppCursor => ":app-cursor",
    Keys => ":keys",
    KittyFlags => ":kitty-flags",
    ModifyOtherKeysLevel => ":modify-other-keys",
    Mode => ":mode",
    Images => ":images",
    Links => ":links",
    Styles => ":styles",
    Events => ":events",
    Exit => ":exit",
    Withheld => ":withheld",
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
    Reset => "reset",
    TitleStack => "title-stack",
    ResizeRequest => "resize-request",
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
    // How Lisp spells a colour scheme on the way *in*, for the `FromLisp' impl on
    // `ColorScheme' that `cooked--set-color-scheme' and the INITIAL-STATE plist's
    // `:color-scheme' both go through. Compared against with `Env::eq' rather than
    // decoded to a number, so there is no third spelling to fall through to.
    Dark => "dark",
    Light => "light",
    // The keys of the plist `cooked--spawn' takes as its INITIAL-STATE argument; see
    // `SpawnState''s `FromLisp' impl in lib.rs.
    MinRedisplayInterval => ":min-redisplay-interval",
    BacklogLimit => ":backlog-limit",
    Graphics => ":graphics",
    ColorScheme => ":color-scheme",
    PaletteDefaults => ":palette-defaults",
    PaletteColors => ":palette-colors",
    FrameSize => ":frame-size",
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
///
/// The only holder of a [`Global`] in the module, which is why `Global` needs no way to
/// be freed and no way to be copied out into something longer-lived.
struct Symbols([Global; Sym::NAMES.len()]);

/// SAFETY: `Global` is a raw pointer, so `Symbols` is neither `Send` nor `Sync` on its
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

    pub fn intern(&self, name: &str) -> Result<Value<'e>> {
        let c = CString::new(name).map_err(|_| Error)?;
        ffi!(self, intern, c.as_ptr()).map(|v| v.in_env(self))
    }

    /// A symbol from the load-time table; no allocation and no FFI call.
    ///
    /// Falls back to interning if the table is somehow not populated. That cannot happen
    /// through any path a user can reach -- `emacs_module_init` fills it before it
    /// registers a single defun -- but the fallback is one line and costs nothing on the
    /// path that matters, and the alternative is a panic in FFI code.
    pub fn sym(&self, s: Sym) -> Result<Value<'e>> {
        self.sym_at(s as usize)
    }

    /// [`Env::sym`] by raw index, for [`plist!`]'s compile-time lookup.
    pub fn sym_at(&self, index: usize) -> Result<Value<'e>> {
        match SYMBOLS.get() {
            Some(table) => Ok(table.0[index].in_env(self)),
            None => self.intern(Sym::NAMES[index]),
        }
    }

    /// Ask Emacs to root `v` for longer than this call.
    ///
    /// The only source of a [`Global`] in the module. A global reference is rooted until
    /// `free_global_ref`, which this module never calls, so the object really does live
    /// as long as the process -- see [`SYMBOLS`].
    fn global_ref(&self, v: Value<'e>) -> Result<Global> {
        Ok(Global(ffi!(self, make_global_ref, v)?.0))
    }

    /// Fill [`SYMBOLS`]. Called once, from `emacs_module_init`.
    ///
    /// A second `module-load` of the same file runs `emacs_module_init` again and finds
    /// the table already set. Ignoring that is correct rather than merely tolerable: one
    /// process is one Emacs with one obarray, so the symbols already in the table name
    /// the very same objects a re-intern would find.
    pub fn intern_symbols(&self) -> Result<()> {
        let mut table = [const { Global::NULL }; Sym::NAMES.len()];
        for (slot, name) in table.iter_mut().zip(Sym::NAMES) {
            *slot = self.global_ref(self.intern(name)?)?;
        }
        let _ = SYMBOLS.set(Symbols(table));
        Ok(())
    }

    pub fn nil(&self) -> Value<'e> {
        self.sym(Sym::Nil).unwrap_or(Value::NULL)
    }

    pub fn is_nil(&self, v: Value<'_>) -> bool {
        !unsafe { ((*self.raw).is_not_nil)(self.raw, v) }
    }

    pub fn eq(&self, a: Value<'_>, b: Value<'_>) -> bool {
        unsafe { ((*self.raw).eq)(self.raw, a, b) }
    }

    pub fn call(&self, func: &str, args: &[Value<'e>]) -> Result<Value<'e>> {
        self.funcall(self.intern(func)?, args)
    }

    /// [`Env::call`] for a function that is already a [`Value`].
    ///
    /// The one to use with [`sym!`] -- `env.funcall(sym!(env, "consp")?, &[v])` -- which
    /// is how a call site on a hot path names a function without interning it and without
    /// naming a [`Sym`] variant.
    pub fn funcall(&self, func: Value<'e>, args: &[Value<'e>]) -> Result<Value<'e>> {
        ffi!(self, funcall, func, args.len() as isize, args.as_ptr())
    }

    /// [`Env::call`] for a function named in the symbol table, which is every function
    /// this module calls often enough for the name lookup to show.
    fn call_sym(&self, func: Sym, args: &[Value<'e>]) -> Result<Value<'e>> {
        self.funcall(self.sym(func)?, args)
    }

    pub fn list(&self, items: &[Value<'e>]) -> Result<Value<'e>> {
        self.call_sym(Sym::List, items)
    }

    pub fn cons(&self, car: Value<'e>, cdr: Value<'e>) -> Result<Value<'e>> {
        self.call_sym(Sym::Cons, &[car, cdr])
    }

    pub fn car(&self, cell: Value<'e>) -> Result<Value<'e>> {
        self.call_sym(Sym::Car, &[cell])
    }

    pub fn cdr(&self, cell: Value<'e>) -> Result<Value<'e>> {
        self.call_sym(Sym::Cdr, &[cell])
    }

    /// The value KEY holds in PLIST, or nil when KEY is absent — what Lisp's
    /// `plist-get` returns, walked by hand rather than through a call to it.
    ///
    /// A plist decoder belongs here rather than in `lib.rs`: every `FromLisp` impl that
    /// reads one — `cooked--spawn`'s INITIAL-STATE argument today — wants the same walk,
    /// and it costs no more than [`Env::car`] and [`Env::cdr`] already do, both of which
    /// this is built from.
    pub fn plist_get(&self, mut plist: Value<'e>, key: Value<'e>) -> Result<Value<'e>> {
        while !self.is_nil(plist) {
            let k = self.car(plist)?;
            let rest = self.cdr(plist)?;
            if self.eq(k, key) {
                return self.car(rest);
            }
            plist = self.cdr(rest)?;
        }
        Ok(self.nil())
    }

    /// Wrap `data` in an opaque Lisp user-pointer; Emacs' GC runs the destructor.
    ///
    /// Reached through `env.into_lisp(session)` rather than called directly: the
    /// [`IntoLisp`] impl for a [`UserPtr`] type is what makes this the ordinary way a
    /// Rust value goes out to Lisp, and it is the only caller.
    pub fn user_ptr<T: UserPtr>(&self, data: T) -> Result<Value<'e>> {
        let boxed = Tagged::into_raw(data);
        ffi!(self, make_user_ptr, Some(finalizer_of::<T>()), boxed)
            .map(|v| v.in_env(self))
            .inspect_err(|_| {
                drop(unsafe { Box::from_raw(boxed.cast::<Tagged<T>>()) });
            })
    }

    /// Borrow a user-pointer *this module* created for `T`.
    ///
    /// Reached through `env.from_lisp::<&Session>(v)`, for the reason [`Env::user_ptr`]
    /// is reached through `into_lisp`.
    ///
    /// Emacs signals for a value that is not a user-pointer at all, but it has no notion
    /// of what kind of thing a user-pointer holds — so without a check of our own,
    /// handing `cooked--send` a user-pointer from some other dynamic module would
    /// reinterpret that module's memory as a `T`.
    ///
    /// Two gates, and the order between them is the point. The finalizer address is the
    /// only identity Emacs carries, and it answers the one question that cannot be
    /// answered by reading the pointed-at memory: whether this module made the
    /// allocation at all. Only once it has is the [`Tagged`] header there to read, and
    /// the header is what says which of our own types the allocation holds.
    pub fn get_user_ptr<T: UserPtr>(&self, v: Value<'e>) -> Result<&'e T> {
        // Propagate first: for a non-user-ptr this is already a pending
        // `wrong-type-argument`, which must not be overwritten with ours.
        //
        // `fn_addr_eq` rather than `==` because comparing function pointers is only as
        // meaningful as the guarantee that the two cannot be folded together. Two of our
        // own finalizers may fold, and the tag is why that is now harmless; a finalizer
        // of ours cannot fold with another module's, because those live in a different
        // shared object.
        let ours = ffi!(self, get_user_finalizer, v)?
            .is_some_and(|f| std::ptr::fn_addr_eq(f, finalizer_of::<T>()));
        if !ours {
            return Err(self.signal_wrong_type(T::PREDICATE, v));
        }
        let p = ffi!(self, get_user_ptr, v)?;
        // SAFETY: the finalizer said this module allocated `p` through `Tagged::into_raw`,
        // and Emacs keeps it alive for as long as the Lisp value is reachable.
        unsafe { Tagged::from_raw(p) }.ok_or_else(|| self.signal_wrong_type(T::PREDICATE, v))
    }

    /// The write end of a `make-pipe-process` channel, owned and safe to use off-thread.
    ///
    /// Emacs hands over a descriptor that is ours to close, so this returns the type that
    /// says so. The `unsafe` sits three lines from the FFI call that establishes the
    /// contract, rather than at a caller who has to be told about it -- which is what
    /// leaves `session.rs` with no `unsafe` at all outside its tests.
    pub fn open_channel(&self, pipe_process: Value<'e>) -> Result<OwnedFd> {
        let raw: RawFd = ffi!(self, open_channel, pipe_process)?;
        // SAFETY: `open_channel` returns a descriptor the module owns and must close.
        Ok(unsafe { OwnedFd::from_raw_fd(raw) })
    }

    pub fn should_quit(&self) -> bool {
        unsafe { ((*self.raw).should_quit)(self.raw) }
    }

    pub fn signal(&self, symbol: &str, message: &str) -> Error {
        let build = || -> Result<(Value<'e>, Value<'e>)> {
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
    pub fn signal_wrong_type(&self, predicate: &str, value: Value<'e>) -> Error {
        let build = || -> Result<(Value<'e>, Value<'e>)> {
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
    pub fn into_lisp<T: IntoLisp<'e>>(&self, v: T) -> Result<Value<'e>> {
        v.into_lisp(self)
    }

    #[allow(clippy::wrong_self_convention, reason = "converts `v`, not `self`")]
    pub fn from_lisp<T: FromLisp<'e>>(&self, v: Value<'e>) -> Result<T> {
        T::from_lisp(self, v)
    }

    /// Optional argument `index`: `None` when it was not supplied, or was nil.
    ///
    /// A `&optional` Lisp argument can be absent or present-and-nil, and both mean the
    /// same thing to every caller here. Written out, that was five combinators --
    /// `.get(i).copied().map(..).transpose()?.flatten()` -- at each of four call sites.
    pub fn opt<T: FromLisp<'e>>(&self, args: &[Value<'e>], index: usize) -> Result<Option<T>> {
        match args.get(index) {
            Some(&v) if !self.is_nil(v) => T::from_lisp(self, v).map(Some),
            _ => Ok(None),
        }
    }

    /// Register `f` as the Lisp function `name`.
    pub fn defun(
        &self,
        name: &'static str,
        arity: std::ops::RangeInclusive<isize>,
        doc: &str,
        f: Defun,
    ) -> Result<()> {
        let doc = CString::new(doc).map_err(|_| Error)?;
        let registered: &'static Registered = Box::leak(Box::new(Registered { name, f }));
        let func = ffi!(
            self,
            make_function,
            *arity.start(),
            *arity.end(),
            trampoline,
            doc.as_ptr(),
            std::ptr::from_ref(registered).cast_mut().cast::<c_void>(),
        )?
        .in_env(self);
        self.call("defalias", &[self.intern(name)?, func]).map(drop)
    }
}

/// A Lisp entry point. `'e` is the call's, universally quantified, which is what leaves
/// the body no way to put a [`Value`] anywhere but back into Emacs.
pub(crate) type Defun = for<'e> fn(Env<'e>, &[Value<'e>]) -> Result<Value<'e>>;

/// What Emacs hands back to [`trampoline`]: the function to call, and the name to put in
/// the signal if it fails without leaving one pending.
///
/// Leaked once per `defun`, for the reason [`SYMBOLS`] is: Emacs holds this pointer for
/// as long as the function is callable, which is the life of the process, and there is no
/// teardown hook to free it from. A bounded leak of one allocation per entry point.
struct Registered {
    name: &'static str,
    f: Defun,
}

type Finalizer = extern "C" fn(*mut c_void);

extern "C" fn finalize<T>(p: *mut c_void) {
    drop(unsafe { Box::from_raw(p.cast::<Tagged<T>>()) });
}

/// The address identifying user-pointers this module made for `T`.
///
/// Identical-code-folding may merge two monomorphisations whose bodies are
/// byte-identical, and for two `Drop`-free payloads of the same size, `Box::from_raw`
/// plus drop glue is exactly that. Folding those two is harmless: the merged body frees
/// the right number of bytes either way, and [`Env::get_user_ptr`] reads the type out of
/// the [`Tagged`] header rather than out of this address. What the address still settles
/// is whether the allocation is ours at all, and no linker can fold a function in this
/// shared object with one in another module's.
const fn finalizer_of<T>() -> Finalizer {
    finalize::<T>
}

/// A user-pointer payload with the type it was made for written in ahead of it.
///
/// Every allocation this module hands Emacs is one of these, and `tag` sits at offset
/// zero of all of them whatever `T` is, which is what makes it readable before anything
/// has committed to a `T`. `TypeId` rather than a constant written out per type, so two
/// types cannot be given the same tag by a copy-paste: the compiler mints them, and it
/// mints a distinct one per type by construction.
#[repr(C)]
struct Tagged<T> {
    tag: TypeId,
    value: T,
}

impl<T: 'static> Tagged<T> {
    /// Allocate `value` behind its tag and give up ownership, as Emacs' GC now owns it.
    fn into_raw(value: T) -> *mut c_void {
        let tagged = Box::new(Self {
            tag: TypeId::of::<T>(),
            value,
        });
        Box::into_raw(tagged).cast::<c_void>()
    }

    /// The payload at `p`, or `None` if this module made that allocation for some other
    /// type -- or if `p` is null.
    ///
    /// Null is answered rather than read because it is Emacs' way of saying it has
    /// nothing, and `get_user_ptr` is a C function that can come back that way; the
    /// caller then signals as it does for any other value it was not handed a `T` for.
    ///
    /// # Safety
    /// `p` must be null or point at a live allocation made by [`Tagged::into_raw`], for
    /// any payload type. Reading the tag is then in bounds and aligned whichever type
    /// that was, because `#[repr(C)]` puts a `TypeId` first in every one of them; nothing
    /// else is read until the tag has said the payload really is a `T`.
    unsafe fn from_raw<'a>(p: *mut c_void) -> Option<&'a T> {
        if p.is_null() || unsafe { *p.cast::<TypeId>() } != TypeId::of::<T>() {
            return None;
        }
        Some(unsafe { &(*p.cast::<Self>()).value })
    }
}

unsafe extern "C" fn trampoline<'e>(
    raw: *mut Raw,
    n: isize,
    args: *mut Value<'e>,
    data: *mut c_void,
) -> Value<'e> {
    let env = unsafe { Env::from_raw(raw) };
    // SAFETY: `data` is the `Registered` `defun` leaked for this function, and a leaked
    // one outlives every call Emacs can make through it.
    let registered = unsafe { &*data.cast::<Registered>() };
    let args = match n {
        0 => &[],
        n => unsafe { slice::from_raw_parts(args, n as usize) },
    };
    match catch_unwind(AssertUnwindSafe(|| (registered.f)(env, args))) {
        Ok(Ok(v)) => v,
        // An `Err` all but always means the signal is already pending on the Emacs side,
        // which is the whole reason `Error` carries nothing. The exception is an `Err`
        // built without signalling -- `intern` and `defun` answer one for a NUL in a name
        // -- and returning `nil` for that hands Lisp a value nobody can explain. So ask,
        // on the error path only, and say who failed if nothing else did.
        //
        // No entry point reaches this today: every one that answers an error signals
        // first, and no name the tree interns carries a NUL. It is here for the one that
        // will, and is deliberately untested rather than tested through a defun that
        // would have to ship in the module to be callable.
        Ok(Err(Error)) => {
            if env.check().is_ok() {
                env.signal(
                    "cooked-error",
                    &format!("{} failed without reporting why", registered.name),
                );
            }
            env.nil()
        }
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

/// Conversion into a handle belonging to the environment doing the converting.
///
/// Parametric in `'e` rather than generic per method, because the identity conversion
/// below -- a [`Value`] that is already Lisp -- can only answer for the environment it
/// came from.
pub trait IntoLisp<'e> {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>>;
}

/// Conversion out of a handle belonging to the environment doing the converting.
///
/// Parametric in `'e` for the same reason [`IntoLisp`] is: a conversion may answer a
/// borrow of something the handle names, and `&'e Session` -- what a defun asks for when
/// it wants the session behind its first argument -- can only be tied to the environment
/// that handed the handle over.
/// A Rust type this module gives Lisp to hold, as a user pointer.
///
/// The bound on [`Env::user_ptr`] and [`Env::get_user_ptr`], so the types that can cross
/// are the ones written down as impls of this and no others -- `'static` alone would
/// admit any of them. There is no impl for `&mut T` or for `T` by value on the way back,
/// which is how the ownership rule is stated: handing a value over moves it, and what
/// comes back is the shared borrow `Emacs` can hand out any number of times.
///
/// Carries the predicate and nothing else. Everything a user pointer needs beyond the
/// name -- the finalizer address, the type tag -- the compiler already mints per type,
/// and a trait item that could be written out wrongly per type is a thing to have fewer
/// of; the name is the one fact only a person can supply, because it names a function on
/// the Lisp side.
pub trait UserPtr: 'static {
    /// The Lisp predicate this type answers to, named in the `wrong-type-argument`
    /// signalled for a handle of some other kind: `"cooked-session-p"` for a `Session`.
    /// Lisp must define it, so that the signal names something that resolves.
    const PREDICATE: &'static str;
}

pub trait FromLisp<'e>: Sized {
    fn from_lisp(env: &Env<'e>, v: Value<'e>) -> Result<Self>;
}

impl<'e> IntoLisp<'e> for Value<'e> {
    fn into_lisp(self, _: &Env<'e>) -> Result<Value<'e>> {
        Ok(self)
    }
}

impl<'e> IntoLisp<'e> for i64 {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        ffi!(env, make_integer, self).map(|v| v.in_env(env))
    }
}

impl<'e> IntoLisp<'e> for usize {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
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
        $(impl<'e> IntoLisp<'e> for $t {
            fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
                i64::from(self).into_lisp(env)
            }
        })*
    };
}

into_lisp_via_i64!(u8, u16, i32);

impl<'e> IntoLisp<'e> for u32 {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        i64::from(self).into_lisp(env)
    }
}

impl<'e> IntoLisp<'e> for bool {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        if self { sym!(env, "t") } else { Ok(env.nil()) }
    }
}

impl<'e> IntoLisp<'e> for &str {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        ffi!(env, make_string, self.as_ptr().cast(), self.len() as isize).map(|v| v.in_env(env))
    }
}

impl<'e> IntoLisp<'e> for String {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        self.as_str().into_lisp(env)
    }
}

/// Byte strings become unibyte Lisp strings — no decoding, no corruption.
impl<'e> IntoLisp<'e> for &[u8] {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        ffi!(
            env,
            make_unibyte_string,
            self.as_ptr().cast(),
            self.len() as isize
        )
        .map(|v| v.in_env(env))
    }
}

impl<'e, T: IntoLisp<'e>> IntoLisp<'e> for Option<T> {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        self.map_or_else(|| Ok(env.nil()), |v| v.into_lisp(env))
    }
}

/// A vector of values that are already Lisp, which is every list this module builds by
/// iterating: the drain's rows, marks, events, images and links.
///
/// Concrete rather than a blanket `impl<T: IntoLisp> IntoLisp for Vec<T>`, for two
/// reasons. A `Vec<Value>` is already the contiguous array `funcall` wants, so it passes
/// straight through with no second `Vec`. And a blanket impl would cover `Vec<u8>`, which
/// would quietly become a Lisp *list of integers* instead of the unibyte string the
/// `&[u8]` impl makes; with no impl for `Vec<u8>`, forgetting `.as_slice()` is a compile
/// error.
impl<'e> IntoLisp<'e> for Vec<Value<'e>> {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        env.list(&self)
    }
}

impl<'e> IntoLisp<'e> for () {
    fn into_lisp(self, env: &Env<'e>) -> Result<Value<'e>> {
        Ok(env.nil())
    }
}

impl<'e> FromLisp<'e> for i64 {
    fn from_lisp(env: &Env<'e>, v: Value<'e>) -> Result<Self> {
        ffi!(env, extract_integer, v)
    }
}

impl<'e> FromLisp<'e> for usize {
    fn from_lisp(env: &Env<'e>, v: Value<'e>) -> Result<Self> {
        i64::from_lisp(env, v)?
            .try_into()
            .map_err(|_| env.signal("args-out-of-range", "negative"))
    }
}

impl<'e> FromLisp<'e> for u16 {
    fn from_lisp(env: &Env<'e>, v: Value<'e>) -> Result<Self> {
        i64::from_lisp(env, v)?
            .try_into()
            .map_err(|_| env.signal("args-out-of-range", "not a u16"))
    }
}

impl<'e> FromLisp<'e> for bool {
    fn from_lisp(env: &Env<'e>, v: Value<'e>) -> Result<Self> {
        Ok(!env.is_nil(v))
    }
}

impl<'e> FromLisp<'e> for Vec<u8> {
    /// The string's UTF-8 bytes, copied straight out of the Lisp string.
    ///
    /// Straight out, with no Lisp copy in between, whatever the string holds: since
    /// Emacs 28 `copy_string_contents` calls `encode_string_utf_8` with NOCOPY, and that
    /// hands back the string itself unless it has to change a byte, which a valid
    /// Unicode string never needs. So a non-ASCII password sent through `send` leaves
    /// this `Vec`, which `send` zeroes, and nothing else behind in Emacs' heap. A
    /// multibyte string holding raw eight-bit bytes is refused by Emacs instead of
    /// re-encoded.
    fn from_lisp(env: &Env<'e>, v: Value<'e>) -> Result<Self> {
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

impl<'e> FromLisp<'e> for String {
    fn from_lisp(env: &Env<'e>, v: Value<'e>) -> Result<Self> {
        String::from_utf8(Vec::from_lisp(env, v)?)
            .map_err(|_| env.signal("wrong-type-argument", "invalid utf-8"))
    }
}

impl<'e, T: FromLisp<'e>> FromLisp<'e> for Option<T> {
    fn from_lisp(env: &Env<'e>, v: Value<'e>) -> Result<Self> {
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
    struct Other;

    #[test]
    fn a_type_keeps_one_finalizer_address() {
        // What the first gate in `get_user_ptr` rests on: the address registered by
        // `user_ptr::<T>` is the address compared against by `get_user_ptr::<T>`.
        assert!(std::ptr::fn_addr_eq(
            finalizer_of::<Dummy>(),
            finalizer_of::<Dummy>()
        ));
    }

    #[test]
    fn a_tagged_box_is_refused_for_another_type() {
        // `Dummy` and `Other` are the case the tag exists for: both `Drop`-free and the
        // same size, so their finalizers have byte-identical bodies and
        // identical-code-folding is free to give them one address. The gate cannot tell
        // those two apart even in principle. The tag does not have to: it is read out of
        // the allocation rather than out of a function address, so folding changes
        // nothing.
        let p = Tagged::into_raw(Dummy);
        assert!(unsafe { Tagged::<Dummy>::from_raw(p) }.is_some());
        assert!(unsafe { Tagged::<Other>::from_raw(p) }.is_none());
        drop(unsafe { Box::from_raw(p.cast::<Tagged<Dummy>>()) });
    }

    #[test]
    fn a_null_user_pointer_is_refused() {
        // What `get_user_ptr` hands back when Emacs has nothing to hand back. Reading a
        // tag out of it would be a null dereference rather than a refusal.
        assert!(unsafe { Tagged::<Dummy>::from_raw(std::ptr::null_mut()) }.is_none());
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
