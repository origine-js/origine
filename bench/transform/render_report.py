"""Render saved benchmark measurements; invoked by run.py report."""
import json


def render(root):
    def read(name):
        return json.loads((root / 'results' / name).read_text())

    meta, summary, coverage = (read(name) for name in ['environment.json', 'summary.json', 'coverage.json'])
    groups, probes, raw = (read(name) for name in ['groups.json', 'probes.json', 'raw.json'])
    lookup = {(r['mode'], r['group']): r for r in summary}
    modes = [r['mode'] for r in meta['sizes']]
    repos = ['cordis', 'webui', 'vue-core']
    text = []

    def paragraph(value):
        text.extend([value, ''])

    def table(headers, rows):
        text.append('| ' + ' | '.join(headers) + ' |')
        text.append('|' + '|'.join(['---'] * len(headers)) + '|')
        text.extend('| ' + ' | '.join(str(value) for value in row) + ' |' for row in rows)
        text.append('')

    def duration(mode, group):
        result = lookup.get((mode, group))
        return f"{result['wall_ms']:.4f}" if result else '—'

    paragraph('# Yuku vs Oxc vs SWC Next: native TS / TSX / JSX transforms')
    paragraph(f"Measured {meta['date']} on **{meta['cpu']}, {meta['logical_cpus']} logical CPUs, {meta['ram_bytes']/1024**3:.0f} GiB RAM, macOS 27.2 arm64**. Yuku 0.24.1 / Zig {meta['zig']}; Oxc 0.155.0 and SWC Next 0.4.0 / {meta['rustc']}; V8 validation via Node {meta['node']}. Seven fresh-process samples per build/group, randomized serial order. All engines were rerun together after adding SWC Next; the original two-engine measurements were replaced.")
    cooldown = meta.get('cooldown_seconds', 0)
    observed = [r['cooldown_actual_seconds'] for r in raw if r.get('cooldown_actual_seconds') is not None]
    if observed:
        paragraph(f"**Cooldown:** at least {cooldown:g} s between every fresh-process sample, including changes of build/workload and sample rounds. All {len(observed)} observed gaps were at least {min(observed):.6f} seconds (maximum {max(observed):.6f} seconds). Warmups and timed sweeps within a worker are batched without pauses. Cooldowns are outside the timing region; raw results preserve worker timestamps and observed intervals.")
    else:
        paragraph('This run did not use an inter-process cooldown.')
    paragraph('**For Origine’s full TS/TSX/JSX contract, Oxc remains the complete existing choice.** Yuku strips erasable TS but rejects runtime TS constructs. SWC Next’s semantic TS transformer lowers enums, namespaces and parameter properties, but its native pipeline still preserves JSX. These results use the new swc-project/swc-next rewrite, not classic SWC. [Primary-source features and V8 integration evidence](../../docs/research/yuku-oxc-features.md).')
    paragraph('## Coverage before speed')
    rows = []
    for repo, kind in [('cordis', 'ts'), ('webui', 'ts'), ('vue-core', 'ts'), ('vite', 'tsx'), ('vite', 'jsx')]:
        selected = [r for r in coverage if r['repo'] == repo and r['kind'] == kind]
        inputs = [r for r in selected if r['engine'] == 'oxc']
        accepted = [sum(r['engine'] == engine and r['status'] == 0 and r.get('v8_syntax_valid', False) for r in selected) for engine in ['yuku', 'oxc', 'swc-next']]
        rows.append([f'{repo}/{kind}', len(inputs), f"{sum(r['bytes'] for r in inputs):,}", *accepted])
    table(['Source', 'Files', 'Input bytes', 'Yuku accepted JS', 'Oxc accepted JS', 'SWC Next accepted JS'], rows)
    paragraph('Acceptance requires no native diagnostics and successful V8 ES-module syntax parsing. A few `.tsx`/`.jsx` files need no JSX lowering and can pass preservation pipelines; that does not establish JSX transform support. Every successfully emitted corpus file was checked. These checks do not resolve imports, execute applications or prove semantic equivalence.')
    paragraph('Cordis and WebUI package source directories and Vue-core package `src` supply the required TS sources. Declarations, tests and fixtures are excluded there; WebUI package `client` is included. Eligible required-package sources contain no TSX/JSX, so Vite create-vite templates and playgrounds provide those workloads. Vue `.vue` SFCs are excluded: they need a separate framework compiler. Exact paths and SHA-256 hashes are in [inventory.json](results/inventory.json).')
    paragraph('## Identical accepted TS subsets')
    paragraph('**Median milliseconds per entire group**, not per file. Each sample averages at least 20 sweeps, or enough to target approximately 150 ms. Inputs and one reusable destination buffer are preloaded. Three warmups and one pilot precede timing. Time includes Python/ctypes overhead, parse/transform/codegen, output copy and freeing temporary allocations; it excludes library loading, file I/O and V8 checks.')
    headers = ['Build'] + [f"{repo}: {len(groups[repo+'/ts-common'])} files / {sum(r['bytes'] for r in groups[repo+'/ts-common']):,} B" for repo in repos]
    table(headers, [[mode, *[duration(mode, repo+'/ts-common') for repo in repos]] for mode in modes])
    paragraph('All three engines receive identical files in each common subset. Yuku performs parse + stripping codegen; Oxc performs parse + semantics + transformer + codegen; SWC Next performs parse + runtime normalization + semantics with all syntax checks + its public TypeScript lowering pass + codegen. The SWC Next wrapper deliberately skips unrelated ES downlevel transforms and post-transform semantic rebuilding. This compares usable native pipelines with different work and feature coverage, not identical algorithms.')
    paragraph('## Full TS corpus and JSX-lowering workloads')
    full_groups = [repo+'/ts-oxc-all' for repo in repos] + ['vite/tsx-oxc-all', 'vite/jsx-oxc-all']
    table(['Build'] + [f"{g}: {len(groups[g])} files" for g in full_groups], [[mode, *[duration(mode, group) for group in full_groups]] for mode in modes if not mode.startswith('yuku')])
    paragraph('Values are milliseconds per whole group. An em dash means the complete group is unsupported; it is not a zero or an omitted fast result. JSX lowering is classic React-style for Oxc. Preserved JSX is not counted as executable JS. No framework-specific template/runtime correctness is established for Vue, Preact, Solid or Qwik.')
    extra_groups = [name for name in groups if 'swc-next-all' in name]
    if extra_groups:
        paragraph('### Additional SWC Next accepted-only subsets')
        table(['Build', 'Group', 'Files', 'Wall ms'], [[r['mode'], r['group'], r['files'], f"{r['wall_ms']:.4f}"] for r in summary if r['group'] in extra_groups])
    paragraph('## Compiled library sizes')
    table(['Build', 'Dynamic bytes', 'Dynamic KiB', 'Static archive bytes'], [[r['mode'], f"{r['dylib_bytes']:,}", f"{r['dylib_bytes']/1024:.2f}", f"{r['archive_bytes']:,}"] for r in meta['sizes']])
    paragraph('Actual stripped Mach-O dylibs and native static archives are measured for the benchmark wrappers and their reachable dependencies. Rust static archives include runtime and dependency objects; archive size is not the size added to Origine after final linking/LTO/dead stripping. Feature coverage differs. Artifact SHA-256 hashes are in [environment.json](results/environment.json).')
    paragraph('Zig `.fast`, `.safe` and `.small` are compared against Rust O3; Os and Oz use Cargo opt-level `s` and `z`. `.small` is Zig’s size-oriented release mode, not an independent “small + O3” setting. Both Rust wrappers use thin LTO, one codegen unit, stripped symbols and aborting panics. O3-checked enables overflow checks and debug assertions, not an exact equivalent of Zig `.safe`. SWC Next upstream uses fat LTO; thin LTO here matches the Oxc benchmark. Toolchain-default CPU targeting is used, without explicitly matched microarchitecture tuning.')
    paragraph('## CPU and RSS for every measured group')
    paragraph('CPU ms and wall ms are per group sweep. CPU utilization = process CPU / wall × 100; 100% means one core, not the whole 16-core machine. Peak RSS is macOS `getrusage` in MiB and includes Python/Typer, preloaded input/buffer, mapped native library pages and allocator state. Δ peak is the post-use process high-water mark minus its pre-library-load high-water mark: an approximate incremental process peak, not an isolated library allocation count or leak measurement. Independent medians need not add exactly.')
    table(['Build', 'Group', 'Wall ms', 'CPU ms', 'CPU %', 'Peak RSS MiB', 'Δ peak MiB', 'Wall min–max ms'], [[r['mode'], r['group'], f"{r['wall_ms']:.4f}", f"{r['cpu_ms']:.4f}", f"{r['cpu_percent']:.2f}", f"{r['peak_rss_mib']:.2f}", f"{r['peak_increment_mib']:.2f}", f"{r['wall_min_ms']:.4f}–{r['wall_max_ms']:.4f}"] for r in sorted(summary, key=lambda r:(r['group'], r['mode']))])
    paragraph('## Features and embedded V8 fit')
    table(['Capability', 'Yuku native path', 'Oxc native path', 'SWC Next native TS path'], [
        ['Erasable TS', 'Yes', 'Yes', 'Yes'],
        ['Enum / const enum', 'Diagnostic', 'Lowered', 'Lowered'],
        ['Namespace / parameter property', 'Diagnostic', 'Lowered', 'Lowered'],
        ['TSX / JSX → JS', 'Preserves JSX', 'Lowers JSX', 'Preserves JSX'],
        ['Source maps', 'Available; disabled here', 'Available; disabled here', 'Available; disabled here'],
        ['Semantic analysis in timed pipeline', 'No', 'Yes', 'Yes'],
        ['Existing Origine integration', 'None', 'Checked C ABI + Zig adapter', 'None'],
    ])
    paragraph(f"[Feature probes](results/probes.json) cover erasable TS, enum, const enum, namespace, parameter property, TSX and JSX across all {len(modes)} configurations: **{len(probes)} expected outcomes checked in V8**. Runtime TS probes execute to answer 42 for Oxc and SWC Next. Yuku reports diagnostics for those constructs. JSX-containing outputs fail V8 parsing for Yuku and SWC Next; Oxc JSX probes execute successfully using a test classic factory.")
    paragraph('SWC Next also has a separate fixed-width `type_strip` API; this benchmark uses its semantic TypeScript transformer, not that restricted eraser and not classic SWC. At the pinned revision, external `import = require()` can emit `import.sync(...)`, and `export =` can remain in output; these require separate V8/module compatibility work. The six additional [module-form checks](results/module-probes.json) reproduce both SWC Next syntax failures in V8. Oxc emits syntactically valid `require(...)` / `module.exports` for these probes, which still need runtime bindings to execute; compilation alone does not supply CommonJS support. JSX lowering is absent from its current native transformer options. Upstream marks the Rust API very early, recommends classic SWC for production, and documents AST-handle ownership soundness issues. The npm entry point exposes parser/codegen rather than this native TS transformer. [Pinned source evidence and caveats](../../docs/research/yuku-oxc-features.md#swc-next-extension).')
    paragraph('V8 accepts JavaScript text; these libraries are compiler front ends, not V8 engine plugins. Oxc already implements Origine’s source→JS boundary through its checked C ABI. SWC Next can sit behind a similar native adapter for supported TS but needs a JSX stage, readiness review and module edge-case handling. A hybrid eraser/fallback path for Yuku or SWC Next needs consistent diagnostics and semantics. Automatic JSX needs runtime-import resolution; classic JSX needs a suitable factory. Syntax validation does not prove application compatibility.')
    paragraph('## Reproducibility and limits')
    owners = {'yuku':'yuku-toolchain/yuku', 'oxc':'oxc-project/oxc', 'cordis':'cordiverse/cordis', 'webui':'cordiverse/webui', 'vue-core':'vuejs/core', 'vite':'vitejs/vite', 'swc-next':'swc-project/swc-next'}
    for name, revision in meta['revisions'].items():
        text.append(f'- [{name} `{revision}`](https://github.com/{owners[name]}/tree/{revision})')
    text.append('')
    paragraph(f"[README.md](README.md) documents commands and measurement definitions. Both Rust wrappers have checked-in Cargo lockfiles; [sources.lock.json](sources.lock.json) pins upstream source commits. [raw.json](results/raw.json) contains **{len(raw)} samples** across **{len(summary)} build/group combinations**. Wall min–max values are observed sample-average ranges, not confidence intervals. Run `uv run --locked bench/transform/run.py report` to regenerate this report from saved results.")
    paragraph('This is one machine and corpus snapshot. CPU affinity, thermal/frequency controls and system-wide idleness were not enforced. Python call overhead matters most for tiny groups; RSS depends on OS/allocator behavior. No cold-start latency, full application execution, final Origine binary-size delta or full embedded-V8 RSS was measured. Origine’s current mixed Oz/O3, 16-codegen-unit, unwind profile differs from these uniform benchmark profiles; changing its profile requires a separate final-binary test. Aborting panics here must not be copied into its panic-catching ABI without reviewing that contract. These results do not predict Linux/x86-64 or other V8 builds.')
    (root / 'report.md').write_text('\n'.join(text))
