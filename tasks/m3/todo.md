# TODO: Playwright.jl — Milestone 3 (events, waiting, assertions)

Spec: `SPEC-M3.md`. See `tasks/plan.md` for full task descriptions, acceptance
criteria, and verification steps. Milestones 1–2 are archived under `tasks/m1/`
and `tasks/m2/`.

## Phase 1: Foundation (no browser needed)
- [x] T0: Fixtures — late element, `window.ready`, popup, sync-fired event,
      5 000-message page, two range inputs (S)
- [x] T1: Error taxonomy — abstract `PlaywrightError` + `DriverError` /
      `TimeoutError` / `TargetClosedError` / `AssertionFailure` (M)
- [x] T2: Timeout settings + `resolve_timeout` cascade, `set_default_timeout!` (M) — deps: T1
- [x] T3: Event registry + `Subscription` lifetime, dispatch routing (L) — deps: T1

T2 ∥ T3 — disjoint files.

### Checkpoint A
- [x] Hermetic `Pkg.test()` green — no Node, no browser (407 tests)
- [x] Milestone-2 smoke suite still green (729 tests, both engines)
- [x] `gen/generate.jl --check` green
- [x] **Human review of the event registry and error taxonomy before anything
      builds on them**

## Phase 2: Threading, then vertical slices
- [x] T2b: Thread `resolve_timeout` through every `src/api/` call site (M) — deps: T2
- [x] T4: `expect_event` / `wait_for_event` / `with_events` + event smoke (M) — deps: T0, T2b, T3
- [x] T5: `wait_for_selector` / `wait_for_function` (M) — deps: T2b
- [x] T6: `expect(...)` over `frame.expect` — probe first, then API (L) — deps: T2b
- [x] T7: Locator ergonomics — `evaluate(loc, …)`, public accessors (M) — deps: T2b
- [x] T8: `browser_name` + launch-option probe (M) — deps: T1
- [x] T9: `bin/install.jl`, `PLAYWRIGHT_BROWSERS_PATH`, CI recipe (S) — no deps
- [x] T11: calls on a closed page raise `TargetClosedError`, not `TypeError`
      from `main_frame` (S) — deps: T1

T5, T6, T7 are independent of each other after T2b. T8, T9 and T11 are
independent of the whole chain.

### Checkpoint B
- [x] Every slice's smoke tests green on Chromium **and** Firefox
- [x] Hermetic suite still green
- [x] Human review before docs/polish

## Phase 3: Proof and polish
- [x] T10: `SPEC-M3.md` target snippet as a test, README, docstrings, format (M) — deps: T4–T9

### Checkpoint C
- [x] All twelve `SPEC-M3.md` success criteria verified

| SC | Verified by |
|---|---|
| 1 | `test_parity.jl` runs the target snippet verbatim on both engines |
| 2 | `wait_for_*` exported for Page/Frame/Locator; `grep -c 'sleep(' test/*.jl` is 0 — `poll_js` now waits driver-side |
| 3 | `test_smoke.jl` "set_default_timeout! shortens a real miss", `@elapsed` |
| 4 | `test_fixtures.jl` — missing selector → `TimeoutError`, throwing predicate → `DriverError` |
| 5 | `fill_range!` is `evaluate(slider, …)`; no `loc.frame`/`loc.selector` in the snippet |
| 6 | sync-fired console event caught; 5 000-message flood yields 5 000 |
| 7 | registry asserted directly after normal return, after a throw, and after owner close |
| 8 | `AssertionFailure` carries expected and received, from the driver's `errorDetails` |
| 9 | `browser_name(::Browser)` exported, returns `String`, agrees with the `BrowserType` method |
| 10 | `bin/install.jl` run from `/tmp` with no project; 646 MB landed under `PLAYWRIGHT_BROWSERS_PATH`; README recipe |
| 11 | probe: irrelevant options ignored → docstring branch + shared-option-set smoke test |
| 12 | hermetic `Pkg.test()` green with no Node/browser; `gen/generate.jl --check` green |
