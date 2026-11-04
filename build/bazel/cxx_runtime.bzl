"""Preprocessor configuration shared by the toolchain's C++ mode and the libc++/libc++abi sources.

These mirror the pinned Chromium libc++ configuration (`buildtools/third_party/libc++/BUILD.gn` and
`build/config/c++/BUILD.gn` at the revisions `MODULE.bazel` pins). They are the one place the values are
written; the toolchain feature and the runtime targets both read them, so they cannot drift apart.
"""

# Defines every translation unit compiled against this libc++ needs.
CLIENT_DEFINES = [
    "LIBC_NAMESPACE=__llvm_libc_cr",
    "_LIBCPP_HARDENING_MODE=_LIBCPP_HARDENING_MODE_EXTENSIVE",
    "_LIBCPP_DISABLE_VISIBILITY_ANNOTATIONS",
    "_LIBCXXABI_DISABLE_VISIBILITY_ANNOTATIONS",
    "_LIBCPP_INSTRUMENTED_WITH_ASAN=0",
]

# Additional defines for building the runtime itself.
RUNTIME_DEFINES = ["_LIBCPP_BUILDING_LIBRARY"]
LIBCXX_DEFINES = RUNTIME_DEFINES + ["LIBCXX_BUILDING_LIBCXXABI", "_LIBCPP_CONSTINIT=constinit"]
LIBCXXABI_DEFINES = RUNTIME_DEFINES + ["LIBCXXABI_SILENT_TERMINATE"]

# Language mode for client code and for the runtime sources, which Chromium builds one standard newer.
CLIENT_STD = "-std=c++20"
RUNTIME_STD = "-std=c++26"

RUNTIME_COPTS = [RUNTIME_STD, "-fexceptions", "-frtti", "-Wno-pragma-clang-attribute", "-Wno-ignored-attributes"]
