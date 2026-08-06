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
- [ ] T13: `apirequest.jl` — `Playwright.fetch`, fulfil-from-upstream (M) —
      D12, D14, R4, deps: T10
      - SC 15 asserts disposal **happened**, not that nothing errored
- [ ] T14: `with_route`, `unroute!`, `unroute_all!` (S) — D8, deps: T10

### Checkpoint B — routing works end to end
- [ ] SC 1–8 pass on Chromium **and** Firefox
- [ ] No test needs a `sleep` (R1's tripwire held)
- [ ] Dispatcher lifetime proved on all four paths: spawn, stop, throwing
      handler, owner closes mid-route
- [ ] `tasks/m6-api-gaps.md` exists, whatever it contains

## Phase 4: Documentation, example and release

- [ ] T15: `docs/src/guide/network.md`, `events.md` table, `api.md` (L) —
      deps: T8–T14
      - states D5's sequential cost and the no-handler-deadline decision out loud
- [ ] T16: `examples/oxygen_jl.jl` gains its mocked-backend section (S) — D16,
      deps: T10, T13
      - the same page tested twice, real route and mocked — the argument for the
        feature, as code
- [ ] T17: README status + `docs/bonnie-parity.md` network rows (S) — deps: T15
- [ ] T18: final verification of all 27 success criteria (M) — deps: all

### Checkpoint C — milestone complete
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
| A1 | |
| A2 | |
| A3 | |
| A4 | |
| A5 | |
| A6 | |
| 1 | |
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
| 14 | |
| 15 | |
| 16 | |
| 17 | |
| 18 | |
| 19 | |
| 20 | |
| 21 | |
| 22 | |
