"""The features compiled into origine, and `if_feature`.

`FEATURES` is the one list: build/bazel/settings declares a flag per entry
(`--//build/bazel/settings:<name>=false` turns it off), src/BUILD.bazel checks `requires`, and
`just build -F` (build/bazel/build.py) reads this file. Keep it a plain literal.
"""

FEATURES = {
    "typescript": {
        "doc": "oxc TypeScript/JSX transformer (api.transform, REPL type erasure)",
        "requires": [],
    },
    "http": {
        "doc": "HTTP/2 client and server (api.http; links nghttp2)",
        "requires": [],
    },
    "tls": {
        "doc": "TLS (api.tls; rustls on AWS-LC)",
        "requires": [],
    },
    "dns": {
        "doc": "DNS resolver (api.dns)",
        "requires": [],
    },
    "quic": {
        "doc": "QUIC and api.net.udp",
        "requires": ["tls"],
    },
}

# How blobs are stored; all off by default; `release-small` turns the first two on (build.py). Each is a
# flag in //build/bazel/settings and an option of `just build -C` (build.py names them `engine-snapshot`, ...).
COMPRESSION = {
    "engine_snapshot_compression": {
        "doc": "engine snapshot embedded LZ4-compressed, expanded at startup (~0.1 ms)",
    },
    "icu_compression": {
        "doc": "ICU data embedded zstd-compressed, expanded on first Intl use (~7 MB smaller)",
    },
    "user_snapshot_compression": {
        "doc": "init snapshots in the global cache LZ4-compressed",
    },
    "user_codecache_compression": {
        "doc": "code caches in the global cache LZ4-compressed",
    },
}

def if_feature(feature, value):
    """Returns `value` when `--//build/bazel/settings:<feature>` is true, else `[]` (a select)."""
    if feature not in FEATURES and feature not in COMPRESSION and feature != "networking":
        fail("unknown feature: " + feature)
    return select({
        "//build/bazel/settings:{}_on".format(feature): value,
        "//conditions:default": [],
    })
