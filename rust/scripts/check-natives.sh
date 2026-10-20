#!/bin/sh
# CONTRACT (docs/contracts.md, surface B): the guest glue (src/js/glue/*.js) must use exactly the
# natives the Rust registry declares (`#[native(path = "namespace.name")]` in rust/crates/origine_api).
#   - every registered `namespace.name` is referenced in the glue (as `native.ns.name`, or `ops.name`
#     for the async fs ops, which glue/fs.js reaches through `makeAsyncOps(native.fsAsync, ..)`);
#   - every `native.<registered namespace>.<name>` the glue mentions is registered.
set -eu
root=$(cd "$(dirname "$0")/../.." && pwd)
paths=$(grep -rh '^#\[native(' "$root"/rust/crates/origine_api/src/*.rs | grep -oE 'path = "[A-Za-z0-9]+\.[A-Za-z0-9]+"' | sed 's/path = "\(.*\)"/\1/' | sort -u)
[ -n "$paths" ] || { echo "check-natives: no registered natives found" >&2; exit 2; }
status=0
for p in $paths; do
    ns=${p%%.*}; name=${p#*.}
    if ! grep -rqE "native\.$ns\.$name\b|\bops\.$name\b|^[[:space:]]*\.$name\(" "$root"/src/js/glue; then
        echo "check-natives: $p is registered in Rust but never used by src/js/glue" >&2
        status=1
    fi
done
namespaces=$(printf '%s\n' $paths | sed 's/\..*//' | sort -u)
for ns in $namespaces; do
    for used in $(grep -rhoE "native\.$ns\.[A-Za-z0-9]+" "$root"/src/js/glue | sort -u); do
        if ! printf '%s\n' $paths | grep -qx "${used#native.}"; then
            echo "check-natives: the glue uses $used, which no #[native(path = ...)] registers" >&2
            status=1
        fi
    done
done
exit $status
