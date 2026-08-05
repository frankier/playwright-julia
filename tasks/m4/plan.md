# Implementation Plan: Playwright.jl — Milestone 4 (artifacts and the failure path)

Spec: [`SPEC-M4.md`](../SPEC-M4.md). Earlier plans are archived at
[`tasks/m1/plan.md`](m1/plan.md), [`tasks/m2/plan.md`](m2/plan.md) and
[`tasks/m3/plan.md`](m3/plan.md).

## Context

M3 made a test suite fast and precise. M4 is about the moment it fails: trace
zips, video and PDF on the artifact side, and six fixes on the path a suite takes
when something has already gone wrong.

The two halves have very different risk profiles, and that shapes everything
below.

**Part B is almost entirely hermetic.** `retry_until`'s three knobs, the
no-throw diagnostics, and `with_page`'s argument validation need no browser at
all — they are pure Julia control flow. That is unusual for this repo and worth
exploiting: Part B can land first, fast, with the full M3 smoke suite as the
oracle that nothing regressed, while Part A waits on a probe.

**Part A is blocked on two undocumented protocol shapes.** `tracingStopChunk`
returns `artifact: Artifact?` *and* an `entries` array and the yml says nothing
about which arrives when (D1); `frame.expect`'s document-level selector and
expression strings are equally undocumented (D2). M3 learned this lesson twice —
T6's `frame.expect` probe and T8's launch-option probe both changed the design
that followed them. So M4 opens with a probe task whose output is a findings
document, and **that probe can veto the milestone**: if trace assembly turns out
to require a Julia zip library, that is an *Ask first* boundary (`SPEC-M4.md`
Boundaries) and work stops for review rather than quietly adding a dependency.

## Architecture Decisions

Recorded as D1–D7 in `SPEC-M4.md`. The ones that drive this plan:

- **D1 — tracing is finished by the driver.** Probe first (T1); the result picks
  between two implementations of the same public API, and no Julia zip
  dependency is added either way.
- **D2 — page/frame assertions reuse `frame.expect`** via the existing closed
  `MATCHERS` table, so B6 is an entry in a table plus a dispatch method, not a
  new subsystem. Also probe-gated.
- **D3 — `with_page` adds evidence, never replaces the failure.** The original
  exception propagates unchanged; a diagnostics failure is a `@warn`.
  `artifacts_on = :failure | :always` ships now (resolved open question 3).
- **D4 — diagnostics are no-throw on a dead target**, bounded to
  `TargetClosedError` and to the postmortem readers only.
- **D5 — `retry_until` grows three knobs and stays one function**, every default
  being the M3 behaviour. Purely additive: no existing call changes meaning.
- **D7 — PDF fails loudly off Chromium**, checked client-side via `browser_name`,
  so no round trip.

## Dependency Graph

```
T0 fixture (m4.html) + artifacts/ ignored          [hermetic, no deps]

T1 PROBE — tracing stop path (D1) + expect strings (D2)   ← gate: may veto A1
 ├── T4 Artifact wrapper (save_as, path, delete)      [A4]
 │    ├── T5 tracing: start/stop/with_tracing         [A1]
 │    └── T6 video: record_video, video(page)         [A2]
 └── T8 expect(::Page) / expect(::Frame)              [B6]

T2 retry_until: target, on_timeout, on_error   [B1-B3]  ─ hermetic, no deps
T3 diagnostics no-throw on a dead target       [B5]     ─ hermetic, no deps
 └── T9 with_page + report_diagnostics + artifacts_on [B4]
T7 pdf(page; …)                                [A3]     ─ no deps

T10 docs, target snippet as a test, README, format  ← depends on T2–T9
```

Critical path: **T1 → T4 → T5 → T10.** Everything else has slack.

Parallelizable: **T2 ∥ T3 ∥ T7** are disjoint at the start (`expect.jl` /
`diagnostics.jl` / `artifacts.jl`), and all three are independent of the probe —
so a browser-free session can pick up T2 and T3 immediately, before T1 has run.

Two serialisation constraints that are *not* visible in the graph:

- **T4, T5, T6, T7 all write `src/api/artifacts.jl`.** They are logically
  independent but share one new file, so they land one at a time. T7 (pdf) is
  the smallest and can go first to establish the file.
- **T2 and T8 both write `src/api/expect.jl`.** T2 touches `retry_until` at the
  bottom of the file, T8 the `MATCHERS` table at the top, so the conflict is mild
  — but sequence them anyway rather than merging by hand.

## Risks and Mitigations

| Risk | Impact | Mitigation |
|---|---|---|
| **Trace assembly needs a client-side zip** — `localUtils.zip` may not cover the local case, and a Julia zip dependency is an *Ask first* boundary | High — could veto A1 | T1 probes before any code is written; a negative result stops the milestone for review rather than being worked around. This is why T1 is first |
| **`frame.expect`'s document-level selector/expression strings are undocumented** — a wrong expression fails with the *same* generic "Expect failed" as a real mismatch (learned in M3, `src/api/expect.jl:55-57`) | Med | Same probe (T1); the strings are recorded in the findings doc before T8 starts, and the closed `MATCHERS` table means a typo is an `ArgumentError`, not a mystery failure |
| **Video timing is an upstream sharp edge** — the file does not exist until the page or context closes, so a naive test asserts on a missing file and looks like our bug | Med | D6 makes the ordering explicit in the docstring; the smoke test closes the page *first* and asserts on `path(video(page))`, which blocks by design |
| **Firefox diverges** on video and rejects PDF outright | Med | Both legs are required tests, not omissions: the Firefox PDF test asserts a *clean* `ArgumentError` naming Chromium (SC 5). Divergence is documented, never papered over |
| **D4's silence hides a real bug** — swallowing `TargetClosedError` is deliberate, and deliberate silence is how masked failures start | Med | Bounded twice over: only that error type, only the postmortem readers. Any other error still propagates, asserted in T3's tests |
| **Teardown code that throws** re-creates B5 in new clothes — `with_tracing`'s `finally`, `report_diagnostics`' writes | High — masks the caller's real failure | Elevated to a code-style rule in `SPEC-M4.md` ("a teardown-path function never throws") and asserted directly: T5 and T9 each have a test where the *body* throws and the body's exception is what propagates |
| **Artifacts leak into git** — traces, videos and PDFs are binaries written during tests | Low | T0 adds `artifacts/` to `.gitignore` before anything can write one; `*.png` is already ignored |
| **`test_fixtures.jl` name clash** — it exists and tests HTML fixtures; the new fixture-API tests are a different thing | Low | Named `test_fixtures_api.jl`, called out in `SPEC-M4.md` Project Structure |
| **Four tasks share one new file** (`artifacts.jl`) | Low | Sequenced explicitly above; T7 lands first to establish the file |

## Verification Checkpoints

- **Checkpoint A** — after T0–T3: hermetic `Pkg.test()` green with no Node and no
  browser; M3 smoke suite still green (nothing regressed under the `retry_until`
  and diagnostics changes); `gen/generate.jl --check` green. **Human review of
  the T1 probe findings before any of Part A is built** — this is the gate that
  decides whether A1 is buildable as specced.
- **Checkpoint B** — after T4–T9: every slice's smoke tests green on Chromium
  *and* Firefox; hermetic suite still green; a trace zip opened once by hand with
  `npx playwright show-trace` (SC 3, the one criterion that cannot be automated).
- **Checkpoint C** — after T10: all thirteen `SPEC-M4.md` success criteria
  verified; the target snippet runs verbatim on both engines.

## Tasks

### T0 — Fixture and ignore rules (S) — no deps

- **Description:** The ground the rest of the milestone stands on: one fixture
  page for the target snippet, and an ignore rule so no test can commit a binary.
- **Acceptance:** `test/fixtures/m4.html` has a `<title>M4</title>`, a late-set
  title (for T8's "passes for a late value" test), console output and a
  deliberate uncaught error (for T9's diagnostics dump), and enough visible
  content to make a screenshot and a PDF non-trivial. `artifacts/` is in
  `.gitignore`.
- **Verify:** fixture loads via the existing HTTP.jl test server; `git status` is
  clean after a smoke run that writes artifacts.
- **Files:** `test/fixtures/m4.html`, `.gitignore`.

### T1 — PROBE: tracing stop path and document-expect strings (M) — gate

- **Description:** Find out what the live 1.61.1 driver actually does, before any
  API is designed around a guess. Two unknowns, one live-driver session.
- **Acceptance:** `tasks/m4-probe.md` records, with the raw replies:
  1. Whether `tracingStopChunk` returns a usable `Artifact` in local mode, or an
     `entries` array requiring `localUtils.zip` — and whether `tracesDir` must be
     set at launch (`protocol/spec/mixins.yml:92`) for either to work.
  2. The selector and expression strings `frame.expect` wants for
     `to.have.title` and `to.have.url`, confirmed by a passing *and* a failing
     call, with the failure's `errorDetails` shape recorded (M3 found the
     received value lives there and nowhere else structured).
- **Verify:** findings reproduced by a second run of the probe script; **human
  review before T4/T5/T8 start.** If neither path assembles a zip without a new
  Julia dependency, **stop and escalate** — do not add one.
- **Files:** probe script under the `@pw-probe` shared env (not committed to
  `src/`), `tasks/m4-probe.md`.

### T2 — `retry_until` gains target, `on_timeout`, `on_error` (M) — B1–B3, D5

- **Description:** Three knobs on one function, every default being the M3
  behaviour, so no existing call changes meaning.
- **Acceptance:** `retry_until(f; timeout, interval, on_timeout=:throw,
  on_error=:throw)` plus the `retry_until(f, target; …)` positional form.
  `on_timeout=:false` returns `false` instead of raising; `on_error=:retry`
  treats a predicate exception as "not yet" and attaches the *last* exception to
  the eventual timeout failure. Invalid symbol values raise `ArgumentError`
  listing the valid ones. The `target` form routes through `resolve_timeout`.
- **Verify:** hermetic tests over all four `on_timeout × on_error` corners;
  predicate that throws twice then succeeds; predicate that always throws under
  `:retry` (times out, last exception in the message); `@elapsed` assertion that
  `retry_until(f, page)` honours `set_default_timeout!` (SC 8); and a
  **recording testset** proving `@test retry_until(f; on_timeout=:false)` yields
  a `Test.Fail` and the testset *continues* (SC 7) — asserted, not eyeballed.
- **Files:** `src/api/expect.jl`, `src/Playwright.jl`, `test/test_expect.jl`.

### T3 — Diagnostics are no-throw on a dead target (S) — B5, D4

- **Description:** The masked-failure fix. These readers run in `finally` blocks,
  exactly when the page may be gone.
- **Acceptance:** `console_messages` and `page_errors` return an empty vector
  when the target is closed, instead of raising `TargetClosedError`. Bounded:
  **only** `TargetClosedError` is swallowed — every other error still propagates.
  Docstrings state the behaviour and why. `screenshot` is unchanged and still
  throws (resolved open question 2).
- **Verify:** hermetic tests with a mocked closed target for both the swallowed
  and the propagated case; smoke test closes the context then calls both (SC 10).
- **Files:** `src/api/diagnostics.jl`, `test/test_errors.jl` or
  `test/test_diagnostics.jl`.

### T4 — `Artifact` wrapper: `save_as`, `path`, `delete` (S) — A4, deps: T1

- **Description:** The shared surface under tracing and video. The generated
  `_artifact_*` calls already exist (`src/generated/channels.jl:723-767`); this
  is the hand-written layer over them.
- **Acceptance:** `save_as(a, path)`, `path(a)` (blocking, via
  `pathAfterFinished`) and `delete(a)` on the generated `Artifact`, following the
  probe's findings. Wire knowledge stays out of the API layer.
- **Verify:** unit tests on recorded messages; real exercise comes via T5/T6.
- **Files:** `src/api/artifacts.jl`, `src/Playwright.jl`, `test/test_artifacts.jl`.

### T5 — Tracing: `start_tracing`, `stop_tracing`, `with_tracing` (M) — A1, deps: T1, T4

- **Description:** The milestone's headline artifact. Implementation follows
  whichever path T1 found.
- **Acceptance:** `start_tracing(ctx; screenshots, snapshots, sources, name,
  title)`, `stop_tracing(ctx; path)`, and the `with_tracing(f, ctx; path, …)`
  do-block that writes the zip **however the block exits**. A tracing failure
  during teardown is a `@warn`, never an exception.
- **Verify:** smoke on both engines — file exists, first four bytes are
  `PK\x03\x04` (SC 1); the same holds when the block throws **and the block's
  exception is what propagates** (SC 2); `npx playwright show-trace` opens it,
  human-verified once and recorded (SC 3).
- **Files:** `src/api/artifacts.jl`, `src/api/lifecycle.jl` (`traces_dir` on
  `launch`, if T1 says it is required), `src/Playwright.jl`,
  `test/test_artifacts.jl`.

### T6 — Video: `record_video`, `video(page)` (M) — A2, deps: T4

- **Description:** Context-scoped recording, with the upstream timing sharp edge
  documented rather than hidden.
- **Acceptance:** `record_video = (dir=…, size=…)` on `new_context`; `video(page)`
  returns a `Video` or `nothing`; `path(v)` blocks until the file is finished.
  The docstring states plainly that the file only exists after the page or
  context closes, and shows the working order.
- **Verify:** hermetic test that `record_video` marshals to the right wire params;
  smoke on both engines — non-empty file after `close(page)`, and `nothing`
  without recording (SC 4).
- **Files:** `src/api/artifacts.jl`, `src/api/lifecycle.jl`, `src/Playwright.jl`,
  `test/test_artifacts.jl`.

### T7 — `pdf(page; path, …)` (S) — A3, D7, no deps

- **Description:** Smallest artifact, and the one that establishes
  `src/api/artifacts.jl` for T4–T6.
- **Acceptance:** `pdf(page; path=nothing, format, landscape, margin,
  print_background, …)` returns `Vector{UInt8}` and writes to `path` when given —
  the same shape as `screenshot` (`src/api/navigation.jl:42`). Off Chromium it
  raises an `ArgumentError` naming the engine and the restriction, decided
  **client-side** via `browser_name`, with no round trip.
- **Verify:** hermetic test on marshalled wire params (`format`, `margin`,
  `landscape`); smoke — non-empty bytes written on Chromium, `ArgumentError` on
  Firefox (SC 5).
- **Files:** `src/api/artifacts.jl`, `src/Playwright.jl`, `test/test_artifacts.jl`.

### T8 — `expect(::Page)` / `expect(::Frame)` (M) — B6, D2, deps: T1

- **Description:** Document-level assertions, as table entries rather than a new
  subsystem.
- **Acceptance:** `to_have_title` and `to_have_url` added to the closed `MATCHERS`
  table using T1's probed strings; `expect(::Page)` delegates to
  `main_frame(page)`. Matchers stay type-partitioned — `to_have_text` on a `Page`
  is an `ArgumentError` naming the right target, not a driver failure. `Regex`
  expectations work, as they already do for locators.
- **Verify:** smoke on both engines — passes for a late-set title, and on
  mismatch raises `AssertionFailure` carrying the received value; the
  wrong-matcher `ArgumentError` is hermetic (SC 6).
- **Files:** `src/api/expect.jl`, `src/Playwright.jl`, `test/test_expect.jl`.

### T9 — `with_page` and `report_diagnostics` (M) — B4, D3, deps: T3

- **Description:** The fixture that deletes every suite's hand-rolled
  `report_diagnostics`.
- **Acceptance:** `report_diagnostics(page, dir)` writes a screenshot,
  `console.log` and `errors.log`, returns the list of files it managed to write,
  and never throws — a failure is a `@warn`. `with_page(f, browser_or_context,
  url=nothing; artifacts=nothing, artifacts_on=:failure, kw...)` opens a page,
  optionally navigates, always closes it, and dumps diagnostics *before* closing.
  **The body's exception always propagates unchanged.** `artifacts_on=:always`
  dumps on success too; an invalid value, or `artifacts_on` without `artifacts`,
  is an `ArgumentError`.
- **Verify:** smoke — throwing body propagates with type and message intact and
  writes all three files; passing body writes **nothing** under the default and
  all three under `:always` (SC 11, both legs). Argument validation is hermetic.
- **Files:** `src/api/fixtures.jl`, `src/Playwright.jl`,
  `test/test_fixtures_api.jl`.

### T10 — Docs, target snippet, format (M) — deps: T2–T9

- **Description:** Prove the milestone against its own spec.
- **Acceptance:** the `SPEC-M4.md` target snippet runs verbatim as a test on both
  engines (SC 13); README gains an artifacts/failure-path section including the
  `show-trace` command; every newly exported function has a docstring; the M3
  smoke suite is still green.
- **Verify:** `format(".")` clean; `gen/generate.jl --check` green; hermetic
  `Pkg.test()` green with no Node and no browser (SC 12); all thirteen success
  criteria walked and recorded in a table in `todo.md`, as M3 did.
- **Files:** `README.md`, `test/test_parity.jl`, docstrings across `src/api/`.
