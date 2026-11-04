"""`v8_bindgen`: runs rusty_v8's bindgen on a header with the C++ flags of a `cc_library`.

The clang arguments are the toolchain's own `c++-compile` command line for `cc_dep`'s compilation
context (includes, defines, libc++ and SDK flags), so the bindings see exactly the ABI the shim
and V8 are compiled with. Replaces the Cargo build script's lookup in GN's compile_commands.json.
"""

load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "ACTION_NAMES")
load("@origine_macos_sdk//:sdk_root.bzl", "LIBCLANG_DIR")
load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")

def _clang_args(ctx):
    cc_toolchain = find_cc_toolchain(ctx)
    features = cc_common.configure_features(
        ctx = ctx,
        cc_toolchain = cc_toolchain,
        requested_features = ctx.features,
        unsupported_features = ctx.disabled_features,
    )
    context = ctx.attr.cc_dep[CcInfo].compilation_context
    variables = cc_common.create_compile_variables(
        feature_configuration = features,
        cc_toolchain = cc_toolchain,
        include_directories = context.includes,
        quote_include_directories = context.quote_includes,
        system_include_directories = depset(transitive = [context.system_includes, context.external_includes]),
        framework_include_directories = context.framework_includes,
        preprocessor_defines = context.defines,
    )
    line = cc_common.get_memory_inefficient_command_line(
        feature_configuration = features,
        action_name = ACTION_NAMES.cpp_compile,
        variables = variables,
    )

    # libclang (the selected Xcode's) brings its own builtin headers: drop the toolchain's
    # `-resource-dir`, and code-generation flags that mean nothing to a parse.
    args = []
    skip = False
    for flag in line:
        if skip:
            skip = False
        elif flag == "-resource-dir":
            skip = True
        elif not flag.startswith("-flto"):
            args.append(flag)
    return args, cc_toolchain

def _v8_bindgen_impl(ctx):
    out = ctx.actions.declare_file(ctx.label.name + ".rs")
    clang_args, cc_toolchain = _clang_args(ctx)
    args = ctx.actions.args()
    args.add(ctx.file.header)
    args.add(out)
    args.add_all(["-x", "c++"] + clang_args)

    # Only source headers: the public V8 API needs none of V8's generated (torque) headers, and
    # listing them would run those generators for a parse.
    headers = [f for f in ctx.attr.cc_dep[CcInfo].compilation_context.headers.to_list() if f.is_source]
    ctx.actions.run(
        executable = ctx.executable._bindgen,
        arguments = [args],
        inputs = depset([ctx.file.header] + ctx.files.srcs + headers + [ctx.file._libclang], transitive = [cc_toolchain.all_files]),
        outputs = [out],
        env = {"LIBCLANG_PATH": LIBCLANG_DIR},
        mnemonic = "RustBindgen",
        progress_message = "Generating Rust bindings for %{label}",
    )
    return [DefaultInfo(files = depset([out]))]

v8_bindgen = rule(
    implementation = _v8_bindgen_impl,
    attrs = {
        "header": attr.label(allow_single_file = True, mandatory = True),
        "srcs": attr.label_list(allow_files = True, doc = "Headers the header includes beside it."),
        "cc_dep": attr.label(providers = [CcInfo], mandatory = True, doc = "Whose compilation context the header is parsed in."),
        "_bindgen": attr.label(default = "//lib/v8_zig/rusty_v8:bindgen", executable = True, cfg = "exec"),
        "_libclang": attr.label(default = "@origine_macos_sdk//:libclang.dylib", allow_single_file = True),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)
