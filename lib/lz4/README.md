# lz4

LZ4 1.10.0 (`lz4.c`, `lz4hc.c` from the pinned upstream release) built by the Zig build system,
with a Zig wrapper (`src/lz4.zig`). Origine uses it, opt in per blob, for the embedded engine snapshot
(`-Dengine_snapshot=compressed`: the build-time snapshot tool packs with the HC compressor, the
shell expands at startup) and the on-disk caches (`-Duser_snapshot=compressed`,
`-Duser_codecache=compressed`). The C ABI is
private to the wrapper; hosts import the module `@lz4`.

- Artifact `lz4` (static library) and module `@lz4`; the consumer links the artifact.
- `zig build test` (in this directory) runs the wrapper tests, including random garbage through
  the decoder.
- Chosen over zstd (about 1 ms cold decode for the snapshot) and Brotli (slower still): about 0.15 ms
  cold, 1.5 KB of decoder code.
