#!/bin/sh
# CONTRACT (docs/contracts.md, surface F): every `#[no_mangle]` / `#[unsafe(no_mangle)]` fn in the
# Rust crates must have a name starting with a prefix that build.zig keeps global
# (`kept_symbol_prefixes`); anything else is hidden by the pre-link step and Zig cannot call it.
# (origine_api_macros only generates `origine_api_native_*` items.) The prefixes are read from build.zig so there is one list.
# usage: check-exports.sh   (from anywhere; prints violations, exits 1 if any)
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
prefixes=$(sed -n 's/^const kept_symbol_prefixes = .*{\(.*\)};$/\1/p' "$root/build.zig" | tr -d '" ' | tr ',' ' ')
[ -n "$prefixes" ] || { echo "check-exports: kept_symbol_prefixes not found in build.zig" >&2; exit 2; }
bad=0
for file in $(find "$root/rust/crates" "$root/rust/src" -name '*.rs' -path '*/src*' -not -path '*/target/*' -not -path '*/origine_api_macros/*'); do
    awk -v prefixes="$prefixes" -v file="$file" '
        BEGIN { n = split(prefixes, p, " ") }
        /^[ \t]*#\[(unsafe\()?no_mangle/ { armed = 1; next }
        armed && /fn [A-Za-z_0-9]+/ {
            match($0, /fn [A-Za-z_0-9]+/)
            name = substr($0, RSTART + 3, RLENGTH - 3)
            ok = 0
            for (i = 1; i <= n; i++) if (index(name, p[i]) == 1) ok = 1
            if (!ok) { printf "%s: #[no_mangle] fn %s does not start with a kept prefix (%s)\n", file, name, prefixes; bad = 1 }
            armed = 0
        }
        END { exit bad }
    ' "$file" || bad=1
done
exit $bad
