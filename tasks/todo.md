# TODO: Playwright.jl — Milestone 2 (codegen + API expansion)

Spec: `SPEC-M2.md`. See `tasks/plan.md` for full task descriptions, acceptance
criteria, and verification steps. Milestone 1 is archived under `tasks/m1/`.

## Phase 1: Foundation (no browser needed)
- [ ] Task 1: Vendor protocol spec (`protocol/spec/*.yml`) + `gen/` environment (S)
- [ ] Task 2: Generator → `src/generated/channels.jl` + `--check` (L) — deps: T1
- [ ] Task 3: `SerializedValue` codec in `src/serializers.jl` (M) — deps: T1 ∥ T2

### Checkpoint A
- [ ] Hermetic `Pkg.test()` green — no Node, no browser, `gen/` not instantiated
- [ ] `gen/generate.jl --check` green; regeneration is byte-reproducible
- [ ] Human review of generated code shape **before** building on it

## Phase 2: Migration, then vertical slices
- [ ] Task 4: Migrate milestone-1 API onto the generated layer, split `src/api/` (M) — deps: T2
- [ ] Task 5: `evaluate` slice — evaluate, handles, scoped disposal (M) — deps: T3, T4
- [ ] Task 6: Locator expansion — strict=false, count/nth/first/last/iterate, dispatch_event (M) — deps: T4
- [ ] Task 7: Frames slice — frames, frame_locator, content_frame (M) — deps: T5, T6
- [ ] Task 8: Launch options + explicit context lifecycle (M) — deps: T4
- [ ] Task 9: Diagnostics — console_messages, page_errors (S) — deps: T4

T5, T6, T8, T9 are independent of each other and can run in parallel after T4.

### Checkpoint B
- [ ] `SPEC-M2.md` target snippet runs verbatim against the fixtures
- [ ] Full smoke suite green on Chromium **and** Firefox
- [ ] Hermetic suite still green
- [ ] Human review before docs/polish

## Phase 3: Parity proof and polish
- [ ] Task 10: Bonnie-parity shim (<40 lines), README, docstrings, format (M) — deps: T5–T9

### Checkpoint C
- [ ] All eight `SPEC-M2.md` success criteria verified
