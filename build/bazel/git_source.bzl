"""`git_source`: a source tree assembled from Git checkouts pinned by commit, then patched.

Chromium's sources are pinned the way V8's `DEPS` names them, `<repository>@<commit>`: googlesource's
`+archive` tarballs are not byte-stable, so a digest of one cannot be pinned, and Git verifies a commit
itself. `build/bazel/bump_v8.py` rewrites these pins in `MODULE.bazel`.
"""

def _checkout(ctx, source, directory):
    remote, commit = source.rsplit("@", 1)
    git = ctx.which("git")
    if not git:
        fail("git is required to fetch " + remote)
    ctx.execute([git, "init", "--quiet", directory], quiet = True)
    for args in [
        ["remote", "add", "origin", remote],
        ["fetch", "--quiet", "--depth=1", "origin", commit],
        ["checkout", "--quiet", "--detach", "FETCH_HEAD"],
    ]:
        result = ctx.execute([git, "-C", directory] + args)
        if result.return_code:
            fail("git {} failed for {}:\n{}".format(args[0], source, result.stderr))
    ctx.delete(directory + "/.git")

def _git_source_impl(ctx):
    # "." sorts first, so the root checkout exists before others land inside it.
    for directory in sorted(ctx.attr.sources):
        _checkout(ctx, ctx.attr.sources[directory], directory)

    workspace = ctx.path(Label("//:MODULE.bazel")).dirname
    for series in ctx.attr.patch_series:
        directory = workspace.get_child(*series.split("/"))
        ctx.watch_tree(directory)
        patches = sorted([p for p in directory.readdir() if p.basename.endswith(".patch")], key = lambda p: p.basename)
        for patch in patches:
            ctx.patch(patch, strip = 1)

    for path in ctx.attr.delete:
        ctx.delete(path)
    if ctx.attr.build_file:
        ctx.file("BUILD.bazel", ctx.read(ctx.attr.build_file))
    for name, content in ctx.attr.files.items():
        ctx.file(name, content)

git_source = repository_rule(
    implementation = _git_source_impl,
    attrs = {
        "sources": attr.string_dict(
            mandatory = True,
            doc = "Directory (`.` for the root) to `<repository>@<commit>`.",
        ),
        "patch_series": attr.string_list(
            doc = "Workspace-relative directories; each one's `*.patch` files are applied in name order " +
                  "(`-p1`), the directories in list order. Edits to them refetch the repository.",
        ),
        "delete": attr.string_list(doc = "Paths to remove after patching, such as upstream BUILD files that would split packages."),
        "build_file": attr.label(allow_single_file = True, doc = "Written as the root `BUILD.bazel`."),
        "files": attr.string_dict(doc = "Extra files to write, path to content."),
    },
)
