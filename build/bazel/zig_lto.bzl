"""`zig_lto_library`: a Zig static library that joins the program's ThinLTO link when LTO is on.

With `--//build/bazel/opt:lto=true` (build/bazel/build.py sets it for release profiles) the library
is Zig's LLVM bitcode, turned into a ThinLTO object by the pinned Clang (as the ThinLTO probe,
//build/bazel/probe, does), so ld64.lld optimizes it together with the C/C++ (`origine_thin_lto`)
and Rust (`-Clinker-plugin-lto`) bitcode. Otherwise it is Zig's native archive. Bitcode carries no
compiler runtime, so the LTO variant also links //build/bazel:zig_compiler_rt (native).
"""

load("@rules_cc//cc:find_cc_toolchain.bzl", "find_cc_toolchain", "use_cc_toolchain")
load("@rules_cc//cc/common:cc_common.bzl", "cc_common")
load("@rules_cc//cc/common:cc_info.bzl", "CcInfo")
load("@rules_zig//zig:defs.bzl", "zig_static_library")
load("@rules_zig//zig/private/providers:zig_module_info.bzl", "ZigModuleInfo")
load("//build/bazel:opt.bzl", "ZIG_MODES")

# Clang's pre-link optimization of the IR Zig already optimized in that mode (the ThinLTO backend
# at the link does the rest): none for debug, size for small.
_IR_OPT = {"debug": "-O0", "safe": "-O2", "fast": "-O2", "small": "-Os"}

def _zig_thinlto_impl(ctx):
    obj = ctx.actions.declare_file(ctx.label.name + ".o")  # `.o`: lld would re-read a `.bc` as IR
    archive = ctx.actions.declare_file("lib" + ctx.label.name + ".a")
    ctx.actions.run(
        executable = ctx.executable._clang,
        arguments = [ctx.attr.opt, "-flto=thin", "-x", "ir", "-c", ctx.file.bitcode.path, "-o", obj.path],
        inputs = [ctx.file.bitcode],
        tools = ctx.attr._llvm_files[DefaultInfo].files,
        outputs = [obj],
        mnemonic = "ZigThinLTO",
        progress_message = "Making a ThinLTO object of %{label}",
    )
    ctx.actions.run(
        executable = ctx.executable._ar,
        arguments = ["rcsD", archive.path, obj.path],
        inputs = [obj],
        outputs = [archive],
        mnemonic = "ZigThinLTOArchive",
    )
    cc_toolchain = find_cc_toolchain(ctx)
    features = cc_common.configure_features(ctx = ctx, cc_toolchain = cc_toolchain)
    library = cc_common.create_library_to_link(
        actions = ctx.actions,
        feature_configuration = features,
        cc_toolchain = cc_toolchain,
        static_library = archive,
        alwayslink = True,
    )
    own = CcInfo(linking_context = cc_common.create_linking_context(
        linker_inputs = depset([cc_common.create_linker_input(owner = ctx.label, libraries = depset([library]))]),
    ))
    return [
        DefaultInfo(files = depset([archive])),
        # The C libraries the Zig modules use (`@lz4`'s lz4, ...): the native library carries them in
        # its CcInfo, the bitcode one has none of its own.
        cc_common.merge_cc_infos(
            direct_cc_infos = [own],
            cc_infos = [dep[CcInfo] for dep in ctx.attr.deps] +
                       [dep[ZigModuleInfo].cc_info for dep in ctx.attr.zig_deps if dep[ZigModuleInfo].cc_info],
        ),
    ]

_zig_thinlto = rule(
    implementation = _zig_thinlto_impl,
    attrs = {
        "bitcode": attr.label(allow_single_file = [".bc"], mandatory = True),
        "opt": attr.string(mandatory = True),
        "deps": attr.label_list(providers = [CcInfo]),
        "zig_deps": attr.label_list(providers = [ZigModuleInfo], doc = "The library's Zig modules, for their C dependencies."),
        "_clang": attr.label(default = "@origine_llvm//:bin/clang", executable = True, allow_single_file = True, cfg = "exec"),
        "_ar": attr.label(default = "@origine_llvm//:bin/llvm-ar", executable = True, allow_single_file = True, cfg = "exec"),
        "_llvm_files": attr.label(default = "@origine_llvm//:files", cfg = "exec"),
    },
    fragments = ["cpp"],
    toolchains = use_cc_toolchain(),
)

def zig_lto_library(name, module, visibility = None, **kwargs):
    """A `zig_static_library` (`kwargs`) that is ThinLTO bitcode when LTO is on.

    `module` names its optimization flag in //build/bazel/opt, which also picks Clang's IR level.
    """
    zig_static_library(name = name + "_native", **kwargs)
    zig_static_library(name = name + "_bitcode", emit_bin = False, emit_llvm_bc = True, **kwargs)
    native.filegroup(name = name + "_bc", srcs = [":" + name + "_bitcode"], output_group = "llvm_bc")
    _zig_thinlto(
        name = name + "_thinlto",
        bitcode = ":" + name + "_bc",
        opt = select({"//build/bazel/opt:{}_{}".format(module, mode): _IR_OPT[mode] for mode in ZIG_MODES}),
        deps = ["//build/bazel:zig_compiler_rt"],
        zig_deps = kwargs.get("deps", []),
    )
    native.alias(
        name = name,
        actual = select({
            "//build/bazel/opt:lto_on": ":" + name + "_thinlto",
            "//conditions:default": ":" + name + "_native",
        }),
        visibility = visibility,
    )
