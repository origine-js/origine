# Shell performance measurement

Build the current single-scope shell with
`zig build -Doptimize=small`.
The shell creates one engine, one runtime and one empty managed scope before
entering the REPL. Import-map and capability demonstrations live in tests.

## Startup tracing

Enable instrumentation with `V8_STARTUP_TRACE=1`:

```sh
V8_STARTUP_TRACE=1 zig-out/bin/origine </dev/null
```

The shell buffers host I/O, platform creation, V8 initialization, runtime/isolate
creation and scope creation timings, then reports them to stderr before the REPL.
Scope creation also reports context creation, host setup, bootstrap compilation,
bootstrap execution/hardening and finalization on the calling thread.
Normal execution prints no timing report. Timestamps use the monotonic clock;
tracing allocates no sample storage dynamically.

Scope-detail stages are nested inside scope creation and must not be added to
the initialization total. Internal measurements exclude process launch, dynamic
loader work, banner output and teardown. Full-process measurements include those
costs and, when tracing is enabled, reporting overhead.

For new investigations, `lib/v8_zig/build-tools/measure-startup.py` measures traced stages
and full-process lifetime; `lib/v8_zig/build-tools/compare-startup.py` compares two binaries
with tracing disabled. Run these optional tools through `uv run --script` and
keep their generated reports in the ignored build-output directory. Comparisons
require the same workload, build settings and measurement conditions.

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
