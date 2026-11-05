"""Per-module optimization: one plain flag per module in //build/bazel/opt, set by build/bazel/build.py.

Bazel knows no profiles: build.py states the mode of every module on each invocation
(`--//build/bazel/opt:<module>=<mode>`); the defaults here are what `dev` sets, so a plain
`bazel build` builds the same thing. A module is a Zig library (debug|safe|fast|small, `-O<mode>`)
a Rust crate (0|1|2|3|s|z, `-Copt-level=<v>`, with debug assertions at 0) or a C/C++ library
(inherit|0|1|2|3|s|z, `-O<level>`; `c_<library>`).
"""

# Zig module -> default mode.
ZIG_MODULES = {
    "safe": "fast",
    "io": "fast",
    "io_native": "fast",
    "v8": "fast",
    "util": "fast",
    "diagnostics": "fast",
    "mimalloc": "safe",
    "lz4": "small",
    "engine": "debug",
    "managed": "debug",
    "origine_main": "debug",
    "snapshot_tool_main": "debug",
}

ZIG_MODES = ["debug", "safe", "fast", "small"]

# Rust crate -> default opt level.
RUST_CRATES = {
    "origine_io": "3",
    "origine_alloc": "3",
    "origine_oxc": "3",
    "origine_tls": "3",
    "origine_h2": "3",
    "origine_dns": "3",
    "origine_transport": "3",
    "rusty_v8": "3",
    "origine_api": "0",
    "origine_api_core": "0",
    "origine_api_fs": "0",
    "origine_repl": "0",
    "origine_native": "0",
}

RUST_LEVELS = ["0", "1", "2", "3", "s", "z"]

# C/C++ library -> default level: "inherit" adds nothing, so `--compilation_mode` decides (`-O2
# -DNDEBUG` with opt, `-O0 -g` with dbg); any other level adds `-O<level>` after it. Each entry is one
# library built from source here (one flag each, never shared): v8 (V8 and everything it compiles in
# its own package: the binding shim, Torque, mksnapshot, simdutf, ...), icu, libcxx (libc++ and
# libc++abi), mimalloc, lz4, nghttp2, zstd (the ICU data decoder), icu_compressed and icu_raw (the
# two ICU data providers of lib/v8_zig/binding), aws_lc (crypto, s2n-bignum and ssl; jitterentropy
# stays -O0 as upstream requires). The `abseil-cpp` and `highway` modules have none: they follow
# `--compilation_mode`.
C_LIBRARIES = {
    "v8": "inherit",
    "icu": "inherit",
    "libcxx": "inherit",
    "mimalloc": "inherit",
    "lz4": "inherit",
    "nghttp2": "inherit",
    "zstd": "s",
    "icu_compressed": "s",
    "icu_raw": "inherit",
    "aws_lc": "inherit",
}

C_LEVELS = ["inherit", "0", "1", "2", "3", "s", "z"]

def c_opt(library):
    """`copts` for a C/C++ library: its `-O<level>`, or nothing for "inherit". Put it last in `copts`."""
    return select({
        Label("//build/bazel/opt:c_{}_{}".format(library, level)): ([] if level == "inherit" else ["-O" + level])
        for level in C_LEVELS
    })

def zig_opt(module):
    """`zigopts` for a Zig module: its `-O<mode>`."""
    return select({
        "//build/bazel/opt:{}_{}".format(module, mode): ["-O" + mode]
        for mode in ZIG_MODES
    })

def rust_opt(crate):
    """`rustc_flags` for a Rust crate: its `-Copt-level` (and debug assertions at 0)."""
    return select({
        "//build/bazel/opt:{}_{}".format(crate, level): ["-Copt-level=" + level] + (["-Cdebug-assertions=on"] if level == "0" else [])
        for level in RUST_LEVELS
    })
