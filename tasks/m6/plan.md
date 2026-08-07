# Implementation Plan: Playwright.jl — Milestone 6 (a Julia-shaped API, and the network)

Spec: [`SPEC-M6.md`](../SPEC-M6.md). Earlier plans are archived at
[`tasks/m1/plan.md`](m1/plan.md), [`tasks/m2/plan.md`](m2/plan.md),
[`tasks/m3/plan.md`](m3/plan.md), [`tasks/m4/plan.md`](m4/plan.md) and
[`tasks/m5/plan.md`](m5/plan.md).

## Context

M6 is two milestones wearing one spec, and they could not be less alike.

**Part A is a rename with no thinking left in it.** Every decision was made in
`SPEC-M6.md` D1–D4; what remains is twelve mechanical substitutions across
`src`, `test`, `docs`, `examples` and `README.md`. The only interesting thing
about it is discipline: one name per commit, green between each, so that a
breakage is attributed to the rename that caused it rather than to "the rename".
It is planned as five tasks, four of which are batches of substitutions and one
of which is the regression test that stops the whole thing being a mistake.

**Part B is the largest hand-written API surface since M2**, and unlike Part A
almost every task in it has a way to be subtly wrong that tests will not catch
unless the test is written to catch that specific thing. Three areas carry real
risk — the dispatcher's lifetime (R1), the glob dialect (R2), and
`APIResponse` disposal (R4) — and each gets a task shaped around proving the
risk did not happen rather than around adding the feature.

**The critical path runs through the dispatcher, and it is short but deep.**
`globs.jl` → `network.jl` (Request/Response) → `routing.jl` (the dispatcher) →
everything else. Nothing in Part B can be demonstrated end to end until the
dispatcher works, which is why T10 is the milestone's gate and why T8 and T9
exist to make T10 small.

**Two things make this milestone cheaper than M2–M4 were.** No probe task is
needed: `SPEC-M6.md` Assumption 5 was verified against the vendored spec while
the spec was written, and every command Part B needs is already generated. And
no new dependency, no `Project.toml` change, so the whole of Part B is additive
to a package whose CI is already green.

**The one thing that makes it more expensive** is that routing failures hang
rather than fail. A test that hangs in CI costs ten minutes and produces no
diagnostic. Every routing test therefore carries an explicit timeout, and D6's
"always settle" rule is tested directly (T11) rather than assumed to hold.

## Architecture Decisions

Recorded as D1–D16 in `SPEC-M6.md`. The ones that drive this plan:

- **D1–D3 — the bang convention and its `Base` collisions.** D3 is why T1 exists
  as its own task and why T5 is a test rather than a checklist item: `fill!` and
  `delete!` would have broken `Base` for every user, and only a test keeps that
  from coming back.
- **D5 — one dispatcher task per routed owner, handlers sequential.** The
  central decision. Drives T10's shape and R1.
- **D6/D7 — every route is settled, every handler exception is re-thrown at
  release.** These are the two properties T11 exists to prove; they are also the
  two most likely to regress silently.
- **D9 — matchers are client-side, the driver gets the union.** Makes T8
  (`globs.jl`) a pure, hermetic, table-driven task that can be done first and
  reviewed on its own.
- **D11 — network events live on the context; `Page` forms filter.** T12's whole
  content, and the reason T12 is not simply "delete four entries from
  `DEFERRED_EVENTS`".
- **D12/D14 — `APIRequestContext` as far as fulfil-from-upstream, spelled
  `Playwright.fetch`.** T13, gated behind T10 because it is useless without a
  route to fulfil.
- **D16 — the mocked backend goes in the existing Oxygen example**, so no CI
  time is added and T16 is small.

## Dependency Graph

```
PART A — must complete entirely before Part B begins (SC A2, Resolved item 1)

T1 set_value! / delete_file! / close!  [D3 — the three collision renames]
T2 goto! / click! / dispatch_event!    [the plain action renames]
T3 dispose! / save_as! / start_tracing! / stop_tracing!
T4 clear_console_messages! / clear_page_errors!
     └── T5 no-shadow regression test + old-name grep   [SC A4, A6]

     ══════════ Checkpoint A: Part A complete and green ══════════

PART B

T8 globs.jl — glob→Regex, matcher union    [hermetic, no deps]  ← start here
T9 network.jl — Request/Response, headers, bodies  [no deps]
     │  T8 ∥ T9 — genuinely disjoint, no shared code
     ▼
T10 routing.jl — Route, registry, dispatcher task   ← THE GATE
     ├── T11 the three settle-guarantee tests   [D6, D7 — R1]
     ├── T12 the four network events + page filtering  [D11]
     ├── T13 apirequest.jl — Playwright.fetch, fulfil-from-upstream  [D12]
     └── T14 with_route, unroute!, unroute_all! ergonomics

     ══════════ Checkpoint B: routing works end to end ══════════

T15 docs: guide/network.md, events.md, api.md      [deps: T8–T14]
T16 examples/oxygen_jl.jl mocked-backend section    [deps: T10, T13]
T17 README status, bonnie-parity re-score           [deps: T15]
T18 final verification of all 27 criteria           [deps: everything]

     ══════════ Checkpoint C: milestone complete ══════════
```

T8 ∥ T9 is the only real parallelism in Part B. Everything after T10 is
parallel in principle but sequential in practice, since it all edits code T10
introduced.

## Risks and Mitigations

**R1 — the dispatcher task leaks, or dies, or deadlocks.** The highest-severity
risk in the milestone, because all three failure modes present identically to a
user: requests hang and a `goto!` times out 30 seconds later with no clue.
- *Mitigation:* T10 writes the task's lifetime before its behaviour — spawn on
  first registration, stop on last, survive a handler that throws (D7), survive
  an owner that closes mid-route. T11 tests each of those four directly, with
  explicit timeouts so a hang fails fast instead of blocking CI.
- *Tripwire:* if T11 needs a `sleep` to pass, the lifetime is wrong. Fix the
  lifetime, not the test.

**R2 — the glob dialect is subtly wrong.** `*` not crossing `/` while `**` does
is the kind of rule that passes six hand-written tests and fails on the seventh
real URL.
- *Mitigation:* T8 is table-driven and the table is shared with the guide page
  (SC 17), so a case that is documented but untested cannot exist. Cases are
  taken from Playwright's own `globToRegex` behaviour, not invented.

**R3 — a routing test hangs in CI.** Costs ten minutes and yields nothing.
- *Mitigation:* every smoke test in T11–T14 wraps its body in an explicit
  timeout. A hang becomes a failure with a message inside one minute.

**R4 — `APIResponse` leaks driver-side buffers.** An unfetched `fetchUid` is
held by the driver until disposed, and nothing in the existing subscription
machinery covers it.
- *Mitigation:* T13 owns disposal on both paths — handler exit and finalization
  — and SC 15 asserts it rather than assuming it.

**R5 — Part A breaks something no test covers.** Twelve renames across five
directories; the suites are good but not total.
- *Mitigation:* T5's grep (SC A4) proves no old spelling survives anywhere, and
  the docs build plus both examples run at Checkpoint A, which together touch
  nearly every renamed name in a way the unit tests do not.

**R6 — scope creep from `tasks/m5-api-gaps.md`.** Part A puts every export under
the eye at once, and eight of the nine recorded gaps will look fixable while
passing.
- *Mitigation:* Assumption 4 and Boundaries make it "ask first". Anything
  noticed goes into `tasks/m6-api-gaps.md`, not into the diff.

## Verification Checkpoints

**Checkpoint A — Part A complete** (after T5, before any Part B code)
- All twelve renames applied; `names(Playwright)` has every new name, no old one
- Hermetic **and** smoke green after *each* rename commit, not just the last
- `using Playwright` shadows nothing in `Base` — T5's test (SC A6)
- Old-name grep across `src`, `test`, `docs`, `examples`, `README.md` is empty
- Docs build warning-free; both examples pass on both engines
- Diff reviewed commit by commit for signature or behaviour changes (SC A5)

**Checkpoint B — routing works end to end** (after T14)
- SC 1–8 all pass on Chromium and Firefox
- No test needs a `sleep` to pass (R1's tripwire)
- Dispatcher lifetime proved on all four paths (T11)
- `tasks/m6-api-gaps.md` exists, whatever it contains

**Checkpoint C — milestone complete** (after T18)
- All 5 Part A and 22 Part B criteria verified, each by running it, in a table
- Gates confirmed still on: `checkdocs = :exports`, `warnonly = false`,
  `doctest = true`, both engines in smoke and `runexamples.jl`
- Nothing in `tasks/m5-api-gaps.md` fixed beyond D3's incidental resolution

## Tasks

### T1 — The three collision renames (M) — D3, SC A3, A6, no deps

- **Description:** `fill` → `set_value!`, `delete` → `delete_file!`,
  `close` → `close!`. First because they are the only renames with any thinking
  in them: the first two stop extending `Base` and become real exports, and
  `close` stops being `Base.close`. Getting these wrong is the R5 failure mode.
- **Acceptance:** All three are exported and appear in `names(Playwright)`.
  Neither `Base.fill!` nor `Base.delete!` is extended anywhere. Every call site
  in `src`, `test`, `docs`, `examples` and `README.md` updated. Each docstring's
  first line names Playwright's own spelling (`fill`, `delete`) so a search for
  it lands here.
- **Verify:** Hermetic and smoke green. `checkdocs = :exports` now covers all
  three, proved by deleting one docstring and watching the docs build go red,
  then restoring it.
- **Files:** `src/api/locators.jl`, `src/api/artifacts.jl`,
  `src/api/lifecycle.jl`, `src/Playwright.jl`, and call sites throughout.

### T2 — The plain action renames (S) — D1, deps: T1

- **Description:** `goto!`, `click!`, `dispatch_event!`. Purely mechanical.
- **Acceptance:** One commit per name; repo-wide substitution, nothing else in
  the diff.
- **Verify:** Hermetic and smoke green **after each of the three commits**
  (SC A2).
- **Files:** `src/api/navigation.jl`, `src/api/locators.jl`, `src/Playwright.jl`,
  call sites throughout.

### T3 — The handle and artifact renames (S) — D1, deps: T2

- **Description:** `dispose!`, `save_as!`, `start_tracing!`, `stop_tracing!`.
- **Acceptance:** As T2. Note that `with_tracing` keeps no bang (D2) — it is
  scaffolding, and the banging belongs on the calls inside the block.
- **Verify:** Green after each commit; the tracing smoke tests specifically,
  since they exercise all four.
- **Files:** `src/api/evaluate.jl`, `src/api/artifacts.jl`, `src/Playwright.jl`.

### T4 — The buffer-clearing renames (S) — D1, deps: T3

- **Description:** `clear_console_messages!`, `clear_page_errors!`.
- **Acceptance:** As T2.
- **Verify:** Green after each commit.
- **Files:** `src/api/diagnostics.jl`, `src/Playwright.jl`.

### T5 — The no-shadow test and the old-name grep (S) — SC A4, A6, deps: T4

- **Description:** The task that makes Part A safe rather than merely done. Two
  tests: one proving `using Playwright` shadows nothing in `Base`, one proving
  no old spelling survives anywhere in the repo.
- **Acceptance:** A test does `using Playwright` and then calls `fill!`,
  `delete!`, `close`, `count` and `first` on ordinary Julia data (an array, a
  `Dict`, an `IOBuffer`), asserting each resolves to `Base` and returns what
  `Base` would. A second test greps `src`, `test`, `docs`, `examples` and
  `README.md` for each old spelling *as a call* (`\bgoto\(`, `\bclick\(`,
  `\bfill\(`, …) and asserts no match.
- **Verify:** Both tests pass. Then prove them: reintroduce `export fill!` in a
  scratch copy and watch the first go red; reintroduce one old call site and
  watch the second go red. Neither is trusted until it has failed once.
- **Files:** `test/test_exports.jl`, `test/runtests.jl`.

### T6 — Checkpoint A verification (S) — deps: T5

- **Description:** Not a code task. Run every Checkpoint A item and record the
  result. Part B does not start until this is clean (Resolved item 1).
- **Acceptance:** Every Checkpoint A bullet ticked with the command that proved
  it.
- **Verify:** Docs build warning-free; `runexamples.jl` 8/8 on a quiet machine;
  diff reviewed commit by commit against Assumption 3.
- **Files:** `tasks/todo.md` (the verification table).

### T7 — `tasks/m6-api-gaps.md` opened (S) — R6, no deps

- **Description:** Create the file with its preamble before Part B starts, so
  that anything noticed during the milestone has somewhere to go that is not the
  diff. M5's equivalent proved that a gap record nobody opened is a gap record
  nobody writes.
- **Acceptance:** File exists with the same framing as `tasks/m5-api-gaps.md`:
  what it is for, and that nothing in it is fixed by this milestone.
- **Verify:** It exists. It is allowed to be empty until it is not.
- **Files:** `tasks/m6-api-gaps.md`.

### T8 — `globs.jl`: the matcher union (M) — D9, SC 17, R2, no deps

- **Description:** Playwright's glob dialect as a pure function, plus the
  three-way matcher union. Entirely hermetic — no driver, no browser, no
  connection. First in Part B because it is the one piece that can be finished
  and reviewed in isolation.
- **Acceptance:** `glob_to_regex(::AbstractString) -> Regex` implementing `*`
  (does not cross `/`), `**` (does), `?` (one non-`/`), `{a,b}` alternation, and
  escaping of regex metacharacters in literal segments. A `matches(matcher, url)`
  dispatching over `AbstractString`, `Regex` and `Function`. Base-URL resolution
  for a scheme-less glob. The case table lives in one place and is read by both
  the test and the guide (SC 17).
- **Verify:** `test_globs.jl` passes hermetically. Every row of the shared table
  is exercised. Metacharacter cases (`a.b`, `x+y`, `q?`) confirm literal
  treatment.
- **Files:** `src/api/globs.jl`, `test/test_globs.jl`, `src/Playwright.jl`.

### T9 — `network.jl`: Request and Response (M) — D10, no deps

- **Description:** The accessors, read from initializers (D10). Independent of
  T8 — no shared code — so the two run in parallel.
- **Acceptance:** `Request`: `url`, `method`, `resource_type`,
  `is_navigation_request`, `frame`, `redirected_from`, `post_data` (bytes),
  `post_data_string`, `json`. `Response`: `url`, `status`, `status_text`, `ok`,
  `request`, `body`, `text`, `json`. Headers as the three functions of D10 —
  `headers`, `headers_array`, `raw_headers` — with lower-cased keys and
  `", "`-joined duplicates in the first. `RequestFailure` struct. Every one
  documented.
- **Verify:** `test_network.jl` covers header normalisation, duplicate joining,
  wire-order preservation and the three body forms against a fake connection, as
  `test_events.jl` does. No browser needed.
- **Files:** `src/api/network.jl`, `test/test_network.jl`, `src/Playwright.jl`.

### T10 — `routing.jl`: Route, registry and the dispatcher (L) — D5–D8, R1 — **GATE**

- **Description:** The milestone's centre. The `Route` wrapper with `abort!`,
  `continue!` and `fulfill!`; the per-owner registry that computes the driver
  pattern union (D9); and the dispatcher task with the lifetime R1 is about.
  Write the lifetime first, the behaviour second.
- **Acceptance:** `route!` / `unroute!` / `unroute_all!` on `Page` and
  `BrowserContext`. Dispatcher spawns on first registration, stops on last,
  runs handlers sequentially newest-first (D5), holds no lock across user code,
  survives a throwing handler (D7) and an owner closing mid-route. Driver
  pattern union re-sent on every registration change, `**/*` when any matcher is
  a `Regex` or `Function`. `fulfill!` per D15 with its mutual-exclusion
  `ArgumentError`s; `abort!` validating its error code client-side.
- **Verify:** SC 1, 2, 7, 8 on both engines. Hermetic tests for the pattern
  union and `fulfill!` parameter building against a fake connection. **No test
  may use `sleep` to pass** (R1's tripwire).
- **Files:** `src/api/routing.jl`, `test/test_network.jl`,
  `test/test_smoke_network.jl`, `test/fixtures/m6.html`, `src/Playwright.jl`.

### T11 — The settle-guarantee tests (M) — D6, D7, R1, R3, deps: T10

- **Description:** A separate task from T10 on purpose. These are the tests that
  prove the two properties most likely to regress silently, and they are worth
  writing deliberately rather than as a corner of the feature task.
- **Acceptance:** Four dispatcher-lifetime tests (spawn, stop, throwing handler,
  owner closes mid-route) and three settle tests (no matcher → continued
  silently; handler settles nothing → exactly one warning per registration, page
  still loads; handler throws → exception out of `with_route`, page still
  navigated). Every one wrapped in an explicit timeout (R3).
- **Verify:** SC 3, 4, 5 on both engines. Each test proved by breaking the thing
  it guards — remove the auto-`continue!` and watch the no-matcher test hang
  into its timeout rather than pass.
- **Files:** `test/test_smoke_network.jl`.

### T12 — The four network events (M) — D11, deps: T10

- **Description:** `:request`, `:response`, `:requestfinished`, `:requestfailed`
  leave `DEFERRED_EVENTS`, plus the page-scoped filtering that D11 describes and
  `expect_request` / `expect_response`.
- **Acceptance:** All four as opt-in `EventSpec`s on `BrowserContext`. The
  `Page` forms subscribe to the page's *context* with a built-in predicate
  filtering on the `page` param — with a comment saying so, since it is
  invisible at the call site. `expect_request` / `expect_response` take the T8
  matcher union. `docs/src/guide/events.md`'s table grows.
- **Verify:** SC 9, 10, 11, 12, 13 on both engines. SC 12 specifically with two
  pages open in one context.
- **Files:** `src/api/events.jl`, `src/api/network.jl`,
  `test/test_smoke_network.jl`, `test/test_events.jl`.

### T13 — `apirequest.jl`: fetch and fulfil-from-upstream (M) — D12, D14, R4, deps: T10

- **Description:** `APIResponse`, `Playwright.fetch`, and
  `fulfill!(; response = …)`. Gated behind T10 because it is untestable without
  a route to fulfil.
- **Acceptance:** `APIResponse` as a plain immutable struct (not a
  `ChannelOwner`) with `url`, `status`, `status_text`, `headers`, `fetch_uid`.
  `Playwright.fetch(ctx, url; …)` and `Playwright.fetch(route)`, unexported
  (D14). `body` / `text` / `json` via `fetchResponseBody`. `fulfill!` accepting
  `response`, with `status`, `headers` and `content_type` overriding it.
  Disposal on both paths (R4). `api.md` gets an explicit `Playwright.fetch`
  `@docs` block and `test_exports.jl` asserts it has a docstring (D14).
- **Verify:** SC 14, 15 on both engines. SC 15 asserts disposal happened rather
  than assuming it — check the driver was told, not that no error occurred.
- **Files:** `src/api/apirequest.jl`, `src/api/routing.jl`,
  `test/test_smoke_network.jl`, `test/test_exports.jl`, `src/Playwright.jl`.

### T14 — `with_route` and ergonomics (S) — D8, deps: T10

- **Description:** The block form, and the exception-collection semantics of D7
  that `unroute!` and `with_route` share.
- **Acceptance:** `with_route(body, target, matcher, handler)` — handler as
  argument, body as do-block (D8). Handler exceptions rethrown at release, one
  directly and several as a `CompositeException`. In-flight routes settled
  before `unroute!` returns. Idempotent.
- **Verify:** SC 6 (overlapping registrations, newest-first, unroute restores
  the older) on both engines. The `CompositeException` path tested with two
  throwing handlers.
- **Files:** `src/api/routing.jl`, `test/test_smoke_network.jl`.

### T15 — Documentation (L) — SC 17, 19, deps: T8–T14

- **Description:** The guide page, and the API reference entries. The largest
  Part B task after T10, and — per M5's experience — the one that finds the API
  gaps that go in T7's file.
- **Acceptance:** `docs/src/guide/network.md` covering routing, the matcher
  dialect (reading T8's shared table, SC 17), the four events, and
  fulfil-from-upstream. It states D5's sequential-handler cost and the
  no-deadline decision (Resolved item 6's subject) out loud. `api.md` gains
  every new name plus the explicit `Playwright.fetch` block. `events.md`'s table
  updated.
- **Verify:** SC 19 — `docs/make.jl` warning-free with `checkdocs = :exports`
  and `warnonly = false` still on, `doctest = true` passing. Glob examples
  doctested.
- **Files:** `docs/src/guide/network.md`, `docs/src/guide/events.md`,
  `docs/src/api.md`, `docs/make.jl`.

### T16 — The Oxygen example gains a mocked backend (S) — D16, SC 21, deps: T10, T13

- **Description:** A second section in the existing example rather than a fifth
  script, so CI time is unchanged (D16).
- **Acceptance:** `examples/oxygen_jl.jl` drives the same page twice — once
  against its real route, once with that route mocked by `with_route` — which is
  the argument for the feature stated as code. Its docs page picks the section
  up through the existing literate include.
- **Verify:** SC 21 — passes on both engines; the new section appears in
  `docs/build/examples/oxygen.html` while `docs/src/examples/oxygen.md` stays
  md5-identical (the M5 SC 9 method).
- **Files:** `examples/oxygen_jl.jl`.

### T17 — README and parity re-score (S) — SC 22, deps: T15

- **Description:** Status section, and `docs/bonnie-parity.md`'s network rows.
- **Acceptance:** Network interception and the network events leave the
  "not yet covered" list; what remains there is still accurate (WebKit, HAR,
  downloads, dialogs, persistent contexts, async, WebSockets). Parity rows that
  routing now covers are re-scored with the call that covers them.
- **Verify:** Read against the actual exports, not against this plan.
- **Files:** `README.md`, `docs/bonnie-parity.md`.

### T18 — Final verification pass (M) — deps: everything

- **Description:** Run all 27 success criteria and record each with the command
  that proved it, in the M5 verification-table style.
- **Acceptance:** A table in `tasks/todo.md`, one row per criterion. Any
  criterion that cannot be verified says so explicitly rather than being marked
  green — M5's SC 13 is the precedent.
- **Verify:** Hermetic `Pkg.test()` with no Node and no browser; smoke both
  engines; `gen/generate.jl --check`; `format(".")`; `Project.toml` `[deps]`
  diffed against `main`.
- **Files:** `tasks/todo.md`.
