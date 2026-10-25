# Shell performance measurement

Build the shell with `zig build -Doptimize=small`.
With no arguments the shell creates one engine, one runtime and one empty managed scope
before entering the REPL. With an init file it also restores or creates the init snapshot
(see [api-design.md](api-design.md)) and calls `main(api)`.

## Startup tracing

Enable instrumentation with `V8_STARTUP_TRACE=1`:

```sh
V8_STARTUP_TRACE=1 zig-out/bin/origine </dev/null
V8_STARTUP_TRACE=1 zig-out/bin/origine examples/timers/init.js
```

The shell buffers host I/O, platform creation, V8 initialization, runtime/isolate
creation and scope creation timings, then reports them to stderr before the REPL.
Scope creation also reports context creation, host setup, bootstrap compilation,
bootstrap execution/hardening and finalization on the calling thread.
With a prepared snapshot, `bootstrap_restore` replaces bootstrap compilation
and initialization; the same validation helpers are restored from context data.
Normal execution prints no timing report. Timestamps use the monotonic clock;
tracing allocates no sample storage dynamically.

Scope-detail stages are nested inside scope creation and must not be added to
the initialization total. Internal measurements exclude process launch, dynamic
loader work, banner output and teardown. Full-process measurements include those
costs and, when tracing is enabled, reporting overhead.

File execution also reports `scope_detail host_*` stages splitting `host_run`
into API installation, module import, the `main` call, and settling/pumping.
The `api_*` stages break down API installation: attaching the scope, restoring
the prebuilt template, and binding native state. With snapshots disabled, template
initialization includes `api_glue_cache_read`, `api_glue_compile`, and
`api_glue_evaluate`; these are nested within `api_restore_template`.
These detail stages overlap their parents and must not be added to startup totals.

Engine and init snapshots prepare API descriptors, error helpers, capability
methods, and network classes/prototypes before startup. Their private context
template contains no host pointers or native authority. Runtime getters only
bind native namespaces on demand; they do not recreate or harden those classes.

Cache controls for comparisons: `ORIGINE_NO_SNAPSHOT=1` disables the engine and init
snapshots and code caches; `ORIGINE_SNAPSHOT_LOG=1` reports init-snapshot hit, miss
(with the reason), create and skip on stderr.

For new investigations, `lib/v8_zig/build-tools/scripts/measure-startup.py` measures traced
stages and full-process lifetime; `lib/v8_zig/build-tools/scripts/compare-startup.py`
compares two binaries with tracing disabled; [bench/startup/research.py](../bench/startup/research.py)
runs seeded, interleaved batches of several binary/environment variants against an init
file. Run these optional tools through `uv run --script` and keep their generated reports in
the ignored build-output directory. Comparisons require the same workload, build settings
and measurement conditions. Results of past experiments:
[startup-optimization-research.md](startup-optimization-research.md).

## Binary size

Inspect the current executable rather than relying on historical build sizes:

```sh
llvm-size --format=darwin -l zig-out/bin/origine
llvm-nm -n --demangle zig-out/bin/origine
```

Section and segment totals can overlap with symbol-based attribution. Symbol
address spans include alignment and unnamed bytes; they are estimates rather
than exact source-file contributions. Virtual reservations and zero-fill BSS
do not contribute equivalent disk payload.
