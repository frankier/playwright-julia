# Implementation Plan: Playwright.jl — Milestone 5 (documentation, examples and release readiness)

Spec: [`SPEC-M5.md`](../SPEC-M5.md). Earlier plans are archived at
[`tasks/m1/plan.md`](m1/plan.md), [`tasks/m2/plan.md`](m2/plan.md),
[`tasks/m3/plan.md`](m3/plan.md) and [`tasks/m4/plan.md`](m4/plan.md).

## Context

M1–M4 built the package. M5 is about a person who has not read this repo: a
documentation site, four examples that drive real Julia web stacks, and CI that
runs the suites nobody currently remembers to run.

The shape of this milestone is unlike the previous four, and that changes how it
is planned.

**Almost nothing here is Julia API work.** M1–M4 were "design a function, probe
the protocol, test both engines". M5 is prose, YAML and example scripts. The one
piece that resembles previous milestones is T1's probe, and the one piece that
resembles previous *risks* is that the CI and docs deployment paths cannot be
fully verified on this machine — they are only true once pushed.

**The docs chain is the critical path, and it is long.** Docstring audit →
Documenter scaffold → guide pages → README slim → final verification is five
sequential tasks, and the first of them (T9) is the largest single task in the
milestone. It is also completely independent of everything else, so it starts
immediately and runs alongside the CI and example work rather than after it.

**Two tasks are gates, for different reasons.** T1 (WGLMakie probe) decides what
B4 can assert, exactly as M4's T1 decided what A1 could be built on. T2 (the
first CI workflow) is a gate of a softer kind: until CI has run green once on a
pushed branch, every later "CI passes" acceptance criterion is a guess.

## Architecture Decisions

Recorded as D1–D9 in `SPEC-M5.md`. The ones that drive this plan:

- **D2 — examples are a separate project with a committed Manifest**, so example
  work never touches `Project.toml` and a Genie breakage cannot redden
  `Pkg.test()`. Plus a weekly unpinned job to catch upstream drift on a cadence.
- **D3 — docs read the executed example source at build time**, so T12 (example
  pages) is small: it writes prose and an `@eval` include, never code.
- **D4 — the docs build never launches a browser**, which decouples the entire
  docs chain from browser flake and lets T10–T15 proceed without a working
  smoke job.
- **D5 — `checkdocs = :exports` with warnings-as-errors**, which is why T9
  (docstring audit) must land *before* T10 introduces the gate: turning the gate
  on over an incomplete surface produces a wall of failures instead of a signal.
- **D6 — Linux-only, Julia 1.10 and `1`.** Keeps T2 small.
- **D8 — WGLMakie is probe-gated** with three acceptable assertion levels.

## Dependency Graph

```
T0 LICENSE (MIT) + compat bounds + ignore rules   [hermetic, no deps]

T1 PROBE — headless WebGL for WGLMakie            ← gate: sets B4's level
 └── T7 WGLMakie example                     [B4]

T2 CI: hermetic matrix + codegen + format    [C1]  ← gate: first green run
 ├── T3 smoke job, browsers cached           [C2]
 └── T8 examples job                         [C3]  ← also deps T4–T7

T4 examples scaffold + HTTP.jl example       [B1]
 ├── T5 Oxygen.jl example                    [B2]
 ├── T6 Genie.jl example                     [B3]
 └── T7 WGLMakie.jl example                  [B4, deps T1]
      └── T8 examples CI job

T9 docstring audit + gaps + m5-api-gaps.md   [A3]  ─ hermetic, no deps
 └── T10 Documenter scaffold + api.md + checkdocs gate   [A1, A2]
      ├── T11 guide pages from README        [A4]
      │    └── T14 README slims to a landing page        [A5]
      ├── T12 example pages (D3 include)     [deps T4–T7]
      ├── T13 doctests                       [SC 3]
      └── T15 docs workflow + deploy         [C4]

T16 TagBot, CompatHelper, Dependabot, badges [C5]  ← deps T2, T15
T17 Final verification of all 16 success criteria  ← deps everything
```

Critical path: **T9 → T10 → T11 → T14 → T17.**

Parallelizable, and worth exploiting because the two halves need different
things: **T9 needs no network, no browser and no CI** — it is reading `src/` and
writing docstrings, the ideal offline task. **T1, T2 and T4** need a browser, a
pushed branch and four heavy dependency trees respectively. A session with no
browser available should pick up T9 and get most of the milestone's writing done.

Serialisation constraints not visible in the graph:

- **T10 must follow T9.** D5's gate is only useful over a complete surface.
- **T14 must follow T11.** The README can only shed material once the site has
  somewhere to put it; doing it in the other order deletes content that has no
  home yet.
- **T3, T8 and T15 all write `.github/workflows/`.** T3 and T8 both edit
  `CI.yml` — land them one at a time. T15 writes its own file and is disjoint.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Headless WebGL does not render in CI** — WGLMakie's example asserts on a blank canvas, or worse, renders locally and not in the container | High — could gut B4 | T1 probes *in a container-like environment* before the example is written, and D8 pre-authorises three fallback levels so a negative result narrows the example rather than blocking the milestone. Dropping WGLMakie entirely stays an *Ask first* boundary |
| **CI cannot be verified locally.** Workflow YAML is only truly tested by pushing | High — every "CI passes" criterion | T2 is deliberately first and deliberately minimal (hermetic tests only), so the first push proves the *scaffolding* — checkout, setup-julia, cache, `Pkg.test()` — before anything complicated is layered on. Later CI tasks add one job each |
| **Docs deployment is the one step with no local dry run** — it is only true once pushed to `main` | Med — blocks SC 13 only | D10 removes the secret from the picture: `GITHUB_TOKEN` is issued to the run, so there is nothing to generate and no owner-only step. T15 still splits *build* (verified locally, gates PRs) from *deploy* (only on `main`), so a deploy problem cannot masquerade as a docs problem. Residual risk is repo settings — Pages must be pointed at `gh-pages` once, in the web UI |
| **Turning on `checkdocs` reveals dozens of gaps at once** and T10 balloons | Med | T9 does the audit and the writing *first*, with the gap list as its deliverable; T10 then only turns the gate on. If T9's audit finds the surface is far worse than expected, that is visible before any Documenter work starts |
| **Writing docs uncovers API gaps and the temptation is to fix them** | Med — scope creep into an API milestone | `SPEC-M5.md` Assumption 2 and SC 16: gaps go into `tasks/m5-api-gaps.md` and stay unfixed. This is an *Ask first* boundary, and T9 is where it will bite |
| **Genie.jl is slow to load and may time out in CI** | Med | Its own job with a generous timeout; the example uses `retry_until(…; on_error = :retry)` for warm-up, which is precisely the M4 feature it is meant to demonstrate. If load time is genuinely prohibitive, the finding is recorded rather than worked around with `sleep` |
| **Four example servers collide on ports** in a shared CI runner | Low | `examples/common.jl` binds port 0 and reads back the assigned port; no example hard-codes one. `runexamples.jl` runs them sequentially |
| **The browser cache key is wrong** and CI silently redownloads every run | Low, but permanently slow | SC 11 requires reading a cache *hit* out of a second run's log, not assuming one. Key is the pinned `PLAYWRIGHT_VERSION` (D7) |
| **The committed examples Manifest hides upstream breakage** | Low | D2's weekly unpinned job, added in T8. Its failure means "the ecosystem moved", and it cannot redden a PR |
| **README and site drift apart**, the classic outcome of splitting docs | Med | T14 makes the README strictly a landing page (SC 5, under 150 lines) with no API material, so there is one home for each fact rather than two |
| **A gate gets weakened to make CI green** | High — it would void the milestone | Named explicitly in `SPEC-M5.md` Boundaries as *Never*. T17 re-checks that `checkdocs`, warnings-as-errors and both engines are still on |

## Verification Checkpoints

- **Checkpoint A** — after T0–T3: `LICENSE` present; hermetic CI green on a
  *pushed* branch across Julia 1.10 and `1`; codegen and format checks green;
  smoke job green on both engines with a verified cache hit. **Human review of
  the T1 probe findings before T7 is written** — this is the gate that fixes
  B4's assertion level.
- **Checkpoint B** — after T4–T8: all four examples exit 0 locally *and* in CI on
  both engines, from a clean checkout, on the committed Manifest.
- **Checkpoint C** — after T9–T15: `docs/make.jl` builds with zero warnings under
  `checkdocs = :exports`; doctests pass; the site's navigation is complete; the
  README is under 150 lines; the site is deployed and reachable.
- **Checkpoint D** — after T16–T17: all sixteen `SPEC-M5.md` success criteria
  verified, each by running the thing, not by reasoning about it.

## Tasks

### T0 — Licence, compat bounds and ignore rules (S) — no deps

- **Description:** The release-metadata groundwork that needs no CI and blocks
  nothing, done first so it cannot be forgotten at the end. `SPEC-M5.md` D9
  notes the current `[compat]` block is backwards: it bounds `HTTP` (a *test*
  dependency) while `Base64`, `Dates`, `Downloads` and `p7zip_jll` — real
  dependencies — carry none.
- **Acceptance:** `LICENSE` is MIT, dated 2026, attributed to Frankie Robertson
  (resolved: `SPEC-M5.md` Open Question 1). Every entry in `[deps]` has a
  `[compat]` bound; stdlib entries get bounds too, as Registrator requires.
  `julia = "1.10"` unchanged. `docs/build/` and `examples/Manifest.toml`'s
  scratch output are handled in `.gitignore` (the Manifest itself is committed —
  D2).
- **Verify:** `Pkg.instantiate()` and hermetic `Pkg.test()` still green under the
  new bounds — a too-tight bound shows up here; `git diff Project.toml` shows
  `[deps]` unchanged (SC 15).
- **Files:** `LICENSE`, `Project.toml`, `.gitignore`.

### T1 — PROBE: headless WebGL for WGLMakie (M) — gate for B4, D8

- **Description:** Find out whether a WGLMakie page actually renders in a
  headless browser in a CI-like container, before an example is designed around
  the assumption. The unknown is not the Julia side; it is whether the engine has
  a working software rasteriser.
- **Acceptance:** `tasks/m5-probe.md` records, with evidence:
  1. Whether a minimal WGLMakie/Bonito page renders on **Chromium** and on
     **Firefox** headless — evidenced by a screenshot whose pixels are *not*
     uniform, plus the pixel statistic used to decide.
  2. Any flag needed to get there (`--use-gl=swiftshader`, `--enable-unsafe-swiftshader`
     or similar), recorded as the exact `launch` argument this repo would pass.
  3. Whether it holds with no GPU and no X display, i.e. the CI condition, not
     just this workstation.
  4. Page errors and console output from the load, which tell us what a
     *structural* assertion could key on if rendering is out.
  5. **A recommendation of one of D8's three levels** — full, structural, or
     Chromium-only.
- **Verify:** findings reproduced by a second run; **human review before T7
  starts.** If the answer is "no rendering on either engine", that is a valid
  outcome (level 2), not a blocker — but **dropping WGLMakie is *Ask first***.
- **Files:** probe script under the `@pw-probe` shared env, `tasks/m5-probe.md`.

### T2 — CI: hermetic tests, codegen and format (M) — C1, D6, gate

- **Description:** The first workflow this repo has ever had. Kept minimal on
  purpose: its job is to prove the scaffolding — checkout, Julia setup, caching,
  `Pkg.test()` — so that later jobs are layered onto something known-good.
- **Acceptance:** `.github/workflows/CI.yml` runs on push and PR: a matrix of
  Julia 1.10 and `1` on `ubuntu-latest` running hermetic `Pkg.test()` with no
  Node and no browser; plus single-version jobs for `gen/generate.jl --check` and
  a JuliaFormatter check using the pinned formatter from `gen/`. Uses
  `julia-actions/setup-julia`, `julia-actions/cache`, `julia-actions/julia-runtest`.
  Concurrency group cancels superseded runs.
- **Verify:** **pushed to a branch and observed green** — this task is not done
  on the strength of the YAML reading correctly. Confirm the format job actually
  fails by pushing one badly formatted line, then reverting.
- **Files:** `.github/workflows/CI.yml`.

### T3 — CI: smoke job with cached browsers (M) — C2, D7, deps: T2

- **Description:** The job that makes CI mean something for this package: real
  Chromium and Firefox against the local fixtures.
- **Acceptance:** A `smoke` job on one Julia version sets `PLAYWRIGHT_BROWSERS_PATH`
  to a workspace path, restores it with `actions/cache` keyed on the pinned
  `PLAYWRIGHT_VERSION` from `src/driver.jl`, runs `julia bin/install.jl` on a
  cache miss, and runs `PLAYWRIGHT_JL_SMOKE=1 Pkg.test()`. Both engines in one
  job (D7). Node comes from `actions/setup-node` or the driver's own fetch —
  whichever the install path already expects.
- **Verify:** green in CI on both engines; **a second run shows a cache hit in
  the log** (SC 11) and is materially faster; a deliberate bump of the cache key
  shows a miss and a successful reinstall.
- **Files:** `.github/workflows/CI.yml`.

### T4 — Examples scaffold and the HTTP.jl example (M) — B1, D2, no deps

- **Description:** The pattern every other example follows: start a server on a
  free port, wait for it to warm up, drive it with the public API, tear it down
  in a `finally`. HTTP.jl is chosen first because it is the thinnest possible
  server, so the example shows *the pattern* and not a framework's conventions.
- **Acceptance:** `examples/Project.toml` with HTTP, Test and Playwright (by
  relative path), plus a committed `examples/Manifest.toml`. `examples/common.jl`
  holds exactly two helpers — `free_port` (bind port 0, read it back) and a
  server warm-up built on `retry_until(…; on_error = :retry)`. `examples/http_jl.jl`
  serves a small page, drives it, asserts on rendered DOM, and exits non-zero on
  failure. `examples/runexamples.jl` runs every example and aggregates.
  `Project.toml`'s `[deps]` untouched.
- **Verify:** `julia --project=examples examples/http_jl.jl` exits 0 from a clean
  checkout on Chromium **and** Firefox (SC 6); it starts and stops its own server,
  leaving no process behind; it reads as something a user would copy.
- **Files:** `examples/Project.toml`, `examples/Manifest.toml`,
  `examples/common.jl`, `examples/http_jl.jl`, `examples/runexamples.jl`.

### T5 — Oxygen.jl example (S) — B2, deps: T4

- **Description:** A modern micro-framework: routes plus a rendered page. Shows
  asserting on *both* halves of a typical app — a JSON endpoint and the DOM.
- **Acceptance:** `examples/oxygen_jl.jl` defines at least one JSON route and one
  HTML route, drives the page, and asserts on the JSON endpoint through the
  browser (via `evaluate` and `fetch`, so it is the browser's view, not Julia's).
  Same start/stop discipline as T4.
- **Verify:** exits 0 on both engines (SC 7); no leaked server.
- **Files:** `examples/oxygen_jl.jl`, `examples/Project.toml`, `Manifest.toml`.

### T6 — Genie.jl example (M) — B3, deps: T4

- **Description:** The full framework, and the slowest to start — which is the
  point. This is the example where `retry_until`'s warm-up mode earns its place
  rather than being demonstrated on a server that was ready instantly.
- **Acceptance:** `examples/genie_jl.jl` stands up a Genie app with real routing
  and HTML rendering, drives it, and asserts on rendered content. The warm-up
  wait is the M4 API, never a `sleep`.
- **Verify:** exits 0 on both engines (SC 7). Record its wall-clock startup in
  the example's comments — it is the honest justification for the whole warm-up
  feature.
- **Files:** `examples/genie_jl.jl`, `examples/Project.toml`, `Manifest.toml`.

### T7 — WGLMakie.jl example (M) — B4, D8, deps: T1, T4

- **Description:** The hardest example and the one that justifies M4: an
  interactive plot, screenshotted and traced. Its assertion level is **not chosen
  here** — it was fixed by T1's probe and human review.
- **Acceptance:** `examples/wglmakie_jl.jl` serves a WGLMakie figure through
  Bonito, drives the page, and asserts at the level T1 selected: rendered-pixel
  content (level 1), DOM plus no-page-errors (level 2), or Chromium-only
  (level 3). It captures a screenshot and a trace zip into an ignored output
  directory, demonstrating the M4 artifact API on a real app. **If the level is
  not "full", the example says so in a comment** — the docs page repeats it
  (SC 8).
- **Verify:** exits 0 at the selected level; run three times to confirm it is not
  flaky. A flaky example is a failed task, not a passing one — retries are not an
  acceptable fix.
- **Files:** `examples/wglmakie_jl.jl`, `examples/Project.toml`, `Manifest.toml`,
  `.gitignore`.

### T8 — CI: examples job and the weekly drift job (S) — C3, D2, deps: T2, T4–T7

- **Description:** Run the examples in CI on the pinned Manifest, plus the
  scheduled unpinned run that catches upstream drift without reddening PRs.
- **Acceptance:** An `examples` job installs browsers (sharing T3's cache), then
  runs `julia --project=examples examples/runexamples.jl`. A separate scheduled
  weekly workflow deletes `examples/Manifest.toml`, resolves fresh, and runs the
  same script; its failure is clearly labelled as upstream drift.
- **Verify:** examples job green in CI (SC 12); the weekly job triggered once by
  hand (`workflow_dispatch`) to prove it runs at all.
- **Files:** `.github/workflows/CI.yml`, `.github/workflows/drift.yml`.

### T9 — Docstring audit, gap fill, and the API-gap record (L) — A3, D5, SC 16

- **Description:** The largest task in the milestone and the one with no
  dependencies. Walk the ~90-name export list, and for each: does it have a
  docstring, does that docstring start with its signature, does it explain
  arguments and defaults, does it show an example, does it cross-reference its
  neighbours? Write what is missing.
- **Acceptance:** Every exported name in `src/Playwright.jl` has a docstring in
  the `SPEC-M5.md` Code Style shape. Cross-references use `[`name`](@ref)`.
  Separately, `tasks/m5-api-gaps.md` records every API awkwardness found while
  writing — inconsistent argument order, a missing keyword, a name that had to be
  explained apologetically — **without fixing any of them** (Assumption 2).
- **Verify:** a script enumerating `names(Playwright)` against
  `Docs.meta(Playwright)` reports zero undocumented exports; the gap document is
  non-empty (if writing ~90 docstrings surfaces *no* API awkwardness, the audit
  was not honest).
- **Files:** all of `src/api/*.jl`, `src/errors.jl`, `src/objects.jl`,
  `src/timeouts.jl`; `tasks/m5-api-gaps.md`.

### T10 — Documenter scaffold, API reference and the checkdocs gate (M) — A1, A2, D5, deps: T9

- **Description:** Stand up the site's skeleton and turn on the gate that keeps
  it honest. Deliberately after T9, so the gate reports "green" rather than a
  wall of pre-existing gaps.
- **Acceptance:** `docs/Project.toml` (Documenter + Playwright by relative path),
  `docs/make.jl` calling `makedocs` with `checkdocs = :exports`, warnings as
  errors, and the page tree from `SPEC-M5.md` Project Structure. `docs/src/api.md`
  carries `@docs` blocks covering the full export list, grouped by area rather
  than alphabetically. `docs/src/index.md` exists as a landing page.
- **Verify:** `julia --project=docs docs/make.jl` builds with zero warnings
  (SC 1). **Delete one docstring, confirm the build fails, restore it** (SC 2) —
  the gate is verified by breaking it, not by trusting the setting.
- **Files:** `docs/Project.toml`, `docs/make.jl`, `docs/src/index.md`,
  `docs/src/api.md`, `.gitignore`.

### T11 — Guide pages (L) — A4, deps: T10

- **Description:** Move the README's substance into real guide pages, one per API
  area, expanding rather than transcribing: the README compresses because it is
  one file, and the site has no such constraint.
- **Acceptance:** `docs/src/getting-started.md` (install, `bin/install.jl`,
  browsers in CI, a first passing test) plus a `docs/src/guide/` page for each of
  locators, waiting, assertions, events, artifacts and the failure path, and
  errors and timeouts. Every page cross-links into the API reference with
  `@ref`. Browser-requiring samples are plain ` ```julia ` (D4).
- **Verify:** docs build stays at zero warnings — a broken `@ref` fails it;
  navigation tree complete (SC 4); read each page start to finish for a reader
  who has not seen the README.
- **Files:** `docs/src/getting-started.md`, `docs/src/guide/*.md`, `docs/make.jl`.

### T12 — Example pages (S) — D3, deps: T10, T4–T7

- **Description:** One page per example. Small by construction: the code is
  *read from the executed file at build time*, so this task writes only prose and
  the include.
- **Acceptance:** Four pages under `docs/src/examples/`, each with the D3 `@eval`
  include of its `examples/*.jl` file and prose explaining why the example is
  shaped as it is. The WGLMakie page states its assertion level honestly if it is
  not "full" (SC 8).
- **Verify:** **edit an example script, rebuild, confirm the page changed with no
  `.md` edit** (SC 9) — the anti-drift property is verified, not assumed.
- **Files:** `docs/src/examples/*.md`, `docs/make.jl`.

### T13 — Doctests (S) — SC 3, deps: T10

- **Description:** Make at least some docstring examples executable. Constrained
  by D4: only browser-free paths qualify.
- **Acceptance:** At least one ` ```jldoctest ` block on a browser-free path —
  value serialisation, timeout resolution, or error construction — running as
  part of the docs build.
- **Verify:** doctests run and pass in the build (SC 3); break one deliberately
  and confirm the build goes red.
- **Files:** `src/serializers.jl`, `src/timeouts.jl` or `src/errors.jl`;
  `docs/make.jl`.

### T14 — README becomes a landing page (S) — A5, deps: T11

- **Description:** The README stops being the manual. Strictly after T11, so
  nothing is deleted before the site has a home for it.
- **Acceptance:** `README.md` under 150 lines: what the package is, badges,
  install, a quick-start snippet, the testing commands, the generated-channel-layer
  note, Status, and links into the site. **No API reference material remains**
  (SC 5).
- **Verify:** line count; read it as a stranger — every removed fact is findable
  on the site in one click.
- **Files:** `README.md`.

### T15 — Docs workflow and deployment (M) — C4, deps: T10

- **Description:** Build the docs in CI on every push, and deploy on `main`.
  Split deliberately: the build gates PRs and is fully verifiable locally, while
  the deploy is only ever exercised on `main` — keeping them separate means a
  deployment problem cannot masquerade as a documentation problem.
- **Acceptance:** `.github/workflows/docs.yml` builds the docs (with doctests and
  the `checkdocs` gate) on push and PR, and calls `deploydocs` on `main`
  authenticated by the workflow's built-in `GITHUB_TOKEN` (D10). The job declares
  `permissions: contents: write` and nothing further. **No repository secret is
  created and none is required** — if the implementation finds itself wanting a
  `DOCUMENTER_KEY`, that contradicts D10 and is a stop-and-review, not a
  workaround.
- **Verify:** build job green in CI. Deploy verified by the site being reachable
  at its Pages URL (SC 13). One **repo-settings** step remains, in the web UI
  rather than in code: pointing GitHub Pages at the `gh-pages` branch after its
  first deploy.
- **Files:** `.github/workflows/docs.yml`, `docs/make.jl`.

### T16 — TagBot, CompatHelper, Dependabot and badges (S) — C5, D9, deps: T2, T15

- **Description:** The remaining release metadata. Nothing here bumps a version
  or submits anything (D9 — ready, not registered).
- **Acceptance:** `.github/workflows/TagBot.yml` and `CompatHelper.yml` in their
  standard forms; `.github/dependabot.yml` keeping the actions current. README
  badges for CI status and docs, pointing at real URLs.
- **Verify:** workflows parse and appear in the Actions tab; CompatHelper
  triggered once by hand; badges render and link correctly (SC 14).
- **Files:** `.github/workflows/TagBot.yml`, `.github/workflows/CompatHelper.yml`,
  `.github/dependabot.yml`, `README.md`.

### T17 — Final verification pass (M) — deps: everything

- **Description:** Walk all sixteen `SPEC-M5.md` success criteria and record how
  each was verified, in the table style M4's `todo.md` used. Every row is run,
  not reasoned about.
- **Acceptance:** A verification table in `tasks/todo.md` with one row per
  criterion naming the command or run that proved it. Explicitly re-confirm the
  gates are still on: `checkdocs = :exports`, warnings-as-errors, both engines in
  smoke, and `Project.toml`'s `[deps]` unchanged (SC 15).
- **Verify:** hermetic `Pkg.test()`, smoke on both engines, `gen/generate.jl
  --check`, `format(".")`, docs build, all four examples — one clean sweep, in
  one session, at the end.
- **Files:** `tasks/todo.md`.
