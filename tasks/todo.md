# TODO: Playwright.jl — Milestone 5 (documentation, examples and release readiness)

Spec: `SPEC-M5.md`. See `tasks/plan.md` for full task descriptions, acceptance
criteria, and verification steps. Milestones 1–4 are archived under `tasks/m1/`
… `tasks/m4/`.

Sizes: (S) small, (M) medium, (L) large.

## Phase 1: Groundwork, probe and first CI

- [x] T0: `LICENSE` (MIT) + compat bounds on every dep + ignore rules (S) —
      no deps
- [x] T1: **PROBE** — headless WebGL for WGLMakie on both engines, findings to
      `tasks/m5-probe.md` (M) — **gate**: fixes B4's assertion level (D8)
      - Chromium renders in full with **no launch flags**; Firefox has no WebGL
        at all and cannot be given one.
      - ✅ **reviewed and approved 2026-08-05: D8 level 3**, Chromium-only for
        the pixel assertion, Firefox kept as a structural leg
- [x] T2: CI — hermetic matrix (1.10, `1`) + codegen check + format check (M) —
      **gate**: the first green run on a pushed branch
      - green: run `30989693673` (all four jobs, branch `m5-ci`, PR #1)
      - gate proved by breaking it: run `30989885239` — Formatting red on a
        deliberately misformatted line, the other three still green; reverted
- [x] T3: CI — smoke job, both engines, browsers cached (M) — deps: T2
      - green on both engines: run `30991010525` (cache miss, install took 40s)
      - **cache hit read out of the log**, run `30991908771`: "Cache restored
        successfully", and the *Install driver and browsers* step **skipped**

T0 ∥ T1 ∥ T2 — disjoint. T1 needs a browser; T0 and T2 do not.

### Checkpoint A
- [x] `LICENSE` present; hermetic `Pkg.test()` green under the new compat bounds
- [x] CI green on a **pushed** branch, Julia 1.10 and `1`
- [x] `gen/generate.jl --check` and the format check green in CI
- [x] Smoke job green on Chromium **and** Firefox, with a cache **hit** read out
      of a second run's log (not assumed)
- [x] **Human review of the T1 probe findings before T7 is written** — approved
      2026-08-05 as D8 level 3. WGLMakie was not dropped.

## Phase 2: Examples

- [x] T4: `examples/` scaffold (`common.jl`, `runexamples.jl`, pinned Manifest)
      + HTTP.jl example (M) — B1, no deps
- [x] T5: Oxygen.jl example (S) — B2, deps: T4
- [x] T6: Genie.jl example (M) — B3, deps: T4
      - measured warm-up: **25.0s** from `up()` to the first answered request
- [x] T7: WGLMakie.jl example (M) — B4, deps: **T1**, T4
      - level 3 as approved; **not flaky**: three consecutive runs all exit 0
        with `colours = 1692` every time
- [x] T8: CI — examples job + weekly unpinned drift job (S) — deps: T2, T4–T7

T5 ∥ T6 ∥ T7 once T4 is in — separate files, one shared `Project.toml`, so
sequence the dependency additions.

### Checkpoint B
- [x] All four examples exit 0 **locally**, from a clean checkout, on Chromium
      and Firefox — `runexamples.jl`, 8/8 PASS
- [x] All four green in CI on the committed Manifest — run `31004938737`
- [x] No example is flaky — T7 run three times, `colours = 1692` every time,
      and no retries were added to make that true
- [x] `Project.toml`'s `[deps]` still unchanged — `[deps]` section diffs
      identical against `main`

## Phase 3: Documentation

- [x] T9: docstring audit + gap fill + `tasks/m5-api-gaps.md` (L) — no deps,
      **start immediately**; the critical path runs through here
- [x] T10: Documenter scaffold + `api.md` + `checkdocs` gate (M) — deps: T9
      - zero-warning build; gate proved by deleting `title`'s docstring —
        build red on `:docs_block` and `:cross_references` — then restored
- [x] T11: guide pages (L) — deps: T10
- [x] T12: example pages, source included from the executed file (S) —
      deps: T10, T4–T7
      - **SC 9 verified** — a marker added to `examples/http_jl.jl` appeared in
        the built page with `http.md` byte-identical (md5 unchanged)
      - the WGLMakie page states its level honestly (SC 8)
- [x] T13: doctests on a browser-free path (S) — deps: T10
      - gate proved by breaking it: changing one expected value to `7.5` turned
        the build red on `doctest failure`; restored
- [x] T14: README slims to a landing page (S) — deps: **T11**
      - 137 lines, down from 517; no API reference material left
- [x] T15: docs workflow + deploy (M) — deps: T10
      - build green in CI: run `30995545900`
      - ⛔ deploy and the Pages repo-setting are only exercised on `main`

T9 needs no browser, no network and no CI — the ideal offline task, and the
longest. T11 ∥ T12 ∥ T13 ∥ T15 once T10 is in.

### Checkpoint C
- [x] `docs/make.jl` builds with **zero warnings**, `checkdocs = :exports` on
- [x] Gate verified by breaking it: `title`'s docstring deleted → build failed
      on `:docs_block` and `:cross_references` → restored
- [x] Doctests pass; an expected `7.0` changed to `7.5` → build red → restored
- [x] Example page changes when its script is edited, with no `.md` edit —
      marker in `examples/http_jl.jl` reached the built page, `http.md` md5
      unchanged
- [x] `README.md` under 150 lines (137), no API reference material left
- [ ] ⛔ Site deployed and reachable at its Pages URL — **needs the merge to
      `main`**; the build half is green (run `31004938747`)
- [x] Deploy authenticated by the workflow's `GITHUB_TOKEN`, with **no repository
      secret created** (D10)
- [ ] ⛔ **Repo-settings step:** GitHub Pages pointed at the `gh-pages` branch —
      web UI, after the first deploy

## Phase 4: Release metadata and proof

- [x] T16: TagBot, CompatHelper, Dependabot, README badges (S) — deps: T2, T15
      - badges added in T14; workflows parse and appear in the Actions tab
      - ⛔ CompatHelper's manual trigger needs the workflow on `main` first
- [x] T17: final verification of all sixteen success criteria (M) — deps: all

### Checkpoint D
- [x] All sixteen `SPEC-M5.md` success criteria verified, each by running it —
      table below; SC 13 is the one exception and says so
- [x] Gates confirmed still on: `checkdocs = :exports` and `warnonly = false`
      in `docs/make.jl`; `doctest = true`; both engines in the smoke job and in
      `runexamples.jl`. None were weakened to make anything green.
- [x] `tasks/m5-api-gaps.md` non-empty — nine items — and **nothing in it was
      fixed** (Assumption 2)

## Verification table

Filled in by T17 — one row per criterion, naming the command or run that proved
it, in the style of `tasks/m4/todo.md`. "smoke" means both engines under
`PLAYWRIGHT_JL_SMOKE=1`; "hermetic" means no Node and no browser.

| SC | Verified by |
|---|---|
| 1 | `julia --project=docs docs/make.jl` — 0 lines matching error/warning, with `checkdocs = :exports` and `warnonly = false` |
| 2 | A script comparing the `@docs` block list against `names(Playwright)` reports both differences empty. Gate proved by deleting `title`'s docstring: build red, then restored |
| 3 | Doctests run inside the docs build (`doctest = true`), on `from_serialized`, `Not` and `DriverError`. Proved by changing an expected `7.0` to `7.5`: `doctest failure`, then restored |
| 4 | Built tree: index, getting-started, six guide pages, four example pages, api.md — all reachable and warning-free |
| 5 | `wc -l README.md` = **137**; `grep` for API tables finds none |
| 6 | `runexamples.jl`: `http_jl.jl` PASS on chromium (26.1s) and firefox (27.0s) |
| 7 | `runexamples.jl`: `oxygen_jl.jl` PASS 44.2s/43.5s, `genie_jl.jl` PASS 49.1s/53.1s, both engines |
| 8 | `wglmakie_jl.jl` PASS 107.7s/107.2s at the approved level 3; the docs page states the Chromium-only limitation with its evidence |
| 9 | Marker comment added to `examples/http_jl.jl` appeared in `docs/build/examples/http.html` while `docs/src/examples/http.md` stayed md5-identical; marker removed |
| 10 | CI run `31004938737`: Julia 1.10 ✅, Julia 1 ✅, Generated code in sync ✅, Formatting ✅ |
| 11 | Smoke green both engines, run `30991010525` (miss, install 40s) and `30991908771` — **"Cache restored successfully"** in the log and the install step **skipped** |
| 12 | Examples job green in CI, run `31004938737`, on the committed Manifest (no `--update`) |
| 13 | ⛔ **Not verified.** The deploy only runs on `main` and Pages must be pointed at `gh-pages` in the web UI. The build half is green: Documentation run `31004938747` |
| 14 | `LICENSE` is MIT/2026; `test/test_project.jl` asserts every `[deps]` and `[extras]` entry has a `[compat]` bound; TagBot, CompatHelper and dependabot.yml all parse |
| 15 | Hermetic `Pkg.test()` 1238 pass, no Node/browser; smoke 1864 pass; `gen/generate.jl --check` in sync; `format(".")` returned `true`; `[deps]` section diffs identical against `main` |
| 16 | `tasks/m5-api-gaps.md`, nine items, none fixed — `fill` not being in `names(Playwright)` is worked around in api.md rather than corrected |

## A note on the one flaky-looking result

The first full `runexamples.jl` sweep reported `genie_jl.jl` and
`wglmakie_jl.jl` failing on Chromium — and it was my fault, not the examples'.
I had started that sweep while the smoke suite was still running in another
process, so two sets of browsers and two sets of local servers were competing
for the same machine. Genie failed in 12.8s, well short of its own 25s warm-up,
which is the tell.

Re-run on a quiet machine: **8/8 PASS**. The examples job in CI passed
independently on the same commit, and T7 had already been run three times
consecutively with an identical pixel count. Recorded here rather than quietly
re-run, because "it passed the second time" is exactly the sentence that hides
a real flake — the difference is that this one has a cause.
