//! Pure-Rust core of the guest API natives: option parsing and handle tables, with no V8
//! dependency so `just check-rust` can run it under Miri. `origine_api` binds it to V8.

pub mod arg;
pub mod errno;
pub mod error;
pub mod net_rules;
pub mod pin;
pub mod slab;
pub mod table;

pub use arg::ArgError;
pub use error::NativeError;
pub use net_rules::NetRules;

/// An I/O backend that runs: what `api.io.create` resolved to and what `Io.backend` reports. Never `auto`; see
/// [`BackendChoice`] for what a guest asks for.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Backend {
    Uring,
    Kqueue,
    Threaded,
}

impl Backend {
    /// Parses the guest-visible name of a running backend; `None` for an unknown name (and for `auto`, which is a
    /// [`BackendChoice`]).
    pub fn parse(name: &str) -> Option<Backend> {
        match name {
            "uring" => Some(Backend::Uring),
            "kqueue" => Some(Backend::Kqueue),
            "threaded" => Some(Backend::Threaded),
            _ => None,
        }
    }

    /// The guest-visible name (the inverse of [`Backend::parse`]).
    pub fn name(self) -> &'static str {
        match self {
            Backend::Uring => "uring",
            Backend::Kqueue => "kqueue",
            Backend::Threaded => "threaded",
        }
    }

    /// The `backends_mask` bit of the backend (`1 << kind` with kind 1 uring, 2 kqueue, 4
    /// threaded; the numbering of `io.Backend`).
    pub fn mask_bit(self) -> u32 {
        match self {
            Backend::Uring => 1 << 1,
            Backend::Kqueue => 1 << 2,
            Backend::Threaded => 1 << 4,
        }
    }
}

/// The backend a guest asks for (`api.io.create({ backend })`): `auto` lets the runtime pick, which it resolves to a
/// [`Backend`].
#[derive(Clone, Copy, Debug, Default, PartialEq, Eq)]
pub enum BackendChoice {
    #[default]
    Auto,
    Named(Backend),
}

impl BackendChoice {
    /// Parses the guest-visible name, `auto` included; `None` for an unknown name.
    pub fn parse(name: &str) -> Option<BackendChoice> {
        match name {
            "auto" => Some(BackendChoice::Auto),
            other => Backend::parse(other).map(BackendChoice::Named),
        }
    }

    /// The guest-visible name (the inverse of [`BackendChoice::parse`]).
    pub fn name(self) -> &'static str {
        match self {
            BackendChoice::Auto => "auto",
            BackendChoice::Named(backend) => backend.name(),
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
    /// `PermissionDenied` when the count ceiling is reached and `Unsupported` for a backend the
    /// embedder excluded.
    pub fn check_create(&self, live: usize, choice: BackendChoice) -> Result<(), u32> {
        let allowed = match choice {
            BackendChoice::Auto => self.backends_mask != 0,
            BackendChoice::Named(backend) => self.backends_mask & backend.mask_bit() != 0,
        };
        if !allowed {
            return Err(errno::UNSUPPORTED);
        }
        if live >= self.max_runtimes as usize {
            return Err(errno::PERMISSION_DENIED);
        }
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn backend_names_round_trip() {
        for backend in [Backend::Uring, Backend::Kqueue, Backend::Threaded] {
            assert_eq!(Backend::parse(backend.name()), Some(backend));
            assert_eq!(BackendChoice::parse(backend.name()), Some(BackendChoice::Named(backend)));
        }
        assert_eq!(BackendChoice::parse("auto"), Some(BackendChoice::Auto));
        assert_eq!(Backend::parse("auto"), None);
        assert_eq!(BackendChoice::parse("epoll"), None);
    }

    #[test]
    fn the_ceiling_limits_count_and_backends() {
        let ceiling =
            Ceiling { max_runtimes: 2, backends_mask: Backend::Threaded.mask_bit() | Backend::Kqueue.mask_bit(), default_entries: 8 };
        assert_eq!(ceiling.check_create(0, BackendChoice::Auto), Ok(()));
        assert_eq!(ceiling.check_create(1, BackendChoice::Named(Backend::Threaded)), Ok(()));
        assert_eq!(ceiling.check_create(2, BackendChoice::Named(Backend::Threaded)), Err(errno::PERMISSION_DENIED));
        assert_eq!(ceiling.check_create(0, BackendChoice::Named(Backend::Uring)), Err(errno::UNSUPPORTED));
        // A backend refusal wins over the count.
        assert_eq!(ceiling.check_create(5, BackendChoice::Named(Backend::Uring)), Err(errno::UNSUPPORTED));
        assert_eq!(Ceiling::NONE.check_create(0, BackendChoice::Auto), Err(errno::UNSUPPORTED));
    }
}
