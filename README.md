# origine

A Zig application embedding V8. The REPL entry point is `src/main.zig`;
`lib/v8_zig` is a local Zig package providing `@v8`, `@engine`, `@managed`,
`@util`, `@mimalloc`, and `@diagnostics` modules.

```sh
zig build
zig build run
zig build run -- path/to/script.js
zig build -Doptimize=small
zig build test
```

With a file argument, origine evaluates that JavaScript file and exits. Without
one, it starts the interactive REPL.

The executable is installed at `zig-out/bin/origine`. Darwin release builds use
V8's matching `ld64.lld` with ThinLTO and identical-code folding; debug builds
cache native archive conversion.

V8 is always built from source by the same command: the patch series in
`lib/v8_zig/build-tools/patches/` is applied automatically and ninja keeps rebuilds
incremental, so a patch edit is picked up by the next `zig build` with nothing to
install or copy. V8 is **release** by default for every application mode, because a
debug V8 makes the shell slow. The application optimization mode (`-Doptimize`)
controls only the executable. While changing V8 or its patches, pass `-Dv8_debug=true`
(or `just v8-dev`) for quick incremental V8 compiles; debug and release V8 keep
separate build directories, so switching back does not rebuild. `zig build patch-v8`
fetches V8 and applies the patches without building, ready for editing.

Reuse an existing archive with `-Dprebuilt_v8_path=/absolute/path/libv8_zig.a`.
`-Dv8_clang_dir=/path/to/llvm/bin` overrides the matching LLVM toolchain and
`-Dcache_root=/path/to/cache` selects the V8 checkout cache.

Full build documentation, including the V8 development loop, is in [docs/BUILD.md](docs/BUILD.md). For all other documentation, see [DOCS.md](DOCS.md).

The V8 package retains its own Git history, tests, build tooling, and documentation.
Run package-specific commands from `lib/v8_zig`; run the application from here.
