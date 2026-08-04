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
- [ ] T2b: Thread `resolve_timeout` through every `src/api/` call site (M) — deps: T2
- [ ] T4: `expect_event` / `wait_for_event` / `with_events` + event smoke (M) — deps: T0, T2b, T3
- [ ] T5: `wait_for_selector` / `wait_for_function` (M) — deps: T2b
- [ ] T6: `expect(...)` over `frame.expect` — probe first, then API (L) — deps: T2b
- [ ] T7: Locator ergonomics — `evaluate(loc, …)`, public accessors (M) — deps: T2b
- [ ] T8: `browser_name` + launch-option probe (M) — deps: T1
- [ ] T9: `bin/install.jl`, `PLAYWRIGHT_BROWSERS_PATH`, CI recipe (S) — no deps
- [ ] T11: calls on a closed page raise `TargetClosedError`, not `TypeError`
      from `main_frame` (S) — deps: T1

T5, T6, T7 are independent of each other after T2b. T8, T9 and T11 are
independent of the whole chain.

### Checkpoint B
- [ ] Every slice's smoke tests green on Chromium **and** Firefox
- [ ] Hermetic suite still green
- [ ] Human review before docs/polish

## Phase 3: Proof and polish
- [ ] T10: `SPEC-M3.md` target snippet as a test, README, docstrings, format (M) — deps: T4–T9

### Checkpoint C
- [ ] All twelve `SPEC-M3.md` success criteria verified
