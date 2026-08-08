# Spec: Playwright.jl — Milestone 5 (documentation, examples and release readiness)

Successor to [`SPEC.md`](SPEC.md) (M1), [`SPEC-M2.md`](SPEC-M2.md) (M2),
[`SPEC-M3.md`](SPEC-M3.md) (M3) and [`SPEC-M4.md`](SPEC-M4.md) (M4), all four
complete. Tech stack, driver architecture, the codegen/API split, code style and
boundaries carry over unchanged unless contradicted here.

## Assumptions

Calls this spec makes without being told. Correct any that are wrong.

1. **New spec, not a rewrite.** `SPEC.md` and `SPEC-M2..4.md` stay as the record
   of milestones 1–4; this is `SPEC-M5.md`.
2. **No new API surface.** M5 adds no exported name and changes no existing
   signature. Writing documentation is the most reliable way to find API gaps,
   and this spec expects to find some — they are **recorded, not fixed**
   (Boundaries: *Ask first*). A milestone that both documents and moves the API
   documents a moving target.
3. **Playwright stays pinned at 1.61.1.** `PLAYWRIGHT_VERSION` in `src/driver.jl`
   remains the single source of truth.
4. **Sync-only, Julia floor 1.10.** Unchanged from M4 and for the same reasons.
5. **Release-*ready*, not released.** M5 produces everything registration in
   General would require — a licence, compat bounds, green CI, a docs site — and
   deliberately stops before submitting. Registration is a later, separate
   decision. No version bump beyond `0.1.0` is part of this milestone.
6. **The repo is `github.com/frankier/playwright-julia`** and docs deploy to
   GitHub Pages on that repo via `deploydocs`. GitHub Actions is the CI.
7. **The example frameworks are never package dependencies.** HTTP.jl,
   Oxygen.jl, Genie.jl and WGLMakie.jl appear only in an `examples/Project.toml`.
   Nothing in `[deps]` changes; `Project.toml`'s test target is untouched.
8. **Linux is the only platform CI claims.** The driver install path has only
   ever been exercised on Linux. See D6 — this is an assumption with a live open
   question attached, not a settled non-goal.
9. **Documentation describes `main`, not history.** One docs build, no version
   selector across milestones. `SPEC-M*.md` remain the historical record and are
   not folded into the site.

## Objective

M1–M4 built the package. **M5 is about a person who has not read this repo.**

Today the entire user-facing documentation is a 517-line `README.md`, and there
is no CI at all — not one workflow file. Every claim in the README, including
every claim in its Status section, is currently backed by nothing a stranger can
see. For a package whose whole purpose is *proving that a web app works*, that is
the wrong shape.

**The user** is a Julia developer who has a web app — an HTTP.jl handler, an
Oxygen route, a Genie site, a WGLMakie plot — and wants to know two things: can
this package drive it, and does it actually work? After this milestone they get a
documentation site with a searchable API reference, four examples that drive
*real* Julia web stacks and are executed by CI on every push, and a green badge
that means something.

**The second user is the maintainer.** M1–M4 were verified by running things by
hand, one milestone at a time. That does not survive contact with a second
contributor or a Playwright version bump. M5 makes the existing test suites —
hermetic, smoke, both engines — run without anyone remembering to run them.

### Part A — the documentation site

| # | Deliverable | Notes |
|---|---|---|
| A1 | **Documenter.jl project** — `docs/Project.toml`, `docs/make.jl`, `docs/src/`, deploying to GitHub Pages | D1 |
| A2 | **API reference from docstrings** — every exported name reachable from an `@docs` block, with `checkdocs` failing the build on a gap | D5 |
| A3 | **Docstring completion** — the gaps A2's gate exposes get written: every exported name gets a signature line, a prose description, arguments, and a runnable-looking example | |
| A4 | **Narrative pages** — the README's substance restructured into guide pages: getting started, browsers in CI, locators, waiting, assertions, events, artifacts and the failure path, errors and timeouts | A3 |
| A5 | **README becomes a landing page** — quick start, install, badges, and links into the site; it stops being the manual | |

### Part B — examples verified in CI

Four examples, each driving a real Julia web stack served in-process and asserted
against with this package's public API. They are the milestone's parity evidence:
not fixtures written to suit the library, but frameworks that existed first.

| # | Example | What it proves |
|---|---|---|
| B1 | **HTTP.jl** — a bare `HTTP.serve` handler | The baseline pattern: start a server on a free port, wait for it to warm up with `retry_until(…; on_error = :retry)`, drive it, tear it down. Every other example is a variation on this one. |
| B2 | **Oxygen.jl** — routes plus a small page | A modern micro-framework; asserting on both a JSON endpoint (via `evaluate`/`fetch`) and rendered DOM. |
| B3 | **Genie.jl** — a full-framework app | The heavyweight: real routing and HTML rendering, plus the slowest startup, which is exactly what `retry_until`'s warm-up mode exists for. |
| B4 | **WGLMakie.jl** — an interactive plot page | The hardest and the most valuable: a canvas/WebGL app, screenshotted and traced. This is the example that proves the artifact family from M4 is useful on something real. **Probe-gated — see D8.** |

Each example is a standalone runnable script, executed by CI, and included into
the docs *by reading the executed file* (D3) so the page cannot drift from what
CI ran.

### Part C — CI and release readiness

| # | Deliverable | Notes |
|---|---|---|
| C1 | **Test workflow** — hermetic `Pkg.test()` on a Julia matrix, plus `gen/generate.jl --check` and a formatting check | D6 |
| C2 | **Smoke workflow** — `PLAYWRIGHT_JL_SMOKE=1`, Chromium **and** Firefox, with the browser download cached | D7 |
| C3 | **Examples workflow** — the four Part B examples, on their own pinned Manifest | D2 |
| C4 | **Docs workflow** — build, doctest, and deploy to `gh-pages`; a docs failure is a red build | D4, D5 |
| C5 | **Release metadata** — `LICENSE` (there is none today), compat bounds on every dependency, TagBot and CompatHelper | D9 |

## Tech Stack

Unchanged, plus documentation-only and example-only tooling:

- **Documenter.jl** for the site (docs-only dependency).
- **GitHub Actions** — `julia-actions/setup-julia`, `julia-actions/cache`,
  `julia-actions/julia-buildpkg`, `julia-actions/julia-runtest`.
- **Example frameworks** — HTTP.jl, Oxygen.jl, Genie.jl, WGLMakie.jl (+ Bonito,
  which WGLMakie serves through), pinned by a committed `examples/Manifest.toml`.

No new runtime dependency. `Project.toml`'s `[deps]` is byte-identical at the end
of this milestone.

## Commands

Unchanged from M4, plus:

```
Instantiate:    julia --project=. -e 'using Pkg; Pkg.instantiate()'
Test:           julia --project=. -e 'using Pkg; Pkg.test()'
Smoke:          PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()'
Codegen check:  julia --project=gen gen/generate.jl --check
Format:         julia --project=. -e 'using JuliaFormatter; format(".")'
Driver setup:   julia bin/install.jl

Docs build:     julia --project=docs docs/make.jl
Docs (local):   julia --project=docs -e 'using LiveServer; servedocs()'
Doctests:       julia --project=docs docs/make.jl        # doctests run in-build
Examples:       julia --project=examples examples/runexamples.jl
One example:    julia --project=examples examples/http_jl.jl
```

Every example is runnable on its own, without the harness — that is what makes it
copy-pasteable, and copy-pasteable is the point.

## Project Structure

Additions only; `src/` is untouched except for docstrings.

```
docs/Project.toml        → NEW. Documenter (+ Playwright via a dev path)
docs/make.jl             → NEW. makedocs + deploydocs
docs/src/index.md        → NEW. Landing page
docs/src/getting-started.md   → NEW. Install, browsers, first test
docs/src/guide/*.md      → NEW. Locators, waiting, assertions, events,
                           artifacts, errors and timeouts
docs/src/examples/*.md   → NEW. One page per Part B example, source included
                           from examples/ at build time (D3)
docs/src/api.md          → NEW. @docs blocks over the exported surface
docs/bonnie-parity.md    → UNCHANGED. Stays a repo doc, not a site page

examples/Project.toml    → NEW. HTTP, Oxygen, Genie, WGLMakie, Test, Playwright
examples/Manifest.toml   → NEW, committed. D2
examples/http_jl.jl      → NEW. B1
examples/oxygen_jl.jl    → NEW. B2
examples/genie_jl.jl     → NEW. B3
examples/wglmakie_jl.jl  → NEW. B4
examples/runexamples.jl  → NEW. Runs all four, non-zero exit on any failure
examples/common.jl       → NEW. free_port, wait_for_server — the one piece of
                           shared scaffolding, kept tiny so each example still
                           reads standalone

.github/workflows/CI.yml        → NEW. C1 + C2 + C3
.github/workflows/docs.yml      → NEW. C4
.github/workflows/TagBot.yml    → NEW. C5
.github/workflows/CompatHelper.yml → NEW. C5
.github/dependabot.yml          → NEW. Keeps action versions current

LICENSE                  → NEW. C5, licence choice is an Open Question
README.md                → CHANGED. Slims to a landing page (A5)
```

`docs/` currently holds `bonnie-parity.md` and nothing else; adding a Documenter
project alongside it is why `docs/src/` exists as a subdirectory rather than
docs pages living at `docs/*.md`.

## Code Style

Documentation prose follows the specs' voice: concrete, no marketing, state the
constraint rather than apologise for it.

Docstrings follow one shape — signature, one-sentence summary, then detail.
Exactly as the existing good ones do:

````julia
"""
    retry_until(f, [target]; timeout = nothing, interval = 0.1,
                on_timeout = :throw, on_error = :throw)

Poll `f` until it returns `true` or the deadline passes.

`target` is any object with a timeout cascade — a `Page`, `Frame`, `Locator` or
`BrowserContext` — and opts this call into `set_default_timeout!`. Without it
the fallback is `DEFAULT_TIMEOUT`.

`on_timeout = :false` returns `false` instead of raising `AssertionFailure`,
which is what `@test retry_until(…)` needs to report a `Fail` rather than an
`Error`. `on_error = :retry` treats an exception from `f` as "not yet" — the
shape you want while a server is still warming up.

```julia
retry_until(page; on_error = :retry) do
    HTTP.get("http://localhost:8000/health").status == 200
end
```

See also [`expect`](@ref), [`wait_for_function`](@ref).
"""
````

Rules that the docs gate enforces rather than merely requests:

- Every exported name has a docstring whose first line is the signature.
- Cross-references use `[`name`](@ref)`, so a rename that breaks a link fails
  the build rather than rotting silently.
- Code blocks that can run without a browser are ` ```jldoctest ` and are
  executed. Anything needing a browser is plain ` ```julia ` — see D4.

Example scripts read as if a user wrote them: no test-harness cleverness, one
`@testset`, explicit teardown in a `finally`.

## Testing Strategy

Four tiers, three of them already exist. M5's job is to make them run
automatically and add the fourth.

| Tier | What | Where | CI |
|---|---|---|---|
| Hermetic | No Node, no browser. The bulk of the suite. | `test/` under `Pkg.test()` | Every push, full Julia matrix |
| Smoke | Real Chromium and Firefox against local fixtures. | `test/test_smoke.jl`, gated on `PLAYWRIGHT_JL_SMOKE=1` | Every push, one Julia version, browsers cached |
| Doctests | Docstring examples that need no browser. | Docstrings in `src/` | Docs job |
| **Examples** | **Real Julia web frameworks, end to end.** | `examples/` | Every push, own Manifest |

The examples tier is new and is deliberately *not* part of `Pkg.test()`. Its
dependencies are heavier than the package itself, and a Genie.jl breakage must
never be able to turn `Pkg.test()` red for someone who only wants to run the unit
tests.

Coverage expectation: not a percentage. The gate is `checkdocs` — every exported
name documented — plus every example green. Both are binary and neither can be
satisfied by writing more tests for code that already works.

## Boundaries

- **Always:** run the hermetic suite before committing; keep `src/generated/`
  generated; keep `Project.toml`'s `[deps]` unchanged; make every example
  runnable standalone; pin example versions in a committed Manifest.
- **Ask first:** any change to the exported API surface (Assumption 2 — record
  the gap and stop); the licence choice; adding a platform to the CI matrix;
  removing an example because it is inconvenient in CI.
- **Never:** commit a token or deploy key (deployment uses the workflow's
  built-in `GITHUB_TOKEN` — D10 — so there is no secret to leak, and none is to
  be added); make the docs build depend on a
  browser (D4); add an example framework to the package's dependencies; weaken a
  gate to make CI green.

## Decisions

**D1 — Documenter.jl, not an alternative.** It is what the Julia ecosystem
expects, it reads docstrings directly (so the API reference cannot drift from the
code), it runs doctests, and `checkdocs` gives the coverage gate D5 needs. The
alternatives (Franklin, a hand-written site) buy design freedom this package does
not need and give up the two mechanisms that make documentation *verified* rather
than *written*.

**D2 — the examples are a separate project with a committed Manifest.** Two
reasons, pulling the same way. First, dependency weight: Genie.jl and WGLMakie.jl
pull in large trees, and a user running `Pkg.test()` on Playwright.jl must not
pay for them. Second, determinism: with a committed `examples/Manifest.toml`, an
examples job going red is attributable to *this repo's change*, not to an
upstream release that happened overnight.

The obvious cost of pinning is that it hides upstream breakage. Mitigation: a
**scheduled weekly job** that deletes the Manifest, resolves fresh, and runs the
examples. Drift is then caught on a cadence, in a job whose failure means "the
ecosystem moved", without every unrelated PR going red for it.

**D3 — examples are executed as source, and the docs read that source.** The
example pages do not paste code. They read the file at build time:

````markdown
```@eval
using Markdown
Markdown.parse("```julia\n" * read(joinpath(@__DIR__, "..", "..", "..",
    "examples", "http_jl.jl"), String) * "\n```")
```
````

The file CI executes and the file the page shows are the same bytes, so the
classic documentation failure — a sample that no longer runs — is structurally
impossible rather than merely discouraged. The prose around each sample explains
*why*; the sample itself is never retyped.

**D4 — the documentation build never launches a browser.** Doctests cover only
browser-free code. The temptation is real (live `@example` blocks producing real
screenshots), and it is refused: a doc build that needs Node, two browsers and
four web frameworks is slow, and every browser flake becomes a docs outage. The
browser evidence is the smoke and examples jobs, which are allowed to be slow and
are permitted to fail loudly. Docs stay fast, hermetic and deployable.

**D5 — docstring coverage is a gate, not an aspiration.** `makedocs` runs with
`checkdocs = :exports` and warnings as errors, so an exported name with no
docstring, or a docstring not placed in any `@docs` block, fails the build. This
pairs with the existing `test/test_exports.jl`, which pins the surface: together,
adding a public name requires both listing it there *and* documenting it here.
The public surface becomes impossible to grow by accident.

**D6 — the CI matrix is small on purpose.** Ubuntu only; Julia 1.10 (the declared
floor) and `1` (current release). No macOS, no Windows, no nightly.

This is the same rule M3's D6 applied to events: *do not advertise what you cannot
back*. The driver install path — Node fetch, browser download, `PLAYWRIGHT_BROWSERS_PATH`
— has only ever been run on Linux, and a green badge on a matrix that was never
thought through is a false promise. Nightly is excluded for a different reason: a
red build must always mean "we broke something".

Adding a platform is an *Ask first* boundary and a live Open Question, not a
closed door.

**D7 — browsers in CI are cached by path, not reinstalled.** `bin/install.jl`
honours `PLAYWRIGHT_BROWSERS_PATH` (M3, SC 10), which is exactly the hook
`actions/cache` needs; the cache key is the pinned `PLAYWRIGHT_VERSION`, so a
version bump invalidates it automatically and nothing else does. The smoke job
runs both engines in one job rather than a two-way matrix — they share a browser
cache and a driver install, and splitting them doubles the setup to parallelise
work that is not the bottleneck.

**D8 — WGLMakie is probe-gated.** It is the one example whose feasibility is
genuinely unknown: it renders through WebGL, and headless WebGL in a CI container
depends on a software rasteriser being present and on the engine cooperating.
Firefox headless is the more doubtful of the two.

So M5 opens with a probe, exactly as M4 did, and the probe's finding picks the
example's assertion level:

1. **Full** — the canvas renders and a screenshot has non-uniform pixel content:
   assert on the rendered output.
2. **Structural** — the page and Bonito wiring load but rendering is unreliable:
   assert on DOM and on the absence of page errors, and say so in the docs.
3. **Chromium-only** — the example runs on one engine and the docs state the
   limitation.

All three are acceptable outcomes. What is not acceptable is a flaky example
retried until it passes. **Dropping WGLMakie entirely is an *Ask first*
boundary** — it is the example that motivates M4's artifact family, so its
removal is a scope decision, not an implementation one.

**D9 — release-readiness means "Registrator would accept this", stopping short of
asking it.** Concretely: a `LICENSE` file (none exists today — the single largest
gap), compat bounds on every `[deps]` entry rather than the current partial set,
TagBot so a future tag produces a release, CompatHelper so bounds do not rot, and
Dependabot for the workflow actions. `version = "0.1.0"` is not bumped.

**D10 — docs deploy with the workflow's `GITHUB_TOKEN`, not a `DOCUMENTER_KEY`
deploy key.** Documenter supports both. `GITHUB_TOKEN` is issued to the workflow
run automatically, so there is **no secret to generate, store or rotate** — the
whole class of "who has the key" problems disappears, and the milestone loses its
one step that only the repo owner could perform. The job declares
`permissions: contents: write` and nothing more.

The one real trade-off: pushes made with `GITHUB_TOKEN` do not trigger further
workflow runs. That matters only if something is ever meant to fire *on* a
`gh-pages` push, which nothing here does — GitHub Pages serves the branch
directly. If that ever changes, this decision is what to revisit.

Note the current `[compat]` block already carries an oddity to resolve: it
bounds `HTTP` and `JSON`, but `HTTP` is a *test*-only dependency while `Base64`,
`Dates`, `Downloads` and `p7zip_jll` — all real dependencies — carry no bound at
all. Fixing that is part of C5.

## Success Criteria

1. `julia --project=docs docs/make.jl` builds the site with zero warnings, with
   `checkdocs = :exports` and warnings-as-errors both on.
2. Every name in `Playwright`'s export list appears in an `@docs` block and has a
   docstring whose first line is its signature. Deleting any one docstring makes
   SC 1 fail — verified by doing it once and restoring it.
3. Doctests pass, and at least one doctest exercises a browser-free path
   (serialisation, timeout resolution, or error construction).
4. The site has a working navigation tree: getting started, one guide page per
   API area listed in A4, four example pages, and an API reference.
5. `README.md` is under 150 lines, contains install + quick start + badges, and
   links to the site. No API reference material remains in it.
6. `julia --project=examples examples/http_jl.jl` exits 0 from a clean checkout,
   starting and stopping its own server, on Chromium and Firefox.
7. The same for `oxygen_jl.jl` and `genie_jl.jl`.
8. `wglmakie_jl.jl` exits 0 at whichever assertion level D8's probe selected, and
   the docs page states that level honestly if it is not "full".
9. Each of the four example pages shows source read from the executed file at
   build time (D3), verified by editing an example and rebuilding: the page
   changes with no edit to any `.md`.
10. CI on a pushed branch runs and passes: hermetic tests on Julia 1.10 and `1`,
    `gen/generate.jl --check`, and a formatting check.
11. The smoke job passes in CI on both engines, with the browser cache hit on a
    second run (verified by the run log, not assumed).
12. The examples job passes in CI, using `examples/Manifest.toml`.
13. The docs job deploys to `gh-pages` and the site is reachable at its
    GitHub Pages URL.
14. `LICENSE` exists; every `[deps]` entry has a `[compat]` bound; TagBot,
    CompatHelper and Dependabot workflows are present and valid.
15. Hermetic `Pkg.test()` still green with no Node and no browser;
    `gen/generate.jl --check` green; `format(".")` clean; `git diff` shows
    `Project.toml`'s `[deps]` unchanged.
16. Any API gap found while writing documentation is recorded in
    `tasks/m5-api-gaps.md` and *not* fixed (Assumption 2).

## Non-Goals

Carried forward and explicitly not built here: WebKit; network interception and
routing; the network events and `Request`/`Response` accessors; downloads, file
chooser and dialog handling; HAR recording; persistent contexts; a Julia trace
viewer; Android/Electron; an async API; callback-style event subscription;
codegen of the user-facing API.

New to this milestone: **submitting to General** (D9 — ready, not registered);
**versioned documentation** across milestones (Assumption 9); **macOS and Windows
CI** (D6); **any change to the exported API** (Assumption 2); a browser-driven
docs build (D4); tutorials or video content; benchmarks.

## Open Questions

All four are **resolved** (2026-08-05); recorded here for the record.

1. **Which licence?** *Resolved: MIT* — the Julia ecosystem default and the least
   friction. Apache-2.0's patent grant was the alternative considered.
2. **Should macOS or Windows join the CI matrix?** *Resolved: no, per D6.* The
   install path is unproven on both, and a green badge on an unexercised platform
   is a false promise. Adding one stays an *Ask first* boundary rather than a
   closed door — the argument for macOS ("unproven is a reason to test") is real,
   but Windows would mean finding and fixing driver-path bugs, which is scope
   this milestone does not carry.
3. **Does `docs/bonnie-parity.md` become a site page?** *Resolved: no.* It stays
   a repo document, history like `SPEC-M*.md` under Assumption 9.
4. **Is a `Pkg.test()`-visible example smoke wanted?** *Resolved: no.* The
   examples stay entirely out of the package's test target (Testing Strategy);
   dependency weight is the deciding factor. The examples job in CI is what
   catches breakage.
