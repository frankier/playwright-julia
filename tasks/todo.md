# TODO: Playwright.jl — Milestone 1

See `tasks/plan.md` for full task descriptions, acceptance criteria, and verification steps.

## Phase 1: Foundation (no browser needed)
- [x] Task 1: Package skeleton — Project.toml, module root, empty test suite passes (S)
- [x] Task 2: Driver download/locate/install in `src/driver.jl` (M) — deps: T1
- [x] Task 3: Length-prefixed JSON transport in `src/transport.jl` (S) — deps: T1
- [x] Task 4: Connection & guid object registry in `src/connection.jl` (M) — deps: T3

### Checkpoint A
- [x] `Pkg.test()` green with no Node/browser installed
- [ ] Human review of protocol-layer API

## Phase 2: Vertical slices against a real browser
- [x] Task 5: Bootstrap handshake + `playwright() do ... end` wrapper (M) — deps: T2, T4
- [x] Task 6: First browser slice — launch, new_page, goto, title, close + fixture server (M) — deps: T5
- [x] Task 7: Locator slice — locator, text_content, click, fill (M) — deps: T6
- [x] Task 8: screenshot + error-path coverage (S) — deps: T6

### Checkpoint B
- [x] SPEC snippet runs end to end on Chromium
- [x] Unit suite green without browser; smoke suite green with `PLAYWRIGHT_JL_SMOKE=1`
- [ ] Human review before hardening

## Phase 3: Hardening & polish
- [ ] Task 9: Clean shutdown (no orphan processes) + Firefox smoke matrix (M) — deps: T7, T8
- [ ] Task 10: README + first-use install UX + docstrings + format (S) — deps: T9

### Checkpoint C
- [ ] All five SPEC success criteria verified
