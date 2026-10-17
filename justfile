default:
    @just --list

# Build the app. V8 is always built from source with the patch series applied
# automatically; it is release V8 unless `v8_debug` is passed.
build mode="debug" v8="release":
    zig build {{ if mode == "release" { "-Doptimize=small" } else if mode == "debug" { "" } else { error("mode must be debug or release") } }} {{ if v8 == "debug" { "-Dv8_debug=true" } else if v8 == "release" { "" } else { error("v8 must be debug or release") } }}

# Run the shell against release V8.
run *args:
    zig build run -- {{args}}

# Working on V8 or its patches: debug V8 for quick incremental compiles.
v8-dev *args:
    zig build run -Dv8_debug=true -- {{args}}

# Fetch V8 and apply patches, then edit lib/v8_zig/.lp-cache/v8-*/.
patch-v8:
    zig build patch-v8

test:
    zig build test
