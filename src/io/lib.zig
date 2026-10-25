//! Root of `liborigine_io.a`: the I/O library's C ABI (`oio_*`), always built with
//! ReleaseFast (see build.zig). Programs link the archive; only this root references
//! `c_api`, so the Zig-side `@io` module never exports a second copy of the symbols.
comptime {
    _ = @import("@io").c_api;
}
