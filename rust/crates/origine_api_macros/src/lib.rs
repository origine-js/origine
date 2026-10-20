//! `#[native]` and the `FromJs`/`IntoJs` derives for `origine_api`.
//!
//! The proc-macro entry points here only forward to [`native::expand`] and [`derive`], which work
//! on `proc_macro2` token streams so they can be unit-tested.
//!
//! ```ignore
//! #[native(side_effect = "any", path = "io.create", needs = "runtime")]
//! fn io_create(host: &mut HostState, opts: Option<IoCreateOpts>) -> Result<IoHandle, NativeError> { .. }
//!
//! #[native(side_effect = "none", path = "fsAsync.stat", needs = "async_fs", promise)]
//! fn file_stat(file: FileRef) -> impl Future<Output = io::Result<Stat>> + use<> { .. }
//! ```
//!
//! Attribute arguments: `side_effect = "none" | "receiver" | "any"` (required, like
//! `binding.func` on the Zig side), `path = "namespace.name"` (required: where the guest finds the native, `native.<namespace>.<name>`;
//! it also lists the native in the registry Zig iterates, see docs/contracts.md surface B), `needs = "runtime" | "async_fs"`
//! (register only when the embedder configured an io runtime / async fs), `promise` (the fn returns a
//! future; the native returns a `Promise`).

mod derive;
mod native;

use proc_macro::TokenStream;

/// Turns a Rust fn into a V8 function callback; see the crate docs.
#[proc_macro_attribute]
pub fn native(attr: TokenStream, item: TokenStream) -> TokenStream {
    native::expand(attr.into(), item.into()).unwrap_or_else(syn::Error::into_compile_error).into()
}

/// Reads a struct from a JS option bag: own data properties only, camelCase names, unknown keys ignored.
#[proc_macro_derive(FromJs, attributes(js))]
pub fn derive_from_js(input: TokenStream) -> TokenStream {
    derive::from_js(input.into()).unwrap_or_else(syn::Error::into_compile_error).into()
}

/// Writes a struct as a frozen plain JS object with camelCase property names.
#[proc_macro_derive(IntoJs, attributes(js))]
pub fn derive_into_js(input: TokenStream) -> TokenStream {
    derive::into_js(input.into()).unwrap_or_else(syn::Error::into_compile_error).into()
}
