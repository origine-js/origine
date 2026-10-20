//! `#[derive(FromJs)]` and `#[derive(IntoJs)]` for plain structs with named fields.

use origine_api_core::arg::camel_case;
use proc_macro2::TokenStream;
use quote::quote;
use syn::{DeriveInput, Field, Fields, LitStr, Result, spanned::Spanned};

/// The named fields of a non-generic struct.
fn named_fields(input: &DeriveInput) -> Result<&syn::punctuated::Punctuated<Field, syn::Token![,]>> {
    if !input.generics.params.is_empty() {
        return Err(syn::Error::new(input.generics.span(), "FromJs/IntoJs structs cannot be generic"));
    }
    match &input.data {
        syn::Data::Struct(data) => match &data.fields {
            Fields::Named(fields) => Ok(&fields.named),
            _ => Err(syn::Error::new(input.span(), "FromJs/IntoJs need a struct with named fields")),
        },
        _ => Err(syn::Error::new(input.span(), "FromJs/IntoJs can only be derived for structs")),
    }
}

/// The JS property name of `field`: `#[js(name = "x")]` or the camelCase of the Rust name.
fn js_name(field: &Field) -> Result<String> {
    let mut name = None;
    for attr in field.attrs.iter().filter(|attr| attr.path().is_ident("js")) {
        attr.parse_nested_meta(|meta| {
            if meta.path.is_ident("name") {
                name = Some(meta.value()?.parse::<LitStr>()?.value());
                Ok(())
            } else {
                Err(meta.error("expected `name = \"...\"`"))
            }
        })?;
    }
    let ident = field.ident.as_ref().expect("named field");
    Ok(name.unwrap_or_else(|| camel_case(&ident.to_string())))
}

pub fn from_js(input: TokenStream) -> Result<TokenStream> {
    let input: DeriveInput = syn::parse2(input)?;
    let fields = named_fields(&input)?;
    let name = &input.ident;
    let mut reads = Vec::new();
    for field in fields {
        let ident = field.ident.as_ref().expect("named field");
        let key = js_name(field)?;
        reads.push(quote! { #ident: ::origine_api::decode::property(scope, object, #key, index)? });
    }
    Ok(quote! {
        impl<'s> ::origine_api::FromJs<'s> for #name {
            fn from_js(
                scope: &mut ::origine_api::v8::PinScope<'s, '_>,
                value: ::origine_api::v8::Local<'s, ::origine_api::v8::Value>,
                index: usize,
            ) -> ::core::result::Result<Self, ::origine_api::ArgError> {
                let object = ::origine_api::decode::object_arg(value, index)?;
                ::core::result::Result::Ok(Self { #(#reads),* })
            }
        }
    })
}

pub fn into_js(input: TokenStream) -> Result<TokenStream> {
    let input: DeriveInput = syn::parse2(input)?;
    let fields = named_fields(&input)?;
    let name = &input.ident;
    let mut writes = Vec::new();
    for field in fields {
        let ident = field.ident.as_ref().expect("named field");
        let key = js_name(field)?;
        writes.push(quote! { ::origine_api::encode::set(scope, object, #key, self.#ident)?; });
    }
    Ok(quote! {
        impl<'s> ::origine_api::IntoJs<'s> for #name {
            fn into_js(
                self,
                scope: &mut ::origine_api::v8::PinScope<'s, '_>,
            ) -> ::core::result::Result<::origine_api::v8::Local<'s, ::origine_api::v8::Value>, ::origine_api::NativeError> {
                let object = ::origine_api::encode::new_object(scope);
                #(#writes)*
                ::origine_api::encode::freeze(scope, object)
            }
        }
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use quote::quote;

    fn text(tokens: Result<TokenStream>) -> String {
        tokens.expect("expands").to_string()
    }

    #[test]
    fn from_js_reads_camel_case_properties() {
        let out = text(from_js(quote! { struct Opts { max_runtimes: Option<u32>, #[js(name = "kind")] backend: String } }));
        assert!(out.contains("\"maxRuntimes\""), "{out}");
        assert!(out.contains("\"kind\""), "{out}");
        assert!(out.contains("decode :: property"), "{out}");
    }

    #[test]
    fn into_js_writes_and_freezes() {
        let out = text(into_js(quote! { struct Handle { kind: &'static str, id: u32 } }));
        assert!(out.contains("encode :: set (scope , object , \"kind\" , self . kind)"), "{out}");
        assert!(out.contains("encode :: freeze"), "{out}");
    }

    #[test]
    fn unsupported_shapes_are_rejected() {
        assert!(from_js(quote! { struct T(u32); }).is_err());
        assert!(from_js(quote! { enum E { A } }).is_err());
        assert!(into_js(quote! { struct G<T> { x: T } }).is_err());
        assert!(from_js(quote! { struct Bad { #[js(rename = "x")] a: u32 } }).is_err());
    }
}
