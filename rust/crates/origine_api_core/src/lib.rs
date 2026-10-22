//! Pure-Rust core of the guest API natives: option parsing and handle tables, with no V8
//! dependency so `just check-rust` can run it under Miri. `origine_api` binds it to V8.

pub mod arg;
pub mod errno;
pub mod error;
pub mod pin;
pub mod slab;
pub mod table;

pub use arg::ArgError;
pub use error::NativeError;

/// An I/O backend a guest may ask for (`api.io.create({ backend })`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Auto,
    Uring,
    Kqueue,
    Threaded,
}

impl Backend {
    /// Parses the guest-visible backend name; `None` for an unknown name.
    pub fn parse(name: &str) -> Option<Backend> {
        match name {
            "auto" => Some(Backend::Auto),
            "uring" => Some(Backend::Uring),
            "kqueue" => Some(Backend::Kqueue),
            "threaded" => Some(Backend::Threaded),
            _ => None,
        }
    }

    /// The guest-visible name (the inverse of [`Backend::parse`]).
    pub fn name(self) -> &'static str {
        match self {
            Backend::Auto => "auto",
            Backend::Uring => "uring",
            Backend::Kqueue => "kqueue",
            Backend::Threaded => "threaded",
        }
    }
}

impl Backend {
    /// The `backends_mask` bit of the backend (`1 << kind` with kind 1 uring, 2 kqueue, 4
    /// threaded; the numbering of `io.Backend`). `Auto` has no bit of its own.
    pub fn mask_bit(self) -> u32 {
        match self {
            Backend::Auto => 0,
            Backend::Uring => 1 << 1,
            Backend::Kqueue => 1 << 2,
            Backend::Threaded => 1 << 4,
        }
    }
}

/// What the embedder allows `api.io.create` to do (`origine_api_configure`).
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub struct Ceiling {
    /// Live runtimes allowed per Host.
    pub max_runtimes: u32,
    /// Allowed backends, see [`Backend::mask_bit`].
    pub backends_mask: u32,
    /// Queue depth for `create` without `entries`.
    pub default_entries: u32,
}

impl Ceiling {
    /// Nothing is allowed (the state before the embedder configured the Host).
    pub const NONE: Ceiling = Ceiling { max_runtimes: 0, backends_mask: 0, default_entries: 0 };

    /// Whether a runtime on `backend` may be created while `live` exist: `Err(errno)` with
    /// `AccessDenied` when the count ceiling is reached and `Unsupported` for a backend the
    /// embedder excluded.
    pub fn check_create(&self, live: usize, backend: Backend) -> Result<(), u32> {
        let allowed = match backend {
            Backend::Auto => self.backends_mask != 0,
            other => self.backends_mask & other.mask_bit() != 0,
        };
        if !allowed {
            return Err(errno::UNSUPPORTED);
        }
        if live >= self.max_runtimes as usize {
            return Err(errno::ACCESS_DENIED);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backend_names_round_trip() {
        for backend in [Backend::Auto, Backend::Uring, Backend::Kqueue, Backend::Threaded] {
            assert_eq!(Backend::parse(backend.name()), Some(backend));
        }
        assert_eq!(Backend::parse("epoll"), None);
    }

    #[test]
    fn the_ceiling_limits_count_and_backends() {
        let ceiling =
            Ceiling { max_runtimes: 2, backends_mask: Backend::Threaded.mask_bit() | Backend::Kqueue.mask_bit(), default_entries: 8 };
        assert_eq!(ceiling.check_create(0, Backend::Auto), Ok(()));
        assert_eq!(ceiling.check_create(1, Backend::Threaded), Ok(()));
        assert_eq!(ceiling.check_create(2, Backend::Threaded), Err(errno::ACCESS_DENIED));
        assert_eq!(ceiling.check_create(0, Backend::Uring), Err(errno::UNSUPPORTED));
        // A backend refusal wins over the count.
        assert_eq!(ceiling.check_create(5, Backend::Uring), Err(errno::UNSUPPORTED));
        assert_eq!(Ceiling::NONE.check_create(0, Backend::Auto), Err(errno::UNSUPPORTED));
    }
}
