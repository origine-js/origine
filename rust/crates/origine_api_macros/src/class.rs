//! Expansion of `#[class(...)]` on an impl block: the Rust type becomes a JS class (see `origine_api::class`).

use origine_api_core::arg::camel_case;
use proc_macro2::{Span, TokenStream};
use quote::{format_ident, quote};
use syn::parse::Parser;
use syn::punctuated::Punctuated;
use syn::spanned::Spanned;
use syn::{FnArg, ImplItem, ImplItemFn, ItemImpl, Meta, Result, ReturnType, Token, Type};

use crate::native::{call_body, js_length, needs_of, parameters, path_of, side_effect_of, string_of};

/// `#[class(...)]` arguments.
struct ClassOptions {
    /// `namespace.Name`: the installer is `native.<namespace>.<Name>`, the class is named `Name`.
    path: String,
    /// The default `SideEffect` variant of the members.
    side_effect: &'static str,
    needs: &'static str,
}

fn class_options(attr: TokenStream) -> Result<ClassOptions> {
    let metas = Punctuated::<Meta, Token![,]>::parse_terminated.parse2(attr)?;
    let (mut path, mut side_effect, mut needs) = (None, None, "None");
    for meta in &metas {
        match meta {
            Meta::NameValue(nv) if nv.path.is_ident("path") => path = Some(path_of(nv, "tls.RootPki")?),
            Meta::NameValue(nv) if nv.path.is_ident("side_effect") => side_effect = Some(side_effect_of(nv)?),
            Meta::NameValue(nv) if nv.path.is_ident("needs") => needs = needs_of(nv)?,
            other => return Err(syn::Error::new(other.span(), "expected `path = \"...\"`, `side_effect = \"...\"` or `needs = \"...\"`")),
        }
    }
    let path = path.ok_or_else(|| {
        syn::Error::new(
            Span::call_site(),
            "#[class] needs a path: #[class(path = \"namespace.ClassName\", ..)], where the glue installs it",
        )
    })?;
    let side_effect = side_effect.ok_or_else(|| {
        syn::Error::new(
            Span::call_site(),
            "#[class] needs an explicit side_effect, the default of its members: #[class(side_effect = \"none\" | \"receiver\" | \"any\")]",
        )
    })?;
    Ok(ClassOptions { path, side_effect, needs })
}

#[derive(Clone, Copy, PartialEq, Eq)]
enum Kind {
    Static,
    Method,
    Getter,
}

/// One member: its kind and options, parsed from (and stripped of) its attribute.
struct MemberOptions {
    kind: Kind,
    name: Option<String>,
    side_effect: Option<&'static str>,
    promise: bool,
}

const MEMBER_ATTRS: [&str; 3] = ["static_method", "method", "getter"];

fn member_options(func: &mut ImplItemFn) -> Result<Option<MemberOptions>> {
    let mut found = None;
    let mut kept = Vec::new();
    for attr in func.attrs.drain(..) {
        let Some(kind) = MEMBER_ATTRS.iter().position(|name| attr.path().is_ident(name)) else {
            kept.push(attr);
            continue;
        };
        if found.is_some() {
            return Err(syn::Error::new(attr.span(), "a member takes one of #[static_method], #[method] or #[getter]"));
        }
        let kind = [Kind::Static, Kind::Method, Kind::Getter][kind];
        let mut options = MemberOptions { kind, name: None, side_effect: None, promise: false };
        if let Meta::List(_) = &attr.meta {
            let metas = attr.parse_args_with(Punctuated::<Meta, Token![,]>::parse_terminated)?;
            for meta in &metas {
                match meta {
                    Meta::NameValue(nv) if nv.path.is_ident("name") => {
                        let text = string_of(nv, "name must be a string: the JS name of the member")?;
                        options.name = Some(text.value());
                    }
                    Meta::NameValue(nv) if nv.path.is_ident("side_effect") => options.side_effect = Some(side_effect_of(nv)?),
                    Meta::Path(path) if path.is_ident("promise") && kind != Kind::Getter => options.promise = true,
                    other => {
                        return Err(syn::Error::new(
                            other.span(),
                            "expected `name = \"...\"`, `side_effect = \"...\"` or (not on a getter) `promise`",
                        ));
                    }
                }
            }
        }
        found = Some(options);
    }
    func.attrs = kept;
    Ok(found)
}

/// `RootPki` -> `ROOT_PKI` (the registry constant `CLASS_ROOT_PKI`).
pub(crate) fn upper_snake(name: &str) -> String {
    let mut out = String::with_capacity(name.len() + 4);
    let mut previous_lower = false;
    for ch in name.chars() {
        if ch.is_ascii_uppercase() && previous_lower {
            out.push('_');
        }
        previous_lower = ch.is_ascii_lowercase() || ch.is_ascii_digit();
        out.extend(ch.to_uppercase());
    }
    out
}

/// `an Identity`, `a RootPki`.
fn expected(name: &str) -> String {
    let article = if name.starts_with(['A', 'E', 'I', 'O', 'U']) { "an" } else { "a" };
    format!("{article} {name}")
}

pub fn expand(attr: TokenStream, item: TokenStream) -> Result<TokenStream> {
    let options = class_options(attr)?;
    let mut block: ItemImpl = syn::parse2(item)?;
    if block.trait_.is_some() {
        return Err(syn::Error::new(block.span(), "#[class] goes on an inherent impl block (`impl RootPki { .. }`), not a trait impl"));
    }
    if !block.generics.params.is_empty() || block.generics.where_clause.is_some() {
        return Err(syn::Error::new(block.generics.span(), "a #[class] type cannot be generic"));
    }
    let Type::Path(self_path) = &*block.self_ty else {
        return Err(syn::Error::new(block.self_ty.span(), "#[class] needs a named type: `impl RootPki { .. }`"));
    };
    let type_ident = self_path.path.segments.last().map(|segment| segment.ident.clone()).expect("a path has a segment");
    let class_name = options.path.split_once('.').map(|(_, name)| name.to_owned()).expect("checked by path_of");
    if !class_name.starts_with(|c: char| c.is_ascii_uppercase()) {
        return Err(syn::Error::new(Span::call_site(), "a class name starts with a capital letter: path = \"namespace.ClassName\""));
    }

    let mut raws = Vec::new();
    let mut members = Vec::new();
    for item in &mut block.items {
        let ImplItem::Fn(func) = item else { continue };
        let found = member_options(func)?;
        let sig = &func.sig;
        let receiver = sig.inputs.iter().find_map(|input| match input {
            FnArg::Receiver(receiver) => Some(receiver),
            FnArg::Typed(_) => None,
        });
        let member = match (found, receiver) {
            (Some(member), _) => member,
            (None, Some(_)) => MemberOptions { kind: Kind::Method, name: None, side_effect: None, promise: false },
            (None, None) => {
                return Err(syn::Error::new(
                    sig.ident.span(),
                    "a #[class] fn without `&self` must be marked #[static_method]; put helpers in another impl block",
                ));
            }
        };
        match (member.kind, receiver) {
            (Kind::Static, Some(receiver)) => {
                return Err(syn::Error::new(receiver.span(), "a #[static_method] takes no `self`"));
            }
            (Kind::Method | Kind::Getter, None) => {
                return Err(syn::Error::new(sig.span(), "a method or getter takes `&self`"));
            }
            (Kind::Method | Kind::Getter, Some(receiver)) if receiver.reference.is_none() || receiver.mutability.is_some() => {
                return Err(syn::Error::new(
                    receiver.span(),
                    "a member takes `&self`: the value is shared with the garbage collector, so mutation goes through a Cell/RefCell",
                ));
            }
            _ => {}
        }
        let generic = sig.generics.params.iter().any(|param| !matches!(param, syn::GenericParam::Lifetime(_)));
        if generic || sig.generics.where_clause.is_some() {
            return Err(syn::Error::new(sig.generics.span(), "a #[class] member cannot be generic (lifetime parameters are fine)"));
        }
        if sig.constness.is_some() || sig.unsafety.is_some() || sig.abi.is_some() || sig.variadic.is_some() {
            return Err(syn::Error::new(sig.span(), "a #[class] member must be a plain fn"));
        }
        if sig.asyncness.is_some() && !member.promise {
            return Err(syn::Error::new(sig.span(), "an async member needs the `promise` option: #[method(promise)]"));
        }
        if member.promise && matches!(sig.output, ReturnType::Default) {
            return Err(syn::Error::new(sig.span(), "a `promise` member returns a future (`impl Future<Output = ..>`) or an `Op`"));
        }
        let what = format!("member `{}`", sig.ident);
        let params = parameters(&sig.inputs, &what, false)?;
        if member.kind == Kind::Getter && js_length(&params) != 0 {
            return Err(syn::Error::new(sig.inputs.span(), "a getter takes no JS arguments"));
        }

        let rust_name = &sig.ident;
        let js_name = member.name.unwrap_or_else(|| camel_case(&rust_name.to_string()));
        let raw = format_ident!("__origine_member_{}", rust_name);
        let receiver = (member.kind != Kind::Static).then(|| {
            quote! { let __this: &Self = ::origine_api::class::receiver::<Self>(scope, args, #js_name)?; }
        });
        let body = call_body(quote!(Self::#rust_name), &params, member.promise, receiver);
        raws.push(quote! {
            #[doc(hidden)]
            #[doc = "The V8 callback of the member of the same name."]
            #[doc = ""]
            #[doc = "# Safety"]
            #[doc = ""]
            #[doc = "Only V8 may call this, as a function callback; `info` must be the pointer V8 passed."]
            unsafe extern "C" fn #raw(info: *const ::origine_api::v8::FunctionCallbackInfo) {
                // SAFETY: forwarded from this function's contract: `info` is the callback info V8 passed.
                unsafe {
                    ::origine_api::native::run_sync(info, |scope, args| {
                        #body
                    })
                }
            }
        });
        let kind = format_ident!(
            "{}",
            match member.kind {
                Kind::Static => "Static",
                Kind::Method => "Method",
                Kind::Getter => "Getter",
            }
        );
        let side_effect =
            format_ident!("{}", member.side_effect.unwrap_or(if member.kind == Kind::Getter { "None" } else { options.side_effect }));
        let length = i32::try_from(js_length(&params)).expect("few arguments");
        members.push(quote! {
            ::origine_api::class::Member {
                name: #js_name,
                kind: ::origine_api::class::MemberKind::#kind,
                callback: Self::#raw,
                side_effect: ::origine_api::native::SideEffect::#side_effect,
                length: #length,
            }
        });
    }

    let self_ty = &block.self_ty;
    let expected = expected(&class_name);
    let table = format_ident!("CLASS_{}", upper_snake(&type_ident.to_string()));
    let path = &options.path;
    let needs = format_ident!("{}", options.needs);
    Ok(quote! {
        #block

        impl #self_ty {
            #(#raws)*
        }

        impl ::origine_api::class::Class for #self_ty {
            const NAME: &'static str = #class_name;
            const EXPECTED: &'static str = #expected;
            const MEMBERS: &'static [::origine_api::class::Member] = &[#(#members),*];
        }

        /// An instance of the class: wrapped in a new object of the current realm.
        impl<'s> ::origine_api::IntoJs<'s> for #self_ty {
            fn into_js(
                self,
                scope: &mut ::origine_api::v8::PinScope<'s, '_>,
            ) -> ::core::result::Result<::origine_api::v8::Local<'s, ::origine_api::v8::Value>, ::origine_api::NativeError> {
                ::origine_api::class::wrap(scope, self)
            }
        }

        #[doc = "The installer of the class, for registration (`native.<namespace>.<Class>(failure, members?)`)."]
        pub(crate) const #table: ::origine_api::native::RawNative = ::origine_api::native::RawNative {
            callback: ::origine_api::class::install::<#self_ty>,
            side_effect: ::origine_api::native::SideEffect::Any,
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
    fn a_class_gets_members_an_installer_and_conversions() {
        let out = text(
            quote!(path = "tls.RootPki", side_effect = "any", needs = "runtime"),
            quote! {
                impl RootPki {
                    /// Docs stay.
                    #[static_method(name = "fromPem")]
                    fn from_pem(pem: ArrayBufferArg<'_>) -> Result<RootPki, NativeError> { todo!() }
                    #[static_method]
                    fn bundled() -> RootPki { todo!() }
                    fn release(&self) {}
                    #[getter]
                    fn closed(&self, host: &HostState) -> bool { true }
                }
            },
        );
        assert!(out.contains("const NAME : & 'static str = \"RootPki\""), "{out}");
        assert!(out.contains("const EXPECTED : & 'static str = \"a RootPki\""), "{out}");
        assert!(out.contains("name : \"fromPem\""), "{out}");
        assert!(out.contains("name : \"bundled\""), "{out}");
        assert!(out.contains("MemberKind :: Getter"), "{out}");
        assert!(out.contains("CLASS_ROOT_PKI"), "{out}");
        assert!(out.contains("class :: install :: < RootPki >"), "{out}");
        assert!(out.contains("path : \"tls.RootPki\""), "{out}");
        assert!(out.contains("Needs :: Runtime"), "{out}");
        assert!(out.contains("receiver :: < Self > (scope , args , \"release\")"), "{out}");
        assert!(out.contains("Self :: release (__this)"), "{out}");
        assert!(out.contains("Self :: closed (__this , __host)"), "{out}");
        assert!(!out.contains("# [static_method"), "{out}");
        // A getter defaults to no side effect, a method to the class's.
        let getter = out.find("name : \"closed\"").unwrap();
        assert!(out[getter..].contains("SideEffect :: None"), "{out}");
        assert!(out.contains("length : 1i32"), "{out}");
    }

    #[test]
    fn promise_members_and_names() {
        let out = text(
            quote!(path = "dns.Resolver", side_effect = "any"),
            quote! {
                impl ResolverHandle {
                    #[method(promise, side_effect = "receiver")]
                    fn lookup_all(&self, name: String) -> impl Future<Output = Result<u32, NativeError>> { async { Ok(1) } }
                }
            },
        );
        assert!(out.contains("name : \"lookupAll\""), "{out}");
        assert!(out.contains("native :: promise"), "{out}");
        assert!(out.contains("SideEffect :: Receiver"), "{out}");
        assert!(out.contains("CLASS_RESOLVER_HANDLE"), "{out}");
        assert!(out.contains("\"Resolver\""), "{out}");
        assert!(out.contains("\"an Identity\"") || expected("Identity") == "an Identity");
    }

    #[test]
    fn class_errors_are_reported() {
        let item = || quote! { impl T {} };
        assert!(error(quote!(side_effect = "any"), item()).contains("needs a path"));
        assert!(error(quote!(path = "t.T"), item()).contains("explicit side_effect"));
        assert!(error(quote!(path = "t.lower", side_effect = "any"), item()).contains("capital"));
        assert!(error(quote!(path = "t.T", side_effect = "any", bogus), item()).contains("expected"));
        let attr = || quote!(path = "t.T", side_effect = "any");
        assert!(error(attr(), quote! { impl Tr for T {} }).contains("inherent"));
        assert!(error(attr(), quote! { impl<X> T<X> {} }).contains("generic"));
        assert!(error(attr(), quote! { impl T { fn helper() {} } }).contains("#[static_method]"));
        assert!(error(attr(), quote! { impl T { #[static_method] fn f(&self) {} } }).contains("no `self`"));
        assert!(error(attr(), quote! { impl T { fn f(&mut self) {} } }).contains("Cell"));
        assert!(error(attr(), quote! { impl T { fn f(self) {} } }).contains("Cell"));
        assert!(error(attr(), quote! { impl T { #[getter] fn g(&self, x: u32) -> u32 { x } } }).contains("no JS arguments"));
        assert!(error(attr(), quote! { impl T { #[getter(promise)] fn g(&self) -> u32 { 1 } } }).contains("expected"));
        assert!(error(attr(), quote! { impl T { fn f(&self, key: ScopeKey) {} } }).contains("ScopeKey"));
        assert!(error(attr(), quote! { impl T { async fn f(&self) {} } }).contains("promise"));
        assert!(error(attr(), quote! { impl T { #[method] #[getter] fn f(&self) {} } }).contains("one of"));
    }

    #[test]
    fn constant_names() {
        assert_eq!(upper_snake("RootPki"), "ROOT_PKI");
        assert_eq!(upper_snake("TlsSessions"), "TLS_SESSIONS");
        assert_eq!(upper_snake("Resolver"), "RESOLVER");
        assert_eq!(upper_snake("ResolverHandle"), "RESOLVER_HANDLE");
        assert_eq!(expected("Identity"), "an Identity");
    }
}
