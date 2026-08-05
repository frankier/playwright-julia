# TODO: Playwright.jl — Milestone 5 (documentation, examples and release readiness)

Spec: `SPEC-M5.md`. See `tasks/plan.md` for full task descriptions, acceptance
criteria, and verification steps. Milestones 1–4 are archived under `tasks/m1/`
… `tasks/m4/`.

Sizes: (S) small, (M) medium, (L) large.

## Phase 1: Groundwork, probe and first CI

- [x] T0: `LICENSE` (MIT) + compat bounds on every dep + ignore rules (S) —
      no deps
- [x] T1: **PROBE** — headless WebGL for WGLMakie on both engines, findings to
      `tasks/m5-probe.md` (M) — **gate**: fixes B4's assertion level (D8)
      - Chromium renders in full with **no launch flags**; Firefox has no WebGL
        at all and cannot be given one. Recommends **D8 level 3** with the
        Firefox leg kept as a structural assertion.
      - ⛔ **awaiting human review — T7 is blocked on it**
- [x] T2: CI — hermetic matrix (1.10, `1`) + codegen check + format check (M) —
      **gate**: the first green run on a pushed branch
      - green: run `30989693673` (all four jobs, branch `m5-ci`, PR #1)
      - gate proved by breaking it: run `30989885239` — Formatting red on a
        deliberately misformatted line, the other three still green; reverted
- [ ] T3: CI — smoke job, both engines, browsers cached (M) — deps: T2

T0 ∥ T1 ∥ T2 — disjoint. T1 needs a browser; T0 and T2 do not.

### Checkpoint A
- [ ] `LICENSE` present; hermetic `Pkg.test()` green under the new compat bounds
- [ ] CI green on a **pushed** branch, Julia 1.10 and `1`
- [ ] `gen/generate.jl --check` and the format check green in CI
- [ ] Smoke job green on Chromium **and** Firefox, with a cache **hit** read out
      of a second run's log (not assumed)
- [ ] **Human review of the T1 probe findings before T7 is written** — this is
      the gate that fixes B4's assertion level. Dropping WGLMakie entirely
      remains *Ask first*.

## Phase 2: Examples

- [ ] T4: `examples/` scaffold (`common.jl`, `runexamples.jl`, pinned Manifest)
      + HTTP.jl example (M) — B1, no deps
- [ ] T5: Oxygen.jl example (S) — B2, deps: T4
- [ ] T6: Genie.jl example (M) — B3, deps: T4
- [ ] T7: WGLMakie.jl example (M) — B4, deps: **T1**, T4
- [ ] T8: CI — examples job + weekly unpinned drift job (S) — deps: T2, T4–T7

T5 ∥ T6 ∥ T7 once T4 is in — separate files, one shared `Project.toml`, so
sequence the dependency additions.

### Checkpoint B
- [ ] All four examples exit 0 **locally**, from a clean checkout, on Chromium
      and Firefox
- [ ] All four green in CI on the committed Manifest
- [ ] No example is flaky — T7 run three times (retries are not a fix)
- [ ] `Project.toml`'s `[deps]` still unchanged

## Phase 3: Documentation

- [ ] T9: docstring audit + gap fill + `tasks/m5-api-gaps.md` (L) — no deps,
      **start immediately**; the critical path runs through here
- [ ] T10: Documenter scaffold + `api.md` + `checkdocs` gate (M) — deps: T9
- [ ] T11: guide pages (L) — deps: T10
- [ ] T12: example pages, source included from the executed file (S) —
      deps: T10, T4–T7
- [ ] T13: doctests on a browser-free path (S) — deps: T10
- [ ] T14: README slims to a landing page (S) — deps: **T11**
- [ ] T15: docs workflow + deploy (M) — deps: T10

T9 needs no browser, no network and no CI — the ideal offline task, and the
longest. T11 ∥ T12 ∥ T13 ∥ T15 once T10 is in.

### Checkpoint C
- [ ] `docs/make.jl` builds with **zero warnings**, `checkdocs = :exports` on
- [ ] Gate verified by breaking it: one docstring deleted → build fails →
      restored
- [ ] Doctests pass; one deliberately broken → build red → restored
- [ ] Example page changes when its script is edited, with no `.md` edit
- [ ] `README.md` under 150 lines, no API reference material left
- [ ] Site deployed and reachable at its Pages URL
- [ ] Deploy authenticated by the workflow's `GITHUB_TOKEN`, with **no repository
      secret created** (D10)
- [ ] **Repo-settings step:** GitHub Pages pointed at the `gh-pages` branch

## Phase 4: Release metadata and proof

- [ ] T16: TagBot, CompatHelper, Dependabot, README badges (S) — deps: T2, T15
- [ ] T17: final verification of all sixteen success criteria (M) — deps: all

### Checkpoint D
- [ ] All sixteen `SPEC-M5.md` success criteria verified, each by running it
- [ ] Gates confirmed still on: `checkdocs = :exports`, warnings-as-errors,
      both engines in smoke
- [ ] `tasks/m5-api-gaps.md` non-empty, and **nothing in it was fixed**
      (Assumption 2)

## Verification table

Filled in by T17 — one row per criterion, naming the command or run that proved
it, in the style of `tasks/m4/todo.md`. "smoke" means both engines under
`PLAYWRIGHT_JL_SMOKE=1`; "hermetic" means no Node and no browser.

| SC | Verified by |
|---|---|
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
