//! Expansion of `#[native(...)]`.

use proc_macro2::{Span, TokenStream};
use quote::{format_ident, quote};
use syn::parse::Parser;
use syn::punctuated::Punctuated;
use syn::spanned::Spanned;
use syn::{Expr, ExprLit, FnArg, ItemFn, Lit, Meta, Result, ReturnType, Token, Type};

/// Parsed attribute arguments.
struct Options {
    /// `SideEffect` variant name.
    side_effect: &'static str,
    promise: bool,
    /// The guest-visible name, `namespace.name` (`fsAsync.openFile`).
    path: String,
    /// `Needs` variant name.
    needs: &'static str,
}

/// The string literal of `name = "..."`; `hint` is the error when it is not one.
pub(crate) fn string_of<'a>(nv: &'a syn::MetaNameValue, hint: &str) -> Result<&'a syn::LitStr> {
    match &nv.value {
        Expr::Lit(ExprLit { lit: Lit::Str(text), .. }) => Ok(text),
        other => Err(syn::Error::new(other.span(), hint)),
    }
}

/// `side_effect = "none" | "receiver" | "any"` as its `SideEffect` variant name.
pub(crate) fn side_effect_of(nv: &syn::MetaNameValue) -> Result<&'static str> {
    let text = string_of(nv, "side_effect must be a string: \"none\", \"receiver\" or \"any\"")?;
    match text.value().as_str() {
        "none" => Ok("None"),
        "receiver" => Ok("Receiver"),
        "any" => Ok("Any"),
        _ => Err(syn::Error::new(text.span(), "side_effect must be \"none\", \"receiver\" or \"any\"")),
    }
}

/// `needs = "runtime" | "async_fs"` as its `Needs` variant name.
pub(crate) fn needs_of(nv: &syn::MetaNameValue) -> Result<&'static str> {
    let text = string_of(nv, "needs must be a string: \"runtime\" or \"async_fs\"")?;
    match text.value().as_str() {
        "runtime" => Ok("Runtime"),
        "async_fs" => Ok("AsyncFs"),
        _ => Err(syn::Error::new(text.span(), "needs must be \"runtime\" or \"async_fs\"")),
    }
}

/// `path = "namespace.name"`, checked.
pub(crate) fn path_of(nv: &syn::MetaNameValue, example: &str) -> Result<String> {
    let text = string_of(nv, &format!("path must be a string such as \"{example}\""))?;
    let value = text.value();
    let segments: Vec<&str> = value.split('.').collect();
    if segments.len() != 2 || segments.iter().any(|s| s.is_empty() || !s.chars().all(|c| c.is_ascii_alphanumeric())) {
        return Err(syn::Error::new(text.span(), "path must be `namespace.name` (ASCII letters and digits)"));
    }
    Ok(value)
}

fn parse_options(attr: TokenStream) -> Result<Options> {
    let metas = Punctuated::<Meta, Token![,]>::parse_terminated.parse2(attr)?;
    let (mut side_effect, mut promise, mut path, mut needs) = (None, false, None, "None");
    for meta in &metas {
        match meta {
            Meta::NameValue(nv) if nv.path.is_ident("side_effect") => side_effect = Some(side_effect_of(nv)?),
            Meta::Path(path) if path.is_ident("promise") => promise = true,
            Meta::NameValue(nv) if nv.path.is_ident("path") => path = Some(path_of(nv, "fsAsync.openFile")?),
            Meta::NameValue(nv) if nv.path.is_ident("needs") => needs = needs_of(nv)?,
            other => {
                return Err(syn::Error::new(
                    other.span(),
                    "expected `side_effect = \"...\"`, `path = \"...\"`, `needs = \"...\"` or `promise`",
                ));
            }
        }
    }
    let side_effect = side_effect.ok_or_else(|| {
        syn::Error::new(
            Span::call_site(),
            "#[native] needs an explicit side_effect: #[native(side_effect = \"none\" | \"receiver\" | \"any\")]",
        )
    })?;
    let path = path.ok_or_else(|| {
        syn::Error::new(
            Span::call_site(),
            "#[native] needs a path: #[native(path = \"namespace.name\", ..)], the name the guest sees in `native`",
        )
    })?;
    Ok(Options { side_effect, promise, path, needs })
}

/// How a parameter is supplied.
pub(crate) enum Param {
    /// `&HostState` / `&mut HostState`, from the isolate slot.
    Host { mutable: bool },
    /// `&mut v8::PinScope<..>` / `&mut v8::HandleScope<..>`.
    Scope,
    /// A `ScopeKey`: which guest scope called (the callback's External data), not a JS argument.
    Key,
    /// Decoded from the next JS argument(s) with `FromJs`.
    Arg(Box<Type>),
}

fn last_segment(ty: &Type) -> Option<String> {
    match ty {
        Type::Path(path) => path.path.segments.last().map(|segment| segment.ident.to_string()),
        _ => None,
    }
}

pub(crate) fn classify(ty: &Type) -> Param {
    if let Type::Reference(reference) = ty {
        match last_segment(&reference.elem).as_deref() {
            Some("HostState") => return Param::Host { mutable: reference.mutability.is_some() },
            Some("PinScope" | "HandleScope") => return Param::Scope,
            _ => {}
        }
    }
    if last_segment(ty).as_deref() == Some("ScopeKey") {
        return Param::Key;
    }
    Param::Arg(Box::new(ty.clone()))
}

/// `ty` with every named lifetime replaced by `'_`, for use inside the generated callback where
/// the fn's own lifetime parameters are not in scope.
fn anonymous_lifetimes(ty: &Type) -> TokenStream {
    use proc_macro2::{Group, TokenTree};
    fn walk(stream: TokenStream) -> TokenStream {
        let mut out = TokenStream::new();
        let mut iter = stream.into_iter().peekable();
        while let Some(tree) = iter.next() {
            match tree {
                TokenTree::Punct(p) if p.as_char() == '\'' && matches!(iter.peek(), Some(TokenTree::Ident(_))) => {
                    iter.next();
                    out.extend(quote!('_));
                }
                TokenTree::Group(g) => {
                    let mut group = Group::new(g.delimiter(), walk(g.stream()));
                    group.set_span(g.span());
                    out.extend([TokenTree::Group(group)]);
                }
                other => out.extend([other]),
            }
        }
        out
    }
    walk(quote!(#ty))
}

/// The parameters of a native or class member, in order, `self` excluded. `what` names the fn in errors;
/// `key` says whether a `ScopeKey` may be asked for (a class member has no calling scope to give).
pub(crate) fn parameters(inputs: &Punctuated<FnArg, Token![,]>, what: &str, key: bool) -> Result<Vec<Param>> {
    let mut params = Vec::new();
    let mut seen_arg = false;
    for input in inputs {
        let FnArg::Typed(typed) = input else { continue };
        let param = classify(&typed.ty);
        match param {
            Param::Arg(_) => seen_arg = true,
            Param::Key if !key => {
                return Err(syn::Error::new(
                    typed.ty.span(),
                    format!("{what} cannot take a ScopeKey: a class member is not bound to a scope; keep the owner in the value"),
                ));
            }
            _ if seen_arg => {
                return Err(syn::Error::new(
                    typed.ty.span(),
                    format!("in {what}, the host state, scope and key parameters must come before the JS arguments"),
                ));
            }
            _ => {}
        }
        params.push(param);
    }
    if params.iter().filter(|param| matches!(param, Param::Host { .. })).count() > 1
        || params.iter().filter(|param| matches!(param, Param::Key)).count() > 1
    {
        return Err(syn::Error::new(inputs.span(), format!("{what} takes at most one host state and one key parameter")));
    }
    if params.iter().any(|param| matches!(param, Param::Host { .. })) && params.iter().any(|param| matches!(param, Param::Scope)) {
        return Err(syn::Error::new(
            inputs.span(),
            format!(
                "{what} cannot take both the host state and the scope (both borrow the scope): take the scope and call `native::host_mut(scope)`"
            ),
        ));
    }
    Ok(params)
}

/// The number of JS arguments `params` read (the function's `length`).
pub(crate) fn js_length(params: &[Param]) -> usize {
    params.iter().filter(|param| matches!(param, Param::Arg(_))).count()
}

/// The body of a V8 callback (inside `native::run_sync(info, |scope, args| ..)`): decodes the arguments, calls
/// `call` and encodes its result (or starts its op for a `promise`). `receiver`, when given, is a statement
/// that binds `__this` before anything else is decoded; it is passed first.
pub(crate) fn call_body(call: TokenStream, params: &[Param], promise: bool, receiver: Option<TokenStream>) -> TokenStream {
    let mut decode = Vec::new();
    let mut call_args = Vec::new();
    let mut host_fetch = None;
    let mut keys = Vec::new();
    if receiver.is_some() {
        call_args.push(quote! { __this });
    }
    for (position, param) in params.iter().enumerate() {
        match param {
            Param::Arg(ty) => {
                let var = format_ident!("__arg{}", position);
                let ty = anonymous_lifetimes(ty);
                decode.push(quote! {
                    let #var: #ty = ::origine_api::FromJs::from_args(scope, args, __index)?;
                    __index += ::origine_api::decode::arity_of(&#var);
                });
                call_args.push(quote! { #var });
            }
            Param::Host { mutable } => {
                let getter = if *mutable { quote!(host_mut) } else { quote!(host_ref) };
                host_fetch = Some(quote! { let __host = ::origine_api::native::#getter(scope)?; });
                call_args.push(quote! { __host });
            }
            Param::Scope => call_args.push(quote! { scope }),
            Param::Key => {
                let var = format_ident!("__key{}", position);
                keys.push(quote! { let #var = ::origine_api::native::scope_key(args); });
                call_args.push(quote! { #var });
            }
        }
    }
    let prologue = quote! {
        #receiver
        #(#keys)*
        let mut __index = 0usize;
        #(#decode)*
        let _ = __index;
    };
    if promise {
        quote! {
            ::origine_api::native::promise(scope, |scope| {
                #prologue
                #host_fetch
                ::origine_api::native::IntoOp::into_op(#call(#(#call_args),*))
            })
        }
    } else {
        quote! {
            #prologue
            #host_fetch
            let __out = #call(#(#call_args),*);
            ::origine_api::IntoJs::into_js(__out, scope)
        }
    }
}

pub fn expand(attr: TokenStream, item: TokenStream) -> Result<TokenStream> {
    let options = parse_options(attr)?;
    let func: ItemFn = syn::parse2(item)?;
    let sig = &func.sig;
    let generic = sig.generics.params.iter().any(|param| !matches!(param, syn::GenericParam::Lifetime(_)));
    if generic || sig.generics.where_clause.is_some() {
        return Err(syn::Error::new(sig.generics.span(), "a #[native] fn cannot be generic (lifetime parameters are fine)"));
    }
    if sig.constness.is_some() || sig.unsafety.is_some() || sig.abi.is_some() || sig.variadic.is_some() {
        return Err(syn::Error::new(sig.span(), "a #[native] fn must be a plain fn"));
    }
    if sig.asyncness.is_some() && !options.promise {
        return Err(syn::Error::new(sig.span(), "an async #[native] fn needs the `promise` option"));
    }
    if options.promise && matches!(sig.output, ReturnType::Default) {
        return Err(syn::Error::new(sig.span(), "a `promise` native returns a future (`impl Future<Output = ..>`)"));
    }
    if let Some(receiver) = sig.inputs.iter().find(|input| matches!(input, FnArg::Receiver(_))) {
        return Err(syn::Error::new(receiver.span(), "a #[native] fn cannot take `self`: methods belong in a #[class] impl block"));
    }

    let params = parameters(&sig.inputs, "a #[native] fn", true)?;
    let name = &sig.ident;
    let vis = &func.vis;
    let raw = format_ident!("{}_raw", name);
    let table = format_ident!("NATIVE_{}", name.to_string().to_uppercase());
    let side_effect = format_ident!("{}", options.side_effect);
    let body = call_body(quote!(#name), &params, options.promise, None);

    let safety_doc = "Only V8 may call this, as a function callback; `info` must be the pointer V8 passed.";
    let path = &options.path;
    let needs = format_ident!("{}", options.needs);

    Ok(quote! {
        #func

        #[doc = "The V8 callback for the native of the same name."]
        #[doc = ""]
        #[doc = "# Safety"]
        #[doc = ""]
        #[doc = #safety_doc]
        #vis unsafe extern "C" fn #raw(info: *const ::origine_api::v8::FunctionCallbackInfo) {
            // SAFETY: forwarded from this function's contract: `info` is the callback info V8 passed.
            unsafe {
                ::origine_api::native::run_sync(info, |scope, args| {
                    #body
                })
            }
        }

        #[doc = "The callback and side effect of the native, for registration."]
        pub(crate) const #table: ::origine_api::native::RawNative = ::origine_api::native::RawNative {
            callback: #raw,
            side_effect: ::origine_api::native::SideEffect::#side_effect,
            path: #path,
            needs: ::origine_api::native::Needs::#needs,
        };
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use quote::quote;

    fn text(attr: TokenStream, item: TokenStream) -> String {
        expand(attr, item).expect("expands").to_string()
    }

    fn error(attr: TokenStream, item: TokenStream) -> String {
        expand(attr, item).expect_err("rejected").to_string()
    }

    #[test]
    fn sync_native_decodes_in_order_and_encodes_the_result() {
        let out = text(quote!(side_effect = "any", path = "t.add"), quote! { fn add(a: u32, b: Option<u32>) -> u32 { a } });
        assert!(out.contains("add_raw"), "{out}");
        assert!(out.contains("NATIVE_ADD"), "{out}");
        assert!(out.contains("SideEffect :: Any"), "{out}");
        assert!(out.find("__arg0").unwrap() < out.find("__arg1").unwrap(), "{out}");
        assert!(out.contains("IntoJs :: into_js (__out , scope)"), "{out}");
        assert!(!out.contains("no_mangle"), "{out}");
        assert!(out.contains("path : \"t.add\""), "{out}");
    }

    #[test]
    fn host_and_scope_params_are_injected() {
        let out = text(quote!(side_effect = "none", path = "t.f", needs = "runtime"), quote! { fn f(host: &mut HostState, x: u32) {} });
        assert!(out.contains("native :: host_mut (scope)"), "{out}");
        assert!(out.contains("Needs :: Runtime"), "{out}");
        let out = text(quote!(side_effect = "none", path = "t.f"), quote! { fn f(host: &HostState) {} });
        assert!(out.contains("native :: host_ref (scope)"), "{out}");
        let out = text(quote!(side_effect = "none", path = "t.f"), quote! { fn f(scope: &mut v8::PinScope<'_, '_>, x: u32) {} });
        assert!(out.contains("f (scope , __arg1)"), "{out}");
    }

    #[test]
    fn key_is_injected_and_lifetimes_are_allowed() {
        let out = text(
            quote!(side_effect = "none", path = "t.f"),
            quote! { fn f<'s>(scope: &mut v8::PinScope<'s, '_>, key: ScopeKey, x: u32) {} },
        );
        assert!(out.contains("native :: scope_key (args)"), "{out}");
        assert!(out.contains("f (scope , __key1 , __arg2)"), "{out}");
        assert!(out.contains("__arg2 : u32 = :: origine_api :: FromJs :: from_args (scope , args , __index)"), "{out}");
        let out = text(quote!(side_effect = "none", path = "t.f"), quote! { fn g<'s>(b: ArrayBufferArg<'s>) {} });
        assert!(out.contains("__arg0 : ArrayBufferArg < '_ > ="), "{out}");
    }

    #[test]
    fn promise_native_goes_through_native_promise() {
        let out = text(
            quote!(side_effect = "none", path = "t.f", promise),
            quote! { fn f(x: u32) -> impl Future<Output = io::Result<u32>> { async move { Ok(x) } } },
        );
        assert!(out.contains("native :: promise"), "{out}");
        assert!(out.contains("IntoOp :: into_op (f (__arg0))"), "{out}");
        assert!(
            text(quote!(promise, path = "t.g", side_effect = "any"), quote! { async fn g() -> u32 { 1 } }).contains("native :: promise")
        );
    }

    #[test]
    fn attribute_errors_are_reported() {
        let f = quote! { fn f() {} };
        assert!(error(quote!(path = "t.f"), f.clone()).contains("explicit side_effect"));
        assert!(error(quote!(side_effect = "none"), f.clone()).contains("needs a path"));
        assert!(error(quote!(side_effect = "none", path = "nodot"), f.clone()).contains("namespace.name"));
        assert!(error(quote!(side_effect = "none", path = "a.b", needs = "x"), f.clone()).contains("needs must be"));
        assert!(error(quote!(side_effect = "sometimes", path = "t.f"), f.clone()).contains("must be"));
        assert!(error(quote!(side_effect = "none", path = "t.f", bogus), f.clone()).contains("expected"));
        assert!(error(quote!(side_effect = "none", path = "t.f", promise), f).contains("returns a future"));
    }

    #[test]
    fn signature_errors_are_reported() {
        let attr = || quote!(side_effect = "none", path = "t.f");
        assert!(error(attr(), quote! { fn f<T>() {} }).contains("generic"));
        assert!(error(attr(), quote! { async fn f() {} }).contains("promise"));
        assert!(error(attr(), quote! { fn f(x: u32, host: &mut HostState) {} }).contains("must come before"));
        assert!(error(attr(), quote! { fn f(a: &mut HostState, b: &mut HostState) {} }).contains("at most one"));
        assert!(error(attr(), quote! { fn f<T>(x: T) {} }).contains("generic"));
        assert!(error(attr(), quote! { unsafe fn f() {} }).contains("plain fn"));
    }
}
