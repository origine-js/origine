default:
    @just --list

# Rebuild V8 (fetch, patch, ninja). Plain `zig build` reuses the last archive; run this
# after changing V8 or its patches. Pass `-Dv8_debug=true` for a debug V8.
build-v8 *args:
    zig build build-v8 {{args}}

# Build the app. V8 is built from source on the first build only (see `build-v8`);
# it is release V8 unless `v8_debug` is passed.
build mode="debug" v8="release":
    zig build {{ if mode == "release" { "-Doptimize=small" } else if mode == "debug" { "" } else { error("mode must be debug or release") } }} {{ if v8 == "debug" { "-Dv8_debug=true" } else if v8 == "release" { "" } else { error("v8 must be debug or release") } }}

# Run the shell against release V8.
run *args:
    zig build run -- {{args}}

# Working on V8 or its patches: rebuild a debug V8 (quick incremental compiles), then run.
v8-dev *args:
    zig build build-v8 -Dv8_debug=true
    zig build run -Dv8_debug=true -- {{args}}

# Fetch V8 and apply patches, then edit lib/v8_zig/.lp-cache/v8-*/.
patch-v8:
    zig build patch-v8

test:
    zig build test
