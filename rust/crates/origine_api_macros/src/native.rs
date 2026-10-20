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

fn parse_options(attr: TokenStream) -> Result<Options> {
    let metas = Punctuated::<Meta, Token![,]>::parse_terminated.parse2(attr)?;
    let (mut side_effect, mut promise, mut path, mut needs) = (None, false, None, "None");
    for meta in &metas {
        match meta {
            Meta::NameValue(nv) if nv.path.is_ident("side_effect") => {
                let Expr::Lit(ExprLit { lit: Lit::Str(text), .. }) = &nv.value else {
                    return Err(syn::Error::new(nv.value.span(), "side_effect must be a string: \"none\", \"receiver\" or \"any\""));
                };
                side_effect = Some(match text.value().as_str() {
                    "none" => "None",
                    "receiver" => "Receiver",
                    "any" => "Any",
                    _ => return Err(syn::Error::new(text.span(), "side_effect must be \"none\", \"receiver\" or \"any\"")),
                });
            }
            Meta::Path(path) if path.is_ident("promise") => promise = true,
            Meta::NameValue(nv) if nv.path.is_ident("path") => {
                let Expr::Lit(ExprLit { lit: Lit::Str(text), .. }) = &nv.value else {
                    return Err(syn::Error::new(nv.value.span(), "path must be a string such as \"fsAsync.openFile\""));
                };
                let value = text.value();
                let segments: Vec<&str> = value.split('.').collect();
                if segments.len() != 2 || segments.iter().any(|s| s.is_empty() || !s.chars().all(|c| c.is_ascii_alphanumeric())) {
                    return Err(syn::Error::new(text.span(), "path must be `namespace.name` (ASCII letters and digits)"));
                }
                path = Some(value);
            }
            Meta::NameValue(nv) if nv.path.is_ident("needs") => {
                let Expr::Lit(ExprLit { lit: Lit::Str(text), .. }) = &nv.value else {
                    return Err(syn::Error::new(nv.value.span(), "needs must be a string: \"runtime\" or \"async_fs\""));
                };
                needs = match text.value().as_str() {
                    "runtime" => "Runtime",
                    "async_fs" => "AsyncFs",
                    _ => return Err(syn::Error::new(text.span(), "needs must be \"runtime\" or \"async_fs\"")),
                };
            }
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
enum Param {
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

fn classify(ty: &Type) -> Param {
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

    let mut params = Vec::new();
    let mut seen_arg = false;
    for input in &sig.inputs {
        let FnArg::Typed(typed) = input else {
            return Err(syn::Error::new(input.span(), "a #[native] fn cannot take `self`"));
        };
        let param = classify(&typed.ty);
        if matches!(param, Param::Arg(_)) {
            seen_arg = true;
        } else if seen_arg {
            return Err(syn::Error::new(typed.ty.span(), "the host state, scope and key parameters must come before the JS arguments"));
        }
        params.push(param);
    }
    if params.iter().filter(|param| matches!(param, Param::Host { .. })).count() > 1
        || params.iter().filter(|param| matches!(param, Param::Key)).count() > 1
    {
        return Err(syn::Error::new(sig.span(), "a #[native] fn takes at most one host state and one key parameter"));
    }

    let name = &sig.ident;
    let vis = &func.vis;
    let raw = format_ident!("{}_raw", name);
    let table = format_ident!("NATIVE_{}", name.to_string().to_uppercase());
    let side_effect = format_ident!("{}", options.side_effect);

    // Decode the JS arguments in order, then fetch the special parameter.
    let mut decode = Vec::new();
    let mut call_args = Vec::new();
    let mut special = None;
    let mut keys = Vec::new();
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
                special = Some(quote! { let __host = ::origine_api::native::#getter(scope)?; });
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
    let host_fetch = special.filter(|_| params.iter().any(|param| matches!(param, Param::Host { .. })));
    let prologue = quote! {
        #(#keys)*
        let mut __index = 0usize;
        #(#decode)*
        let _ = __index;
    };

    let body = if options.promise {
        quote! {
            ::origine_api::native::promise(scope, |scope| {
                #prologue
                #host_fetch
                ::origine_api::native::IntoOp::into_op(#name(#(#call_args),*))
            })
        }
    } else {
        quote! {
            #prologue
            #host_fetch
            let __out = #name(#(#call_args),*);
            ::origine_api::IntoJs::into_js(__out, scope)
        }
    };

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
