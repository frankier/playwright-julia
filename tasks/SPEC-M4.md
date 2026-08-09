# Spec: Playwright.jl — Milestone 4 (artifacts and the failure path)

Successor to [`SPEC.md`](SPEC.md) (M1), [`SPEC-M2.md`](SPEC-M2.md) (M2) and
[`SPEC-M3.md`](SPEC-M3.md) (M3), all three complete. Tech stack, driver
architecture, the codegen/API split, code style and boundaries carry over
unchanged unless contradicted here.

## Assumptions

Calls this spec makes without being told. Correct any that are wrong.

1. **New spec, not a rewrite.** `SPEC.md`, `SPEC-M2.md` and `SPEC-M3.md` stay as
   the record of milestones 1–3; this is `SPEC-M4.md`.
2. **Layering is unchanged.** Codegen emits the channel layer into
   `src/generated/channels.jl`; everything user-facing stays hand-written in
   `src/api/`. No new runtime dependencies — in particular, trace zips are built
   by the driver's own `localUtils.zip`, not by a Julia zip library (see D1).
3. **Playwright stays pinned at 1.61.1.** `PLAYWRIGHT_VERSION` in `src/driver.jl`
   remains the single source of truth and selects the protocol spec.
4. **Sync-only.** No async API, no callbacks on the reader task. Unchanged from
   M3's assumption 4 and for the same world-age reason.
5. **Acceptance is general upstream parity, not Bonnie parity.** Items 1–6 in
   part B below were raised by the Bonnie.jl port, but every success criterion is
   phrased against `playwright-python` semantics and this repo's own fixtures.
   Bonnie is not a dependency and not a test gate.
6. **Julia floor stays 1.10.** Nothing here needs newer.
7. **Artifacts are local.** The driver runs as a child process on the same
   machine, so a path handed to `saveAs` is a path this process can then read.
   Remote-driver (`connect`) setups are out of scope, as they have been since M1.

## Objective

M3 made a test suite fast and precise. **M4 is about the moment it fails.**

When a browser test goes red in CI, the assertion message is rarely enough. What
is needed is evidence: what the page looked like, what the console said, what the
browser was actually doing in the seconds before. Playwright's answer to that is
its artifact family — traces, video, screenshots — and Playwright.jl currently
exposes only `screenshot`. Everything else has to be hand-rolled, and the pieces
needed to hand-roll it (`retry_until`, the diagnostics getters) are themselves
awkward on exactly the teardown path where they get used.

**The user** is a Julia developer whose e2e suite just failed in CI and who has
nothing but a stack trace. After this milestone they have a trace zip they can
open in the upstream trace viewer, a video of the run, and a diagnostics dump —
without writing a `report_diagnostics` helper of their own.

### Part A — artifact capture

| # | Deliverable | Protocol |
|---|---|---|
| A1 | **Tracing** — `start_tracing`/`stop_tracing` on a `BrowserContext`, plus a `with_tracing` do-block that writes a zip on the way out | `Tracing` channel, already generated (`tracing: Tracing` on the context initializer, `protocol/spec/browserContext.yml:21`); `tracingStart`, `tracingStartChunk`, `tracingStopChunk`, `tracingStop` |
| A2 | **Video** — `record_video` on `new_context`, `video(page)`, `save_as`, `path` | `recordVideo` context option (`protocol/spec/mixins.yml:187`); `video: Artifact?` on the page initializer (`protocol/spec/page.yml:27`) |
| A3 | **PDF** — `pdf(page; path, …)` returning bytes, Chromium-only with a clear error elsewhere | `page.pdf` (`protocol/spec/page.yml:423`), returns `binary` |
| A4 | **`Artifact` surface** — `save_as`, `path`, `delete`, shared by A1–A2 | `artifact.yml`, all commands already generated as `_artifact_*` |

### Part B — the failure path

Six defects and gaps found by porting a real suite. Numbered as raised.

| # | Problem | M4 |
|---|---|---|
| B1 | `retry_until` raises `AssertionFailure` on timeout, so `@test retry_until(…)` reports an **Error**, not a Fail. A suite written as `@test <bool>` cannot use it. | A non-throwing mode (D5) |
| B2 | `retry_until` is outside the timeout cascade — everything else honours `set_default_timeout!`, it alone falls back to `DEFAULT_TIMEOUT` because "there is no page here to inherit a setting from" (`src/api/expect.jl:230-234`) | Optional target argument, opting into `resolve_timeout` (D5) |
| B3 | `retry_until` propagates predicate exceptions. Right for a DOM predicate, wrong for the common e2e shape where the predicate is an HTTP call against a server that is still warming up | `on_error = :throw \| :retry` (D5) |
| B4 | No screenshot-on-failure helper — every suite hand-rolls "page errors + console errors + a screenshot into an artifacts dir" | `with_page(f, browser, url; artifacts=…)` and `report_diagnostics` (D3) |
| B5 | `page_errors`, `console_messages` and `screenshot` are exactly what a `finally` block calls, and exactly when the page may already be gone. M3's `TargetClosedError` makes that teardown path throw and **mask the original failure** — and on an *already-disposed* page it is worse than a throw (see D4) | No-throw on a dead target (D4) |
| B6 | `expect` dispatches only on `Locator`, so there is no `to_have_url` / `to_have_title`; document-level assertions fall back to `retry_until` | `expect(::Page)` / `expect(::Frame)` (D2) |

B4 and B5 are the same bug seen from two sides, and A1–A2 are what B4's helper
should be able to collect. That is why one milestone.

### Target snippet

The thing that must work at the end, run verbatim as a test on both engines (as
M3's snippet is, in `test_parity.jl`):

```julia
using Playwright, Test

playwright() do pw
    browser = launch(pw, :chromium; headless = true)
    ctx = new_context(browser; record_video = (dir = "artifacts/video",))

    with_tracing(ctx; path = "artifacts/trace.zip", screenshots = true, snapshots = true) do
        page = new_page(ctx)
        set_default_timeout!(page, 2_000)
        goto(page, "file://" * abspath("test/fixtures/m4.html"))

        # B6: assertions about the document, not just about an element
        expect(page; to_have_title = "M4")
        expect(page; to_have_url = r"m4\.html$")

        # B1/B2/B3: reports a Fail, inherits the page's 2 s timeout,
        # retries through a predicate that throws while the server warms up
        @test retry_until(page; on_timeout = :false, on_error = :retry) do
            HTTP.get(probe_url).status == 200
        end

        # A3
        bytes = pdf(page; path = "artifacts/page.pdf", format = "A4")
        @test !isempty(bytes)

        close(page)
        # A2: the video only exists once the page is closed
        @test isfile(path(video(page)))
    end

    # B5: teardown after the context is gone must not throw
    close(ctx)
    @test isempty(page_errors(page))

    @test isfile("artifacts/trace.zip")
    close(browser)
end
```

## Tech Stack

Unchanged from M1: pure Julia ≥ 1.10, JSON.jl at runtime, YAML.jl in `gen/`
only, HTTP.jl test-only. Playwright driver 1.61.1, assembled from the
`playwright-core` npm tarball plus a nodejs.org binary.

## Commands

Unchanged from M3, plus one for inspecting what this milestone produces:

```
Instantiate:   julia --project=. -e 'using Pkg; Pkg.instantiate()'
Test:          julia --project=. -e 'using Pkg; Pkg.test()'
Smoke:         PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()'
Codegen:       julia --project=gen gen/generate.jl
Codegen check: julia --project=gen gen/generate.jl --check
Format:        julia --project=. -e 'using JuliaFormatter; format(".")'
Driver setup:  julia bin/install.jl
View a trace:  npx playwright@1.61.1 show-trace artifacts/trace.zip
```

`show-trace` is a **human** verification step only — never a test dependency.

## Project Structure

Additions only; everything else is as M3 left it.

```
src/api/artifacts.jl    → NEW. Artifact wrapper (save_as, path, delete),
                          video(page), tracing start/stop/with_tracing, pdf
src/api/fixtures.jl     → NEW. with_page, report_diagnostics
src/api/expect.jl       → CHANGED. expect(::Page)/expect(::Frame) matchers;
                          retry_until gains target, on_timeout, on_error
src/api/diagnostics.jl  → CHANGED. no-throw on a closed target
src/api/lifecycle.jl    → CHANGED. record_video on new_context, traces_dir
                          on launch
test/test_artifacts.jl  → NEW. Tracing/video/pdf, smoke; zip and path
                          assertions are hermetic where they can be
test/test_fixtures_api.jl → NEW. with_page / report_diagnostics, including
                          the failure path
test/fixtures/m4.html   → NEW. Target-snippet fixture
```

Note the name clash to avoid: `test/test_fixtures.jl` already exists and tests
the HTML fixtures. The new file is `test_fixtures_api.jl`.

## Code Style

Unchanged conventions: snake_case surface over camelCase wire names, verbs as
functions, `Base` overloads where the meaning matches, `!` on mutators,
do-block-first for anything that must set up before it acts.

New in this milestone: **a teardown-path function never throws.** If it cannot do
its job it says so and returns something usable, because it is running while a
more important error is already in flight.

```julia
"""
    with_tracing(f, ctx::BrowserContext; path, screenshots=true, snapshots=true, sources=false)

Record a Playwright trace around `f()` and write it to `path`.

The zip is written **however the block exits** — that is the point, since the
run worth tracing is the one that threw:

```julia
with_tracing(ctx; path = "artifacts/trace.zip") do
    goto(page, url)
    click(locator(page, "#submit"))
end
```

Open it with `npx playwright show-trace artifacts/trace.zip`.
"""
function with_tracing(f, ctx::BrowserContext; path::AbstractString, kw...)
    start_tracing(ctx; kw...)
    try
        return f()
    finally
        # Teardown: a failure to save the trace must not replace the caller's
        # exception with a less interesting one.
        try
            stop_tracing(ctx; path)
        catch e
            @warn "could not save trace" path exception = e
        end
    end
end
```

## Testing Strategy

Framework and gating unchanged: stdlib `Test`, hermetic unit tests always,
browser smoke tests behind `PLAYWRIGHT_JL_SMOKE=1`, every newly exported
function exercised by at least one smoke test.

- **Unit (no browser):**
  - `retry_until` in all four corners of `on_timeout × on_error`, against
    pure-Julia predicates — no browser needed for any of it. Includes: predicate
    that throws once then succeeds (`:retry` passes, `:throw` propagates), and
    that timeout under `:false` returns `false` **without** throwing.
  - Timeout resolution for `retry_until(f, target)` — same cascade table as M3's.
  - `report_diagnostics` against a mocked closed page: writes what it can,
    returns, does not throw.
  - `with_page` argument validation — `artifacts_on = :bogus`, and
    `artifacts_on` without `artifacts` — needs no browser to reject.
  - PDF option marshalling to wire params (`format`, `margin`, `landscape`),
    asserted on the recorded message, as `test_connection.jl` does for launch.
- **Smoke (real browser, Chromium *and* Firefox):**
  - Tracing round-trip: `with_tracing` produces a file, it is a valid zip
    (magic bytes `PK\x03\x04`), and it contains a `*.trace` entry. Reading the
    entry list is done with the driver's own zip, not a Julia unzip dependency —
    assert on size and magic bytes only.
  - Trace is written even when the block throws (the B4/B5 case).
  - Video: a context with `record_video` yields a non-empty `.webm` after
    `close(page)`, and `video(page)` on a context without recording is `nothing`.
  - PDF on Chromium succeeds; on Firefox raises a `DriverError` whose message
    names Chromium. **The Firefox leg asserting a clean failure is a required
    test, not an omission.**
  - `expect(page; to_have_title=…)` passes for a late-set title and raises
    `AssertionFailure` with the received value on a mismatch.
  - `with_page(…; artifacts=dir)` on a body that throws: the exception
    propagates *unchanged*, and the dir contains a screenshot, a console log and
    a page-error log. The passing body writes nothing under the default
    `artifacts_on = :failure`, and all three files under `:always` — both legs
    asserted, since "wrote nothing" is as much a behaviour as "wrote something".
- **The B5 regression test, specifically:** close the context, then call
  `page_errors`, `console_messages` and `report_diagnostics`. None throws. This
  is the test that would have caught the masked-failure bug.
- **Race regression carried from M3:** unchanged, must stay green.

## Boundaries

- **Always:** run the hermetic suite before commits; keep `gen/generate.jl
  --check` green; keep wire-protocol knowledge out of `src/api/`; keep timeout
  defaults in exactly one place; write artifacts only under a caller-supplied
  path, never a package-chosen one.
- **Ask first:** any new runtime dependency (a zip library in particular — see
  D1); changing `PLAYWRIGHT_VERSION`; breaking an M3 exported signature;
  registering the package.
- **Never:** run user closures on the transport reader task; commit driver,
  browser or artifact binaries (`artifacts/` goes in `.gitignore`); let a
  teardown-path function throw; poll in Julia where the driver offers a waiting
  command.

## Decisions

**D1 — tracing is finished by the driver, not by Julia.** `tracingStopChunk`
returns an `Artifact?` *and* an `entries` array, and upstream clients hand those
entries to `localUtils.zip` (`protocol/spec/localUtils.yml:51`) to assemble the
zip locally. Which of the two paths the 1.61.1 driver actually takes depends on
the mode and on whether `tracesDir` was set at launch, and the yml documents
neither. **This is probed before anything is built** — the same discipline M3's
T6 applied to `frame.expect`. If the artifact path works, `save_as` is the whole
implementation. If entries come back instead, `localUtils.zip` does the work.
Either way no Julia zip dependency is added; if the probe shows one would be
required, that is an *Ask first* boundary and the milestone stops for review.

*Probed and resolved (2026-08-04, `tasks/m4-probe.md`).* **The artifact path
works**, on Chromium and Firefox alike: `tracingStopChunk(mode = "archive")`
returns a real `Artifact` whose `save_as` writes a valid zip, so `save_as` is
the whole implementation and `localUtils.zip` is never called. No Julia zip
dependency is needed and the *Ask first* boundary is not reached. Two
consequences the spec had left open:

- **`tracesDir` at launch is not required.** Without it the driver uses its own
  temporary directory and archive mode still produces a valid zip; setting it
  only relocates that scratch directory. So `launch` gains no `traces_dir`
  option.
- **`sources` cannot be supported on this path.** Upstream embeds calling source
  files by passing `includeSources` to `localUtils.zip` — which it can do
  because it assembles the zip itself. 1.61.1's `tracingStart` carries no
  `sources` flag, so there is nowhere for the option in the Code Style example
  above to go. `start_tracing` accepts the keyword and **raises an
  `ArgumentError` if it is `true`**, rather than accepting it and silently
  doing nothing: a flag that quietly does nothing is worse than one that is not
  offered.

**D2 — page/frame assertions reuse `frame.expect`.** There is no separate
protocol command for document-level assertions; upstream sends `frame.expect`
with a root selector and expressions `to.have.title` / `to.have.url`. The exact
selector and expression strings are **probed** alongside D1, then added to the
existing closed `MATCHERS` table in `src/api/expect.jl:58`, which is where new
matchers belong. `expect(::Page)` delegates to `main_frame(page)`. Matchers stay
type-partitioned: passing `to_have_text` to a `Page` is an `ArgumentError` naming
the right target, not a confusing driver-side failure.

*Probed and resolved (2026-08-04).* The "root selector" is the **empty string**.
`":root"` and `"html"` both fail, and — as in M3 — they fail with exactly the
same generic `ExpectFailure` a real mismatch produces, which is what makes the
closed table load-bearing rather than merely tidy. The failure's `errorDetails`
carries the received value in the shape M3's `received_value` already decodes,
so no new error handling was needed. The matchers landed in a separate
`DOCUMENT_MATCHERS` table of the same shape rather than in `MATCHERS`, which is
what makes the type partition enforceable in both directions.

**D3 — the fixture is `with_page`, and it is honest about failure.**

```julia
with_page(f, browser_or_context, url = nothing;
          artifacts = nothing, artifacts_on = :failure, kw...)
```

Opens a page, optionally navigates, runs `f(page)`, always closes the page. When
`artifacts` is a directory path, `report_diagnostics(page, dir)` runs *before*
the page closes and writes a screenshot, `console.log` and `errors.log`.
**The original exception always propagates unchanged** — the helper's job is to
add evidence, never to replace or swallow the failure. A diagnostics failure is a
`@warn`, never an exception.

`artifacts_on` decides when the dump happens: `:failure` (default) only when `f`
throws, `:always` on every run. `:failure` is the default because a screenshot
per passing test is a lot of bytes for nothing on a large suite; `:always` exists
because a passing-but-wrong run is exactly when symmetric evidence helps, and a
caller who wants that should not have to reimplement the fixture to get it. Any
other value is an `ArgumentError` listing the two — the closed-set discipline
`MATCHERS` already uses (`src/api/expect.jl:58`), for the same reason: a typo'd
`:allways` must not silently mean "never".

Passing `artifacts_on` without `artifacts` is also an `ArgumentError`, since it
can only be a mistake about where the files were meant to go.

`report_diagnostics(page, dir)` is also public on its own, because a suite with
its own fixture shape should not have to adopt `with_page` to get the dump. It
returns the list of files it managed to write, so a caller can log paths.

**D4 — diagnostics are no-throw on a dead target.** `console_messages`,
`page_errors` and `report_diagnostics` return empty / partial results rather than
raising `TargetClosedError`. Rationale: these are postmortem readers called from
`finally` blocks; a throw there masks the real failure (B5), and "the page is
gone" is not new information to a caller who is already handling an error. The
silence is bounded — it applies *only* to `TargetClosedError`, only to these
functions. Any other error still propagates, so a genuine bug is not hidden.

`screenshot` is the awkward one: it returns `Vector{UInt8}`, so it has no natural
empty answer, and it is a real action rather than a buffer read. It keeps
throwing; `report_diagnostics` catches for it. See Open Question 2.

**Correction found while building this (2026-08-05): a dead target fails in two
ways, and B5 only described one.**

Catching `TargetClosedError` covers the *race* — the message went out to a live
page and the reply came back saying it had closed. That is what a real suite
hits, and it is what B5 reported.

But a page that was **already disposed** when the call started does not throw at
all. These readers do not hop through `main_frame`, so they inherit none of M3's
guard, and there is nobody left to answer the message they send: the call
**hangs indefinitely**. This is strictly worse than the bug B5 describes — a
masked failure is at least a failure, whereas a `finally` block that never
returns takes the whole suite with it. It was found by a hermetic test hanging
rather than failing.

So liveness is checked *before* the send, not only caught after it. Both halves
are asserted, including that the disposed case sends no message at all.

**D5 — `retry_until` grows three knobs and stays one function.**

```julia
retry_until(f; timeout=nothing, interval=100, on_timeout=:throw, on_error=:throw)
retry_until(f, target; …)          # opts into the resolve_timeout cascade
```

- `on_timeout = :throw` (default, unchanged) raises `AssertionFailure`;
  `:false` returns `false`, which is what stdlib `Test` needs to render a **Fail**
  rather than an Error (B1).
- `on_error = :throw` (default, unchanged) propagates a predicate exception;
  `:retry` treats it as "not yet", subject to the same deadline (B3). Under
  `:retry` the *last* exception is attached to the timeout failure, so a
  predicate that never stops throwing still reports why.
- `target` is a second positional (matching `expect_event(f, target, event)`),
  routing `timeout` through `resolve_timeout` (B2).

One function with defaulted keywords rather than four names: every default is the
M3 behaviour, so this is purely additive and no existing call changes meaning.

**Two corrections found while building this (2026-08-05).**

*`:false` is not a `Symbol`.* `false` is a boolean literal, so Julia parses
`:false` as `false::Bool`, while `:throw` and `:retry` really are symbols. The
keyword therefore takes `Union{Symbol,Bool}`, and `on_timeout = :false` and
`on_timeout = false` are the same thing. This spec's spelling is kept — it
lines up with the other values at the call site — but it is a spelling, not a
symbol, and the implementation accepts both.

*B1 overstated the damage.* stdlib `Test` records a throwing `@test` as a
`Test.Error` and **carries on to the next assertion**; it does not abort the
enclosing `@testset`. So the gain from `:false` is the report, not the
continuation — and it is still worth having, because an `Error` says "this test
is broken" while a `Fail` says "this assertion did not hold", which is the truth
about a condition that never arrived. A `Fail` also renders the expression and
its value instead of a stacktrace through package internals. SC 7 is worded
against the difference that is real.

**D6 — video is context-scoped and finalized on close.** `record_video` is a
`new_context` option, not a page one, because that is what the protocol offers.
`video(page)` returns an `Artifact` or `nothing`; `path(v)` **blocks** until the
file is finished, which only happens once the page (or context) closes. This is
an upstream sharp edge, not a Playwright.jl one, and the docstring says so
explicitly with the working order shown.

*Built as an `Artifact` rather than a distinct `Video` type (2026-08-05).* The
protocol hands back `video: Artifact?` and the three verbs a caller wants —
`path`, `save_as`, `delete` — are exactly the surface A4 already defines as
shared by A1 and A2. A `Video` wrapper would either duplicate all three or add a
type that only forwards them.

**D7 — PDF fails loudly off Chromium.** `page.pdf` is Chromium-only upstream.
Rather than let the driver's error surface raw, `pdf` checks `browser_name` (M3,
gap 6) and raises an `ArgumentError` naming the engine and the restriction.
Checked client-side because the answer is knowable without a round trip.

## Success Criteria

Each is a specific, testable condition.

1. `with_tracing` writes a file at the requested path whose first four bytes are
   `PK\x03\x04`, on Chromium and Firefox.
2. That is still true when the traced block throws, and the block's exception —
   not a tracing error — is what propagates.
3. `npx playwright show-trace` opens the produced zip and shows the recorded
   actions. Human-verified once, recorded in the milestone notes; not a test.
4. A context created with `record_video` yields, after `close(page)`, a
   non-empty file at `path(video(page))`; `video(page)` is `nothing` without it.
5. `pdf(page; path=…)` on Chromium returns non-empty bytes and writes them;
   on Firefox it raises an `ArgumentError` naming Chromium, and does so without
   a round trip to the driver.
6. `expect(page; to_have_title=…)` and `to_have_url` pass for a late-set value
   and, on mismatch, raise `AssertionFailure` carrying the received value.
   `expect(page; to_have_text=…)` is an `ArgumentError`, not a driver failure.
7. `@test retry_until(f; on_timeout = :false)` on a never-true predicate produces
   a `Test.Fail` and **not** a `Test.Error`, and the enclosing `@testset`
   continues to the next test — asserted with a recording testset, not by
   eyeball, and asserted against the M3 default (which gives the `Error`) in the
   same test. Fail-versus-Error is the real difference; see the correction under
   D5, since stdlib does not in fact abort the testset on an `Error`.
8. `retry_until(f, page)` honours `set_default_timeout!(page, ms)`: a
   never-true predicate returns/raises in ≈`ms`, asserted with `@elapsed`.
9. `on_error = :retry` passes for a predicate that throws twice then returns
   `true`; `on_error = :throw` propagates the first exception. A predicate that
   always throws, under `:retry`, times out with the last exception in the
   message.
10. After `close(ctx)`, each of `page_errors(page)`, `console_messages(page)` and
    `report_diagnostics(page, dir)` returns without throwing.
11. `with_page(…; artifacts=dir)` around a throwing body: the original exception
    propagates with its type and message intact, and `dir` contains a screenshot,
    a console log and an error log. Around a *passing* body `dir` stays empty;
    with `artifacts_on = :always` the same three files appear. `artifacts_on =
    :bogus`, and `artifacts_on` passed without `artifacts`, are both
    `ArgumentError`.
12. Hermetic `Pkg.test()` green with no Node and no browser;
    `gen/generate.jl --check` green; `format(".")` clean.
13. The target snippet above runs as a test on Chromium and Firefox — verbatim
    on Chromium, and on Firefox with only the `pdf` call changed.

    **This criterion contradicted SC 5 as originally written (corrected
    2026-08-05).** The snippet calls `pdf`, and SC 5 requires `pdf` to *raise*
    on Firefox, so "verbatim on both engines" cannot hold. Rather than drop the
    Firefox leg or drop `pdf` from the milestone's showcase, Firefox runs the
    identical snippet with the two `pdf` lines replaced by an assertion that it
    refuses; every other line is shared.

    Three further substitutions are the same licence M3's snippet was given for
    `url`: `probe_url` is this spec's own placeholder, the `file://` fixture
    path is resolved against the test directory, and `page` is declared before
    the `with_tracing` block — the snippet assigns it inside the do-block and
    reads it after, which, a do-block being a closure, is an `UndefVarError`
    rather than a claim about the library.

## Non-Goals

Deferred again, explicitly not built here: WebKit; network interception and
routing (`route`/`fulfill`/`abort`); downloads, file chooser and dialog handling
— wrapper types *and* events; HAR recording and replay (`harStart`/`harExport`
exist in the protocol and stay unused); persistent contexts; a Julia trace
*viewer* or any trace parsing — the zip is an opaque artifact for upstream's
viewer; `browser.startTracing`/`stopTracing` (the Chromium-only DevTools tracing,
distinct from the `Tracing` channel this milestone wraps); Android/Electron; an
async API; callback-style event subscription; codegen of the user-facing API.

## Open Questions

All three are **resolved** (2026-08-04); recorded here for the record.

1. **Non-throwing spelling.** *Resolved: the keyword* — `on_timeout = :false` on
   the existing `retry_until`, as D5 describes. The alternative considered was a
   separate exported predicate (`settles(f)`), rejected to avoid a second name
   for one concept. (Note the D5 correction: `:false` is the boolean `false`,
   not a `Symbol`. The spelling survives; the type does not.)
2. **Does `screenshot` need a closed-target mode?** *Resolved: no* — it keeps
   throwing, and `report_diagnostics` catches for it (D4). A `Union{Vector{UInt8},
   Nothing}` return that every caller must handle is not worth it until a real
   call site asks. Revisit only with such a call site in hand.
3. **Should `with_page` capture artifacts on success too?** *Resolved: build
   `artifacts_on = :failure | :always` now, defaulting to `:failure`.* Not
   deferred — shipping the knob immediately costs one branch and means no caller
   has to re-litigate it later. See D3.
