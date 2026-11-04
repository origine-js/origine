"""The single target description of the C/C++ toolchain, the SDK probes and the ThinLTO probe.

Only macOS arm64 is supported; adding a platform adds an entry here and a platform/toolchain pair.
The deployment target comes from `@origine_macos_sdk` (`MODULE.bazel`, or MACOSX_DEPLOYMENT_TARGET).
"""

load("@origine_macos_sdk//:sdk_root.bzl", "DEPLOYMENT_TARGET", "SDK_ROOT")

ARCH = "arm64"
CPU = "apple-m1"
TARGET = "{}-apple-macos{}".format(ARCH, DEPLOYMENT_TARGET)
SDK = SDK_ROOT
