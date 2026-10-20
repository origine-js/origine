//! Argument decoding that needs no V8: the error type and the number range rules shared by the
//! `FromJs` implementations in `origine_api` (mirrors `decode` in `src/api/binding.zig`).

use std::borrow::Cow;
use std::fmt;

/// The largest integer a JS number holds exactly (2^53 - 1); `u64` arguments above it are rejected.
pub const MAX_SAFE_INTEGER: u64 = (1 << 53) - 1;

/// A missing or mistyped argument. Displays as `argument N: expected X` (N is the 0-based
/// position in the native's JS argument list).
#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ArgError {
    /// 0-based JS argument position.
    pub index: usize,
    /// What was expected, e.g. `a string`.
    pub expected: Cow<'static, str>,
}

impl ArgError {
    /// An error for the argument at `index`.
    pub fn new(index: usize, expected: impl Into<Cow<'static, str>>) -> ArgError {
        ArgError { index, expected: expected.into() }
    }

    /// Narrows the error to a property of an option bag: `expected property `name` to be a string`.
    #[must_use]
    pub fn in_property(self, name: &str) -> ArgError {
        let expected = match self.expected.strip_prefix("property ") {
            // A nested bag: `property `a`.`b``.
            Some(rest) => format!("property `{name}.{}", rest.trim_start_matches('`')),
            None => format!("property `{name}` to be {}", self.expected),
        };
        ArgError { index: self.index, expected: Cow::Owned(expected) }
    }
}

impl fmt::Display for ArgError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "argument {}: expected {}", self.index, self.expected)
    }
}

impl std::error::Error for ArgError {}

/// `number` as a `u32` when it is an integer in `0..=u32::MAX`.
pub fn f64_to_u32(number: f64) -> Option<u32> {
    // The range check also rejects NaN and the infinities; `fract` rejects 1.5.
    if (0.0..=f64::from(u32::MAX)).contains(&number) && number.fract() == 0.0 { Some(number as u32) } else { None }
}

/// `number` as a `u64` when it is an integer in `0..=MAX_SAFE_INTEGER`.
pub fn f64_to_u64(number: f64) -> Option<u64> {
    if (0.0..=MAX_SAFE_INTEGER as f64).contains(&number) && number.fract() == 0.0 { Some(number as u64) } else { None }
}

/// A byte limit with `std.Io.Limit` semantics: `+Infinity` is unlimited (`usize::MAX`), otherwise a
/// non-negative number, truncated to an integer and clamped. `None` for NaN, negative numbers and
/// `-Infinity`.
pub fn f64_to_limit(number: f64) -> Option<usize> {
    if number.is_nan() || number < 0.0 {
        return None;
    }
    if number == f64::INFINITY {
        return Some(usize::MAX);
    }
    Some(number.min((usize::MAX / 2) as f64) as usize)
}

/// `value` as an `f64` that is exact in JS; `None` above [`MAX_SAFE_INTEGER`].
pub fn u64_to_f64(value: u64) -> Option<f64> {
    (value <= MAX_SAFE_INTEGER).then_some(value as f64)
}

/// The JS property name for a Rust field name: `snake_case` -> `camelCase`.
pub fn camel_case(name: &str) -> String {
    let mut out = String::with_capacity(name.len());
    let mut upper = false;
    for ch in name.trim_start_matches("r#").chars() {
        if ch == '_' {
            upper = !out.is_empty();
        } else if upper {
            out.extend(ch.to_uppercase());
            upper = false;
        } else {
            out.push(ch);
        }
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn u32_accepts_only_integers_in_range() {
        assert_eq!(f64_to_u32(0.0), Some(0));
        assert_eq!(f64_to_u32(4294967295.0), Some(u32::MAX));
        assert_eq!(f64_to_u32(4294967296.0), None);
        assert_eq!(f64_to_u32(-1.0), None);
        assert_eq!(f64_to_u32(1.5), None);
        assert_eq!(f64_to_u32(f64::NAN), None);
        assert_eq!(f64_to_u32(f64::INFINITY), None);
    }

    #[test]
    fn u64_stops_at_the_safe_integer_limit() {
        assert_eq!(f64_to_u64(9007199254740991.0), Some(MAX_SAFE_INTEGER));
        assert_eq!(f64_to_u64(9007199254740992.0), None);
        assert_eq!(f64_to_u64(-0.5), None);
        assert_eq!(f64_to_u64(f64::NAN), None);
        assert_eq!(u64_to_f64(MAX_SAFE_INTEGER), Some(9007199254740991.0));
        assert_eq!(u64_to_f64(MAX_SAFE_INTEGER + 1), None);
    }

    #[test]
    fn limits_follow_std_io_limit() {
        assert_eq!(f64_to_limit(0.0), Some(0));
        assert_eq!(f64_to_limit(10.9), Some(10));
        assert_eq!(f64_to_limit(f64::INFINITY), Some(usize::MAX));
        assert!(f64_to_limit(1e300).is_some_and(|limit| (usize::MAX / 2..usize::MAX).contains(&limit)));
        assert_eq!(f64_to_limit(-1.0), None);
        assert_eq!(f64_to_limit(f64::NEG_INFINITY), None);
        assert_eq!(f64_to_limit(f64::NAN), None);
    }

    #[test]
    fn messages_name_the_argument_and_property() {
        let err = ArgError::new(2, "a string");
        assert_eq!(err.to_string(), "argument 2: expected a string");
        let err = err.in_property("backend");
        assert_eq!(err.to_string(), "argument 2: expected property `backend` to be a string");
        let err = err.in_property("opts");
        assert_eq!(err.to_string(), "argument 2: expected property `opts.backend` to be a string");
    }

    #[test]
    fn camel_case_converts_snake_case() {
        assert_eq!(camel_case("backend"), "backend");
        assert_eq!(camel_case("max_runtimes"), "maxRuntimes");
        assert_eq!(camel_case("r#type"), "type");
        assert_eq!(camel_case("_x_y_"), "xY");
    }
}
