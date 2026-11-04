"""macOS arm64 C/C++ toolchain using V8's exact LLVM distribution."""

load("@rules_cc//cc:defs.bzl", "CcToolchainConfigInfo", "cc_common")
load(":cxx_runtime.bzl", "CLIENT_DEFINES", "CLIENT_STD")
load(":platform.bzl", "CPU", "SDK", "TARGET")
load("@bazel_tools//tools/build_defs/cc:action_names.bzl", "ACTION_NAMES")
load("@bazel_tools//tools/cpp:cc_toolchain_config_lib.bzl", "feature", "feature_set", "flag_group", "flag_set", "tool_path", "variable_with_value")

_COMPILE = [ACTION_NAMES.c_compile, ACTION_NAMES.cpp_compile, ACTION_NAMES.assemble, ACTION_NAMES.preprocess_assemble]
_LINK = [ACTION_NAMES.cpp_link_executable, ACTION_NAMES.cpp_link_dynamic_library, ACTION_NAMES.cpp_link_nodeps_dynamic_library]

def _flags(name, actions, flags, enabled = True):
    """Accepts configuration values; returns a feature retaining only immutable values."""
    return feature(name = name, enabled = enabled, flag_sets = [flag_set(actions = actions, flag_groups = [flag_group(flags = flags)])])

def _impl(ctx):
    """Borrows SDK artifact metadata during analysis; returns immutable toolchain config."""
    sdk = SDK
    # lib/clang/<major>, found from the headers rather than named by version.
    resource_dir = [f.dirname for f in ctx.files.builtin_headers if f.basename == "stddef.h" and f.dirname.endswith("/include")][0][:-len("/include")]
    libcxx = ctx.file.libcxx_header.dirname
    libcxxabi = ctx.file.libcxxabi_header.dirname
    libcxx_config = ctx.file.libcxx_config.dirname
    llvm_libc = ctx.file.llvm_libc_header.dirname.rsplit("/", 1)[0]
    return cc_common.create_cc_toolchain_config_info(
        ctx = ctx,
        toolchain_identifier = "origine-llvm-macos-arm64",
        host_system_name = "aarch64-apple-darwin",
        target_system_name = "aarch64-apple-darwin",
        target_cpu = "darwin_arm64",
        target_libc = "macosx",
        compiler = "clang",
        abi_version = "unknown",
        abi_libc_version = "unknown",
        tool_paths = [
            tool_path(name = "gcc", path = "bin/clang"),
            tool_path(name = "ld", path = "bin/ld64.lld"),
            tool_path(name = "ar", path = "bin/llvm-ar"),
            tool_path(name = "cpp", path = "bin/clang++"),
            tool_path(name = "gcov", path = "/usr/bin/false"),
            tool_path(name = "nm", path = "/usr/bin/nm"),
            tool_path(name = "objdump", path = "/usr/bin/otool"),
            tool_path(name = "strip", path = "bin/llvm-strip"),
        ],
        cxx_builtin_include_directories = [
            sdk,
            sdk + "/usr/include",
            sdk + "/usr/include/c++/v1",
            sdk + "/System/Library/Frameworks",
            resource_dir + "/include",
            libcxx,
            libcxxabi,
            libcxx_config,
            llvm_libc,
        ],
        features = [
            _flags("origine_compile", _COMPILE, ["-target", TARGET, "-mcpu=" + CPU, "-isysroot", sdk, "-resource-dir", resource_dir, "-fPIC"]),
            _flags("origine_cxx", [ACTION_NAMES.cpp_compile], [
                CLIENT_STD, "-nostdinc++",
                "-isystem", libcxx_config,
                "-isystem", libcxx,
                "-isystem", libcxxabi,
                "-isystem", llvm_libc,
                "-Wno-pragma-clang-attribute",
            ] + ["-D" + define for define in CLIENT_DEFINES]),
            _flags("origine_link", _LINK, ["-target", TARGET, "-isysroot", sdk, "-fuse-ld=lld", "-Wl,-dead_strip"]),
            _flags("dbg", _COMPILE, ["-O0", "-g"], enabled = False),
            _flags("opt", _COMPILE, ["-O2", "-DNDEBUG"], enabled = False),
            # Requested per repository (V8's REPO.bazel); applies only with `-c opt`.
            feature(
                name = "origine_thin_lto",
                requires = [feature_set(features = ["opt"])],
                flag_sets = [flag_set(actions = _COMPILE + _LINK, flag_groups = [flag_group(flags = ["-flto=thin"])])],
            ),
            feature(
                name = "archiver_flags",
                enabled = True,
                flag_sets = [flag_set(
                    actions = [ACTION_NAMES.cpp_link_static_library],
                    flag_groups = [
                        flag_group(flags = ["rcsD", "%{output_execpath}"], expand_if_available = "output_execpath"),
                        flag_group(
                            iterate_over = "libraries_to_link",
                            expand_if_available = "libraries_to_link",
                            flag_groups = [
                                flag_group(flags = ["%{libraries_to_link.name}"], expand_if_equal = variable_with_value(name = "libraries_to_link.type", value = "object_file")),
                                flag_group(flags = ["%{libraries_to_link.object_files}"], iterate_over = "libraries_to_link.object_files", expand_if_equal = variable_with_value(name = "libraries_to_link.type", value = "object_file_group")),
                            ],
                        ),
                    ],
                )],
            ),
            feature(name = "supports_pic", enabled = True),
        ],
    )

origine_cc_toolchain_config = rule(
    implementation = _impl,
    attrs = {
        "sdk": attr.label(allow_single_file = True, default = "@origine_macos_sdk//:identity.json"),
        "compiler": attr.label(allow_single_file = True, mandatory = True),
        "builtin_headers": attr.label(allow_files = True, mandatory = True),
        "libcxx_header": attr.label(allow_single_file = True, default = "@libcxx//:libcxx/include/__config"),
        "libcxxabi_header": attr.label(allow_single_file = True, default = "@libcxx//:libcxxabi/include/cxxabi.h"),
        "libcxx_config": attr.label(allow_single_file = True, default = "@libcxx//:buildtools/third_party/libc++/__config_site"),
        "llvm_libc_header": attr.label(allow_single_file = True, default = "@libcxx//:llvm-libc/shared/math.h"),
    },
    provides = [CcToolchainConfigInfo],
)
