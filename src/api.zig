//! The guest-visible `api` (env, fs, io, scope) and the typed binding layer behind it.
//!
//! - `Host` owns authority and drives the init -> `main(api)` lifecycle.
//! - `binding` / `Call` are the DX for writing JS-native functions as ordinary typed
//!   Zig functions; see src/api/binding.zig.
//! - The guest side lives in src/js/ (`glue/` and the `origine:@std/*` modules).
pub const Host = @import("api/host.zig").Host;
pub const Config = @import("api/host.zig").Config;
pub const FsConfig = @import("api/host.zig").FsConfig;
pub const RuntimeConfig = @import("api/host.zig").RuntimeConfig;
pub const EnvPair = @import("api/env.zig").Pair;
pub const Errno = @import("api/errno.zig").Errno;
pub const errnoOf = @import("api/errno.zig").of;
pub const errnoOfFs = @import("api/errno.zig").ofFs;
pub const Error = @import("api/errno.zig").Error;
pub const narrowError = @import("api/errno.zig").narrow;
/// `errno.zig` itself, for `isBinding` / `requireBinding` (named to avoid the `errno` cell).
pub const binding_errors = @import("api/errno.zig");
pub const errno_module_source = @import("api/errno.zig").module_source;
pub const binding = @import("api/binding.zig");
pub const Call = @import("api/call.zig").Call;
pub const std_io_id = @import("api/std/io.zig").id;
pub const std_io_source = @import("api/std/io.zig").source;
pub const std_modules = @import("api/init_loader.zig").std_modules;
pub const module = @import("api/module.zig");
pub const transformer = @import("api/transform/transformer.zig");
pub const oxc = @import("api/transform/oxc.zig");
pub const transformers = @import("api/transform/transformers.zig");
