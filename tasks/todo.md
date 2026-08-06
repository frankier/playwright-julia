# TODO: Playwright.jl — Milestone 6 (a Julia-shaped API, and the network)

Spec: `SPEC-M6.md`. See `tasks/plan.md` for full task descriptions, acceptance
criteria, and verification steps. Milestones 1–5 are archived under `tasks/m1/`
… `tasks/m5/`.

Sizes: (S) small, (M) medium, (L) large.

**The rule for Part A:** one rename per commit, hermetic **and** smoke green
between each. A rename that breaks something must be attributable to itself.

## Phase 1: Part A — the bang convention

- [x] T1: the three collision renames — `fill` → `set_value!`,
      `delete` → `delete_file!`, `close` → `close!` (M) — D3, no deps
      - the only renames with thinking in them: two stop extending `Base`
      - each docstring's first line names Playwright's own spelling
      - prove the docs gate now covers them: delete one docstring, watch the
        build go red, restore
- [x] T2: `goto!`, `click!`, `dispatch_event!` (S) — deps: T1
      - one commit per name, green after each
- [x] T3: `dispose!`, `save_as!`, `start_tracing!`, `stop_tracing!` (S) — deps: T2
      - `with_tracing` keeps no bang (D2)
- [x] T4: `clear_console_messages!`, `clear_page_errors!` (S) — deps: T3
- [x] T5: the no-shadow test and the old-name grep (S) — SC A4, A6, deps: T4
      - ⚠️ **neither test is trusted until it has failed once** — reintroduce
        `export fill!` and one old call site in a scratch copy to prove both
- [x] T6: Checkpoint A verification (S) — deps: T5
- [x] T7: open `tasks/m6-api-gaps.md` with its preamble (S) — R6, no deps
      - do this *before* Part B, or it will not get written at all (M5's lesson)

T7 ∥ everything — it is a file with a preamble and no dependencies.

### Checkpoint A — Part A complete, before any Part B code

**Result: clean, with one pre-existing failure that is not Part A's.**
`runexamples.jl` is 7/8, not 8/8: `wglmakie_jl.jl` fails on Firefox at
`examples/wglmakie_jl.jl:144`, `@test has_webgl == false` evaluating
`true == false`. The example asserts that headless Firefox has no WebGL and
takes its level-2 structural path accordingly; this machine's Firefox (build
1532) reports WebGL available, so the assertion about the *engine* is what is
now false.

Attributed rather than assumed: the identical failure — same line, same
expression, same evaluation — reproduces at `e45f3f4`, the commit before this
milestone began, in a clean worktree. It is not caused by the renames, and
fixing it is an example's environmental assumption rather than anything M6 is
about (Boundaries, R6). Recorded here in the style of M5's SC 13: a criterion
that cannot be met says so, instead of being ticked.
- [x] All twelve renames applied; `names(Playwright)` has every new name and no
      old one
- [x] Hermetic **and** smoke green after **each** rename commit, not just the
      last (SC A2)
- [x] `using Playwright` shadows nothing in `Base`: `fill!` on an array,
      `delete!` on a `Dict`, `close` on an `IOBuffer`, `count` and `first` all
      still resolve to `Base` (SC A6)
- [x] Old-name grep across `src`, `test`, `docs`, `examples`, `README.md`
      returns nothing (SC A4)
- [x] `close!`, `set_value!` and `delete_file!` in `names(Playwright)` and
      covered by `checkdocs = :exports` (SC A3)
- [x] Docs build warning-free (every rename commit); `runexamples.jl` 7/8 —
      see the note above, the eighth is pre-existing and reproduces at `e45f3f4`
- [x] Diff reviewed commit by commit: no signature change, no behaviour change
      (SC A5, Assumption 3)

## Phase 2: Part B — the foundations

- [x] T8: `globs.jl` — glob→Regex and the matcher union (M) — D9, R2, no deps
      - the case table lives in **one** place, read by both the test and the
        guide (SC 17)
- [x] T9: `network.jl` — Request/Response accessors, the three header
      functions, the three body functions (M) — D10, no deps

T8 ∥ T9 — genuinely disjoint, no shared code.

## Phase 3: Part B — routing

- [x] T10: `routing.jl` — Route, registry, dispatcher task (L) — D5–D8, R1
      — 🚧 **GATE**: nothing in Part B is demonstrable until this works
      - write the task's **lifetime** first, its behaviour second
      - ⚠️ **no test may use `sleep` to pass.** If one needs it, the lifetime is
        wrong — fix the lifetime, not the test (R1's tripwire)
- [x] T11: the settle-guarantee tests (M) — D6, D7, R1, R3, deps: T10
      - four lifetime tests + three settle tests, every one with an explicit
        timeout (R3)
      - each proved by breaking what it guards
- [x] T12: the four network events + page-scoped filtering (M) — D11, deps: T10
- [x] T13: `apirequest.jl` — `Playwright.fetch`, fulfil-from-upstream (M) —
      D12, D14, R4, deps: T10
      - SC 15 asserts disposal **happened**, not that nothing errored
- [x] T14: `with_route`, `unroute!`, `unroute_all!` (S) — D8, deps: T10

### Checkpoint B — routing works end to end
- [x] SC 1–8 pass on Chromium **and** Firefox
- [x] No test needs a `sleep` (R1's tripwire held)
- [x] Dispatcher lifetime proved on all four paths: spawn, stop, throwing
      handler, owner closes mid-route
- [x] `tasks/m6-api-gaps.md` exists, whatever it contains

## Phase 4: Documentation, example and release

- [x] T15: `docs/src/guide/network.md`, `events.md` table, `api.md` (L) —
      deps: T8–T14
      - states D5's sequential cost and the no-handler-deadline decision out loud
- [x] T16: `examples/oxygen_jl.jl` gains its mocked-backend section (S) — D16,
      deps: T10, T13
      - the same page tested twice, real route and mocked — the argument for the
        feature, as code
- [x] T17: README status + `docs/bonnie-parity.md` network rows (S) — deps: T15
- [ ] T18: final verification of all 27 success criteria (M) — deps: all

### Checkpoint C — milestone complete

**All 27 criteria verified by running them**, table below. Nothing is marked
green that was not run, and three criteria are worth reading rather than
ticking:

- **A4** was incomplete when first written. Its grep walked `docs/src`, so
  `docs/bonnie-parity.md` — which sits in `docs/` — escaped Part A entirely and
  still held four old spellings until T17. The walk now covers `docs/`.
- **SC 3** passed for the wrong reason until it was proved. A glob matcher
  never reaches D6's "nothing matched" path, because the driver filters
  non-matching URLs before delivery; only a `Regex` or predicate widens the
  union to `**/*` and exercises it.
- **SC 16**'s first assertion was a Chromium-only fact dressed as a general
  one.

One thing outside the criteria is **not** green, and is recorded rather than
hidden: `runexamples.jl` is 7/8. See the Checkpoint A note — `wglmakie_jl.jl`
fails on Firefox on an assertion about WebGL availability that reproduces
identically at `e45f3f4`, before this milestone began.
- [ ] All 5 Part A and 22 Part B criteria verified, each by running it — table
      below
- [ ] Gates confirmed still on: `checkdocs = :exports` and `warnonly = false`
      in `docs/make.jl`; `doctest = true`; both engines in the smoke job and in
      `runexamples.jl`. None weakened to make anything green.
- [ ] Nothing in `tasks/m5-api-gaps.md` fixed beyond D3's incidental resolution
      of gap 1 for `fill` and `close` (Assumption 4)

## Verification table

Filled in by T18 — one row per criterion, naming the command or run that proved
it, in the style of `tasks/m5/todo.md`. "smoke" means both engines under
`PLAYWRIGHT_JL_SMOKE=1`; "hermetic" means no Node and no browser.

A criterion that cannot be verified says so explicitly rather than being marked
green. M5's SC 13 is the precedent — it stayed ⛔ because Pages had to be pointed
at `gh-pages` by hand, and saying so was worth more than a green tick.

| SC | Verified by |
|---|---|
| A1 | `names(Playwright)` printed after the twelfth rename: every new name present, no old one. Also pinned by `test_exports.jl`'s expected list. |
| A2 | Full `PLAYWRIGHT_JL_SMOKE=1 Pkg.test()` green after **each** of the twelve rename commits (1866–1868 passes), not only the last. |
| A3 | `close!`, `set_value!`, `delete_file!` in `names(Playwright)`; proved covered by the docs gate by deleting `set_value!`'s `api.md` entry and watching the build fail on checkdocs, then restoring it. |
| A4 | `test_exports.jl` "no old spelling survives anywhere" — proved by restoring one `goto(` in `docs/src/index.md` and watching it fail. **Widened in T17**: the walk covered `docs/src` and so missed `docs/bonnie-parity.md`, which still held four old spellings. |
| A5 | `git diff f353146..HEAD -- src/` reviewed: every changed definition differs from its predecessor in nothing but its name. No signature or behaviour change. |
| A6 | `test_exports.jl` "using Playwright shadows nothing in Base" — proved by re-adding `export fill!`, which produced exactly D3's predicted `UndefVarError: fill! not defined in Main`. |
| 1 | `test_smoke_network.jl` SC 1, both engines: page renders mocked data **and** the server's hit counter never moves. |
| 2 | `test_smoke_network.jl` SC 2, both engines: a second page in the same context still gets the server's answer under a Page registration; a context registration reaches both. |
| 3 | `test_smoke_network.jl` SC 3, both engines — **and proved**: removing the auto-`continue!` makes the page die with `TimeoutError: Timeout 30000ms exceeded`. Strengthened first: a glob matcher never reaches D6's no-match path because the driver filters it, so the test uses a predicate. |
| 4 | `test_smoke_network.jl` SC 4, both engines: the exception comes out of `with_route`, and the page under it still navigated and loaded its data. |
| 5 | `test_smoke_network.jl` SC 5, both engines: two matching requests through one unsettling registration produce exactly one warning, page loads both times. |
| 6 | `test_smoke_network.jl` SC 6, both engines: newest-first, unrouting the newer restores the older, `unroute_all!` restores the server — all in one test. |
| 7 | `test_smoke_network.jl` SC 7, both engines: counted server-side, zero hits, and the page's own error handler fired. |
| 8 | `test_smoke_network.jl` SC 8, both engines: the **server** echoes back the header the route added. |
| 9 | `test_smoke_network.jl` SC 9, both engines: `url`, `method`, `headers` and `post_data_string` of a real POST. |
| 10 | `test_smoke_network.jl` SC 10, both engines: `status`, `ok`, headers, `json`, `text`, plus a 404 so `ok` is proved false somewhere. |
| 11 | `test_smoke_network.jl` SC 11, both engines: `:requestfailed` fires with a non-empty engine-specific `error_text`. |
| 12 | `test_smoke_network.jl` SC 12, both engines: two pages in one context, both fetching the same URL; the returned request's frame is the watched page's main frame. |
| 13 | `test_smoke_network.jl` SC 13 (`expect_event(ctx, :request)` returns a `Request`) and `test_events.jl` (the four are absent from `DEFERRED_EVENTS`, present on both owners). |
| 14 | `test_smoke_network.jl` SC 14, both engines: `Playwright.fetch(route)` returns the genuine 200 and body; the page receives that body under a forced 500. |
| 15 | `test_smoke_network.jl` SC 15, both engines — asserted, not assumed: the handler's response is disposed afterwards, a standalone one is not, and reading a disposed body **raises**. |
| 16 | `test_smoke_network.jl` SC 16, both engines. Note: the original assertion (`raw` strictly larger) was Chromium-only — Firefox's initializer already carries the same set — so it asserts what holds on both. |
| 17 | `test_globs.jl` hermetic, 74 tests, every row of `GLOB_CASES` exercised; the guide renders that same list. Additionally cross-checked against playwright-core 1.61.1 by running upstream's `globToRegexPattern` under the driver's own Node: **20/20 byte-identical patterns**. |
| 18 | Hermetic `Pkg.test()` 1645 passes in 3m34 with smoke skipped; `PLAYWRIGHT_JL_SMOKE=1` 2384 passes in 10m22 on both engines. |
| 19 | `julia --project=docs docs/make.jl` — zero errors, zero warnings, with `checkdocs = :exports`, `warnonly = false` and `doctest = true` all still on and none weakened. |
| 20 | `gen/generate.jl --check` → "in sync"; `format(".")` → `true`; `git diff e45f3f4..HEAD -- Project.toml` → empty. |
| 21 | `examples/oxygen_jl.jl` passes on Chromium and Firefox; "mocked backend" appears in `docs/build/examples/oxygen.html`; `docs/src/examples/oxygen.md` md5 unchanged at `c6811683032423551ce09c08fa814377`. |
| 22 | README Status rewritten (milestones 1–6; interception and the network events removed from not-covered); `docs/bonnie-parity.md` gains four re-scored rows. |
