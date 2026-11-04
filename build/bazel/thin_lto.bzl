"""Acceptance probe for the pinned Zig/Rust/Clang cross-language ThinLTO path."""

load(":platform.bzl", "CPU", "SDK", "TARGET")

def _probe_impl(ctx):
    """Borrows declared artifacts; returns build-owned executable and link evidence."""
    binary = ctx.actions.declare_file(ctx.label.name)
    evidence = ctx.actions.declare_directory(ctx.label.name + ".evidence")
    args = ctx.actions.args()
    args.add(ctx.executable._clang.path)
    args.add(SDK)
    args.add(TARGET)
    args.add(CPU)
    args.add(ctx.file.zig)
    args.add(ctx.file.rust)
    args.add(ctx.file.cpp)
    args.add(ctx.file.main)
    args.add(binary)
    args.add(evidence.path)
    ctx.actions.run_shell(
        inputs = depset(
            [ctx.file.zig, ctx.file.rust, ctx.file.cpp, ctx.file.main],
            transitive = [ctx.attr._sdk_files[DefaultInfo].files],
        ),
        tools = ctx.attr._llvm_files[DefaultInfo].files,
        outputs = [binary, evidence],
        arguments = [args],
        command = """
set -eu
root="$PWD"
clang="$root/$1"
sdk="$2"
target="$3"
cpu="$4"
zig="$root/$5"
rust="$root/$6"
cpp="$root/$7"
main="$root/$8"
binary="$root/$9"
work="$root/${10}"
mkdir -p "$work"
cd "$work"
# Stage inputs: LLD writes -save-temps files beside each input. Never write
# through Bazel's source or external-repository symlinks.
cp "$rust" rust.a
"$clang" -target "$target" -O2 -flto=thin -x ir -c "$zig" -o zig.o
"$clang" -target "$target" -mcpu="$cpu" -isysroot "$sdk" -O2 -flto=thin -c "$cpp" -o cpp.o
"$clang" -target "$target" -mcpu="$cpu" -isysroot "$sdk" -O2 -flto=thin -c "$main" -o main.o
"$clang" -target "$target" -isysroot "$sdk" -fuse-ld=lld -flto=thin \
    -Wl,-save-temps -Wl,-dead_strip main.o cpp.o zig.o rust.a -o "$binary"
"$clang" -S -emit-llvm -x ir zig.o.3.import.bc -o imported.ll
"$clang" -S -emit-llvm -x ir zig.o.4.opt.bc -o optimized.ll
# Require actual imports from BOTH foreign languages into the Zig module.
grep -E 'define.*@origine_probe_rust' imported.ll >/dev/null
grep -E 'define.*@origine_probe_cpp' imported.ll >/dev/null
if grep -E 'call.*@origine_probe_(rust|cpp)' optimized.ll; then
    echo 'cross-language calls survived optimization' >&2
    exit 1
fi
"$clang" --version > toolchain.txt
""",
        env = {"PATH": "/usr/bin:/bin"},
        mnemonic = "OrigineThinLTOProbe",
        progress_message = "Proving Zig/Rust/C++ ThinLTO imports",
    )
    return [
        DefaultInfo(executable = binary, files = depset([binary])),
        OutputGroupInfo(evidence = depset([evidence])),
    ]

thin_lto_probe_test = rule(
    implementation = _probe_impl,
    test = True,
    attrs = {
        "zig": attr.label(allow_single_file = True, mandatory = True),
        "rust": attr.label(allow_single_file = True, mandatory = True),
        "cpp": attr.label(allow_single_file = True, mandatory = True),
        "main": attr.label(allow_single_file = True, mandatory = True),
        "_clang": attr.label(default = "@origine_llvm//:bin/clang", executable = True, allow_single_file = True, cfg = "exec"),
        "_llvm_files": attr.label(default = "@origine_llvm//:files", cfg = "exec"),
        "_sdk": attr.label(default = "@origine_macos_sdk//:identity.json", allow_single_file = True),
        "_sdk_files": attr.label(default = "@origine_macos_sdk//:files"),
    },
)
