"""`macos_sdk`: Xcode's selected macOS SDK, recorded by identity instead of imported file by file."""

def _macos_sdk_impl(ctx):
    sdk = ctx.os.environ.get("ORIGINE_MACOS_SDK")
    if not sdk:
        result = ctx.execute(["/usr/bin/xcrun", "--sdk", "macosx", "--show-sdk-path"])
        if result.return_code:
            fail("macOS SDK discovery failed: " + result.stderr)
        sdk = result.stdout.strip()
    sdk = str(ctx.path(sdk).realpath)
    deployment_target = ctx.os.environ.get("MACOSX_DEPLOYMENT_TARGET") or ctx.attr.deployment_target
    ctx.file("identity.json", ctx.read(ctx.path(sdk + "/SDKSettings.json")))
    ctx.file("sdk_root.bzl", "SDK_ROOT = {}\nDEPLOYMENT_TARGET = {}\n".format(repr(sdk), repr(deployment_target)))
    ctx.file("BUILD.bazel", """
package(default_visibility = ["//visibility:public"])
exports_files(["identity.json", "sdk_root.bzl"])
filegroup(name = "files", srcs = ["identity.json"])
""")

macos_sdk = repository_rule(
    implementation = _macos_sdk_impl,
    local = True,
    configure = True,
    attrs = {"deployment_target": attr.string(mandatory = True, doc = "Oldest macOS the binaries run on.")},
    environ = ["DEVELOPER_DIR", "ORIGINE_MACOS_SDK", "MACOSX_DEPLOYMENT_TARGET"],
)
