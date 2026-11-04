"""Generated registry edges; local crate edges are explicit BUILD dependencies."""

_DEPS = {
    "aws-lc-rs": {
        "normal": [
            "@crates//:zeroize_1_9_1"
        ]
    },
    "aws-lc-sys": {},
    "origine_alloc": {},
    "origine_api": {},
    "origine_api_core": {},
    "origine_api_fs": {},
    "origine_api_macros": {
        "normal": [
            "@crates//:proc_macro2_1_0_107",
            "@crates//:quote_1_0_47",
            "@crates//:syn_2_0_119"
        ]
    },
    "origine_dns": {
        "dev": [
            "@crates//:pollster_0_4_0"
        ],
        "normal": [
            "@crates//:hickory_proto_0_25_2"
        ]
    },
    "origine_gen": {
        "normal": [
            "@crates//:bindgen_0_72_1"
        ]
    },
    "origine_h2": {
        "dev": [
            "@crates//:async_executor_1_14_0",
            "@crates//:futures_lite_2_6_1",
            "@crates//:rcgen_0_13_2"
        ]
    },
    "origine_io": {},
    "origine_native": {},
    "origine_oxc": {
        "normal": [
            "@crates//:oxc_allocator_0_155_0",
            "@crates//:oxc_codegen_0_155_0",
            "@crates//:oxc_diagnostics_0_155_0",
            "@crates//:oxc_parser_0_155_0",
            "@crates//:oxc_semantic_0_155_0",
            "@crates//:oxc_span_0_155_0",
            "@crates//:oxc_transformer_0_155_0"
        ]
    },
    "origine_repl": {
        "normal": [
            "@crates//:oxc_allocator_0_155_0",
            "@crates//:oxc_ast_0_155_0",
            "@crates//:oxc_ast_visit_0_155_0",
            "@crates//:oxc_diagnostics_0_155_0",
            "@crates//:oxc_parser_0_155_0",
            "@crates//:oxc_span_0_155_0",
            "@crates//:oxc_syntax_0_155_0",
            "@crates//:unicode_width_0_2_2"
        ]
    },
    "origine_tls": {
        "dev": [
            "@crates//:futures_lite_2_6_1",
            "@crates//:pollster_0_4_0",
            "@crates//:rcgen_0_13_2"
        ],
        "normal": [
            "@crates//:rustls_0_23_46",
            "@crates//:rustls_pki_types_1_15_1",
            "@crates//:rustls_webpki_0_103_16",
            "@crates//:webpki_roots_1_0_11"
        ]
    },
    "origine_transport": {},
    "v8": {
        "build": [
            "@crates//:bindgen_0_73_2",
            "@crates//:serde_json_1_0_154"
        ],
        "normal": [
            "@crates//:bitflags_2_13_2",
            "@crates//:temporal_capi_0_2_6"
        ],
        "proc_macro": [
            "@crates//:paste_1_0_15"
        ]
    }
}

def registry_deps(package, kind = "normal"):
    """Borrow names; return a fresh list of immutable dependency labels."""
    return list(_DEPS[package].get(kind, []))

_FEATURES = {
    "aws-lc-rs": [
        "aws-lc-sys",
        "prebuilt-nasm"
    ],
    "aws-lc-sys": [
        "prebuilt-nasm"
    ],
    "origine_alloc": [],
    "origine_api": [
        "dns",
        "http",
        "tls"
    ],
    "origine_api_core": [],
    "origine_api_fs": [],
    "origine_api_macros": [],
    "origine_dns": [],
    "origine_gen": [],
    "origine_h2": [],
    "origine_io": [],
    "origine_native": [
        "default",
        "dns",
        "http",
        "quic",
        "tls",
        "typescript"
    ],
    "origine_oxc": [],
    "origine_repl": [
        "typescript"
    ],
    "origine_tls": [],
    "origine_transport": [
        "testing"
    ],
    "v8": [
        "default",
        "inspector",
        "use_custom_libcxx",
        "v8_enable_pointer_compression",
        "v8_enable_sandbox"
    ]
}

def package_features(package):
    """Borrow a name; return a fresh list of Cargo-resolved feature names."""
    return list(_FEATURES[package])
