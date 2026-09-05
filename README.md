# strictmigrate

**Delegate a Swift 6 strict-concurrency migration to agents — with the compiler as judge and a journal as the single source of truth.**

The official migration guide is a great 40-page document. strictmigrate turns those 40 pages into an executable task queue: the compiler counts the verdicts, the journal records where the migration stands, and the agent (or a human) holds the pen in between.

**v0.1 — measure, journal, report.** Useful with zero agents: point it at a Swift package, get per-target strict-concurrency diagnostic counts, and track them to zero.

```console
$ strictmigrate status
strictmigrate — Swift 6 strict concurrency migration
journal: strictmigrate.yaml.journal

Target            Level      Sendable  Isolation  Region  Other  Total   Progress
─────────────────────────────────────────────────────────────────────────────────────────────
ImagePipelineCore complete          1          3       0      0      4   ▓▓▓▓▓░░░░░    50%
DemoApp           complete          0          0       2      0      2   ░░░░░░░░░░     0%

Total: 6 remaining concurrency diagnostics (from 8 initial) — 25% complete across 2 targets
```

That table is the migration meeting. No wiki page, no memory of "what we already fixed" — data.

## Why

Migrating a large Swift 5 codebase to Swift 6 strict concurrency means hundreds to thousands of Sendable / actor-isolation diagnostics the moment you raise `StrictConcurrency` from `minimal` toward `complete`:

1. **Scale** — too many diagnostics to triage in an afternoon, or a quarter.
2. **Official support stops at docs and syntax** — `swift-migrator` flips flags and syntax; deciding *how* a type becomes `Sendable`, or where an actor boundary should sit, is semantic work. Verifying that work is mechanical: build, count, test.
3. **Delegating it wholesale to an agent fails structurally** — context limits cause partial fixes, sessions regress previous work, and nobody records how far you got. There is no revert boundary.

strictmigrate's bet: split the diagnostics into atomic tasks, let an agent execute one task at a time, judge each result deterministically (build + tests + diagnostic counts), and journal every verdict so any session — human, agent, or CI — reads the same state. v0.1 ships the measurement and journaling half; the agent loop lands in v0.3.

## Install

Requires a Swift 6+ toolchain (Xcode 16+ on macOS).

```console
$ git clone https://github.com/<you>/strictmigrate
$ cd strictmigrate && swift build -c release
$ cp .build/release/strictmigrate /usr/local/bin/   # or anywhere on PATH
```

## Quickstart

```console
$ cd YourSwiftPackage

$ strictmigrate init
Created strictmigrate.yaml.journal

$ strictmigrate measure
Building with -strict-concurrency=complete …
build: swift build --no-color-diagnostics --scratch-path .strictmigrate/measure-scratch -Xswiftc -strict-concurrency=complete (exit 1)
diagnostics: 6 tracked (sendable 1, isolation 3, region 2, other 0); 0 unrelated, not counted

Target             Sendable  Isolation  Region  Other  Total   Δ vs previous
ImagePipelineCore         1          3       0      0      4   new
DemoApp                   0          0       2      0      2   new

journal updated: strictmigrate.yaml.journal

$ strictmigrate status                  # pretty table (above)
$ strictmigrate status --format markdown # paste into a PR or issue
$ strictmigrate status --format json     # feed CI or dashboards
```

Commit `strictmigrate.yaml.journal`. Raw build logs land in `.strictmigrate/`, which ignores itself.

A live example lives in [`Examples/DemoConcurrency`](Examples/DemoConcurrency) — a tiny package with intentional violations of all three categories.

## Commands

| Command | What it does |
|---|---|
| `strictmigrate init` | Create an empty journal in the package root. |
| `strictmigrate measure` | Build with strict concurrency, count diagnostics per target, update the journal. |
| `strictmigrate status` | Render the journal as a report (`pretty`, `markdown`, `json`). |

### `measure` options

- `--level minimal|targeted|complete` — strict-concurrency level to measure at (default `complete`; the honest distance to Swift 6).
- `--with-tests` — include test targets (`swift build --build-tests`).
- `--incremental` — reuse the package's `.build`. Fast, but warnings from files that did not recompile are not re-emitted and will be undercounted. By default measure builds in a throw-away scratch directory so every diagnostic is emitted and counts are reproducible.
- `-Xswiftc <flag>` — pass extra swiftc flags (repeatable).
- `--xcresult <path>` — parse an existing result bundle instead of running `swift build` (see below).
- `--verbose` — list every tracked diagnostic after the summary.

A failing build is the *normal case* mid-migration: measure reports the exit code and counts what the compiler said. Diagnostics that are not concurrency-related (syntax errors, style warnings) are counted as `unrelated` and never enter the journal.

### Xcode projects

v0.1 measures SwiftPM packages directly. For Xcode projects, build once with a result bundle and hand it over:

```console
$ xcodebuild -scheme App -destination 'generic/platform=iOS' \
    -resultBundlePath build.xcresult \
    OTHER_SWIFT_FLAGS='$(inherited) -strict-concurrency=complete' build
$ strictmigrate measure --xcresult build.xcresult
```

If a `Package.swift` is present (xcodebuild on a package), diagnostics are attributed to package targets; otherwise they land under `(unattributed)` until target mapping ships for project files.

## The journal

One YAML file per repository, commit target, edited by `measure` and safe to edit by hand:

```yaml
version: 1
targets:
  ImagePipelineCore:
    level: complete          # minimal | targeted | complete
    diagnostics_baseline:    # latest measured counts
      sendable: 1
      isolation: 3
      region: 0
      other: 0
    diagnostics_initial:     # counts at first contact — progress denominator
      sendable: 2
      isolation: 3
      region: 0
      other: 0
    last_measured_at: '2026-09-06T00:00:00Z'
tasks: []                    # v0.2+: atomic tasks (one task = one commit = one revert boundary)
```

`status` computes progress as `1 − baseline/initial` per target. Regressions are reported honestly (you can see −50%), never clamped.

## How counting works

- **Collection** — `swift build` output is parsed from `file:line:col: error|warning:` lines (ANSI colors and hyperlink markup stripped, duplicates from the emit-module/per-file phases collapsed), or from `xcresulttool` JSON for result bundles.
- **Attribution** — files map to targets by longest source-root prefix from `swift package describe`. Clean targets appear with zeros; unmapped files land under `(unattributed)`.
- **Classification** — two deterministic layers: newer toolchains append stable diagnostic ids (`[#RegionIsolation::SendingRisksDataRace]`, `[#ActorIsolatedCall]`, `[#MutableGlobalVariable]`) which are preferred; older output falls back to keyword rules on the message text. Categories (`sendable`, `isolation`, `region`, `other`) are a prioritization aid — the tracked *total* is exact regardless of bucketing.

Known ground roughness, handled explicitly: incremental builds don't re-emit cached warnings (fresh scratch by default), xcresult locations are 0-based (normalized), and the root `issues` mirror per-action summaries (deduplicated).

## Design principles

- **The compiler is the judge.** Verdicts (build, tests, counts) are deterministic. The harness reports them, never manipulates them.
- **The journal is the single source of truth.** "How far along is the migration?" is answered by data, not memory or PR prose. CI, meetings, and agents all read the same file.
- **Agents hold the pen only.** In v0.3, an agent (claude-code, codex, ACP) writes the fix for one task; parsing, slicing, verdicts, journaling, and reverting stay deterministic code.
- **Atomic tasks.** One task = one symbol group = one commit — the revert boundary is always unambiguous.
- **Fully local.** Diagnostics, journal, and commits stay in the repository. Nothing is sent anywhere.

## Roadmap

- **v0.2** — task slicing + manual mode: cluster diagnostics by file/symbol, prioritize leaf targets, `strictmigrate next` prints the task and its prompt for copy-paste.
- **v0.3** — agent executor: claude-code adapter, automatic verdict/commit/revert, attempt limits.
- **v0.4** — codex/ACP adapters (Xcode agents), ThreadSanitizer verdicts, cross-target regression detection.
- **v0.5 (undecided)** — Kotlin K2/JVM strict mode adapter.

## Development

```console
$ swift test                            # unit tests + recorded-fixture tests
$ STRICTMIGRATE_SKIP_INTEGRATION=1 swift test   # skip the real-toolchain integration tests
```

The integration tests compile [`Examples/DemoConcurrency`](Examples/DemoConcurrency) with your local toolchain and assert exact diagnostic counts — they are the guardrail for the parsing pipeline.

## License

[MIT](LICENSE)
