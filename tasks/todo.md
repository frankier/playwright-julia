# TODO: Playwright.jl — Milestone 4 (artifacts and the failure path)

Spec: `SPEC-M4.md`. See `tasks/plan.md` for full task descriptions, acceptance
criteria, and verification steps. Milestones 1–3 are archived under `tasks/m1/`,
`tasks/m2/` and `tasks/m3/`.

## Phase 1: Foundation and probe

- [x] T0: Fixture `m4.html` + `artifacts/` in `.gitignore` (S) — no deps
- [x] T1: **PROBE** — tracing stop path (D1) and document-expect strings (D2),
      findings to `tasks/m4-probe.md` (M) — **gate**
      → gate **passes**: `tracingStopChunk(mode="archive")` returns a real
      `Artifact` on both engines, so `save_as` is the whole implementation and
      no Julia zip dependency is needed. `tracesDir` at launch is not required.
      `frame.expect` wants selector `""` (not `:root`) for `to.have.title` /
      `to.have.url`, and the M3 `received_value` accessor reads the failure
      unchanged.
- [x] T2: `retry_until` gains `target`, `on_timeout`, `on_error` (M) — B1–B3
- [x] T3: diagnostics no-throw on a dead target (S) — B5

T2 ∥ T3 — disjoint files, and both are hermetic and independent of the probe, so
a browser-free session can start here.

### Checkpoint A
- [ ] Hermetic `Pkg.test()` green — no Node, no browser
- [ ] Milestone-3 smoke suite still green, both engines
- [ ] `gen/generate.jl --check` green
- [ ] **Human review of the T1 probe findings before any of Part A is built.**
      If trace assembly needs a Julia zip dependency: **stop and escalate** —
      that is an *Ask first* boundary, not a workaround.

## Phase 2: Artifact slices and the fixture

- [ ] T7: `pdf(page; …)`, Chromium-only with a client-side check (S) — A3, D7
- [ ] T4: `Artifact` wrapper — `save_as`, `path`, `delete` (S) — A4, deps: T1
- [ ] T5: tracing — `start_tracing`, `stop_tracing`, `with_tracing` (M) — A1,
      deps: T1, T4
- [ ] T6: video — `record_video` on `new_context`, `video(page)` (M) — A2, deps: T4
- [ ] T8: `expect(::Page)` / `expect(::Frame)` (M) — B6, deps: T1
- [ ] T9: `with_page` + `report_diagnostics` + `artifacts_on` (M) — B4, deps: T3

T7 → T4 → T5 → T6 share `src/api/artifacts.jl` and land one at a time; T7 goes
first to establish the file. T2 and T8 share `src/api/expect.jl` — sequence them.
T9 is independent of Part A once T3 is in.

### Checkpoint B
- [ ] Every slice's smoke tests green on Chromium **and** Firefox
- [ ] Hermetic suite still green
- [ ] A trace zip opened once by hand: `npx playwright@1.61.1 show-trace
      artifacts/trace.zip` (SC 3 — the one criterion that cannot be automated)
- [ ] Human review before docs/polish

## Phase 3: Proof and polish

- [ ] T10: `SPEC-M4.md` target snippet as a test, README, docstrings, format (M)
      — deps: T2–T9

### Checkpoint C
- [ ] All thirteen `SPEC-M4.md` success criteria verified

| SC | Verified by |
|---|---|
| 1 | *(fill in as T5 lands)* |
| 2 | |
| 3 | |
| 4 | |
| 5 | |
| 6 | |
| 7 | |
| 8 | |
| 9 | |
| 10 | |
| 11 | |
| 12 | |
| 13 | |
