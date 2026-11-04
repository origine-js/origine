//! `api.http.fields`: `HeaderList`, a Rust-defined class over `origine_h2::FieldList`: an ordered sequence of
//! header fields, duplicates kept, validated natively when a field is put (lowercase token names, no NUL, CR or LF
//! in values, no connection-specific field, pseudo header fields only before the others). A list the session
//! received is sealed: `put` on it is a `TypeError`.

use std::cell::RefCell;

use origine_api_core::{ArgError, NativeError};
use origine_h2::FieldList;

use crate::{FromJs, class};

/// A `[name, value]` pair of `HeaderList.of`.
struct Pair(String, String);

impl<'s> FromJs<'s> for Pair {
    fn from_js(scope: &mut v8::PinScope<'s, '_>, value: v8::Local<'s, v8::Value>, index: usize) -> Result<Self, ArgError> {
        let expected = || ArgError::new(index, "a [name, value] pair of strings");
        let pair = Vec::<String>::from_js(scope, value, index).map_err(|_| expected())?;
        match <[String; 2]>::try_from(pair) {
            Ok([name, value]) => Ok(Pair(name, value)),
            Err(_) => Err(expected()),
        }
    }
}

/// An ordered list of header fields (`api.http.fields`).
pub(crate) struct HeaderList {
    list: RefCell<FieldList>,
    sealed: bool,
}

impl HeaderList {
    /// A sealed list of fields a session received.
    pub(crate) fn received(list: FieldList) -> HeaderList {
        HeaderList { list: RefCell::new(list), sealed: true }
    }

    /// A copy of the fields.
    pub(crate) fn fields(&self) -> FieldList {
        self.list.borrow().clone()
    }
}

fn text(bytes: &[u8]) -> String {
    String::from_utf8_lossy(bytes).into_owned()
}

#[class(path = "http.HeaderList", side_effect = "any", needs = "runtime")]
impl HeaderList {
    /// A new list of `pairs` (`[name, value]`, in order; an empty array for an empty list). `InvalidInput` for a
    /// field `put` would refuse.
    #[static_method]
    fn of(pairs: Vec<Pair>) -> Result<HeaderList, NativeError> {
        let mut list = FieldList::new();
        for Pair(name, value) in pairs {
            list.put(name.as_bytes(), value.as_bytes()).map_err(crate::http::h2_error)?;
        }
        Ok(HeaderList { list: RefCell::new(list), sealed: false })
    }

    /// Appends a field (checked; `InvalidInput` for a bad one). `TypeError` on a received list.
    fn put(&self, name: String, value: String) -> Result<(), NativeError> {
        if self.sealed {
            return Err(NativeError::type_error("a received HeaderList cannot be changed"));
        }
        self.list.borrow_mut().put(name.as_bytes(), value.as_bytes()).map_err(crate::http::h2_error)
    }

    /// The first value of `name` (compared in lowercase), or `undefined`.
    fn get(&self, name: String) -> Option<String> {
        self.list.borrow().get(&name.to_ascii_lowercase()).map(text)
    }

    /// Every value of `name`, in order.
    #[method(name = "getAll")]
    fn get_all<'s>(&self, scope: &mut v8::PinScope<'s, '_>, name: String) -> v8::Local<'s, v8::Value> {
        let name = name.to_ascii_lowercase();
        let values: Vec<v8::Local<v8::Value>> =
            self.list.borrow().get_all(&name).filter_map(|value| v8::String::new(scope, &text(value)).map(Into::into)).collect();
        let array = v8::Array::new_with_elements(scope, &values);
        array.set_integrity_level(scope, v8::IntegrityLevel::Frozen);
        array.into()
    }

    fn has(&self, name: String) -> bool {
        self.list.borrow().get(&name.to_ascii_lowercase()).is_some()
    }

    /// The number of fields.
    #[getter]
    fn length(&self) -> usize {
        self.list.borrow().len()
    }

    /// The fields as a frozen array of frozen `[name, value]` pairs, in order (what `[Symbol.iterator]` yields).
    fn entries<'s>(&self, scope: &mut v8::PinScope<'s, '_>) -> v8::Local<'s, v8::Value> {
        let mut pairs = Vec::with_capacity(self.list.borrow().len());
        for (name, value) in self.list.borrow().iter() {
            let (Some(name), Some(value)) = (v8::String::new(scope, &text(name)), v8::String::new(scope, &text(value))) else { continue };
            let pair = v8::Array::new_with_elements(scope, &[name.into(), value.into()]);
            pair.set_integrity_level(scope, v8::IntegrityLevel::Frozen);
            pairs.push(pair.into());
        }
        let array = v8::Array::new_with_elements(scope, &pairs);
        array.set_integrity_level(scope, v8::IntegrityLevel::Frozen);
        array.into()
    }
}
