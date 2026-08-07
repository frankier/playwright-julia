# TODO: Playwright.jl — Milestone 7 (the generator, the sweep, and the files)

Spec: `SPEC-M7.md`. See `tasks/plan.md` for full task descriptions, acceptance
criteria, and verification steps. Milestones 1–6 are archived under `tasks/m1/`
… `tasks/m6/`. The spec-phase probe findings are in `tasks/m7-probe.md`.

Sizes: (S) small, (M) medium, (L) large.

**The rule for Part A:** T1 must be written and seen to fail *before* T2
touches the generator. A fix with no failing test in front of it is a fix with
no evidence.

**The rule for Part B:** one rename per commit, hermetic **and** smoke green
between each — M6's rule, which worked.

**The tripwire for Part C:** if a test needs a `sleep` to pass, the lifetime is
wrong. Fix the lifetime, not the test.

## Phase 1: Part A — the generator

- [x] T1: the no-shadow check in `test_codegen.jl` (S) — D2, SC 1, no deps
      - ⚠️ **write it first and run it red.** It must name
        `_api_request_context_fetch` and `_cdp_session_send`, not report a count
      - record the failure output — it is SC 1's only evidence
      - **Red at `e29cf75`,** both halves, named not counted:
        ```
        Expression: sort(unique(bare_locals)) == Symbol[]
         Evaluated: [:params, :result] == Symbol[]
        Expression: sort(shadowed) == Symbol[]
         Evaluated: [:_api_request_context_fetch, :_cdp_session_send] == Symbol[]
        ```
      - the bare-locals half names **`result` as well as `params`** — D1 spells
        out only `params`, but D1's *rule* and D2's check both cover every
        emitted local, so T2 renames both
- [x] T2: underscore every emitted local in `gen/generate.jl` (S) — D1, deps: T1
      - the rule is the deliverable: emitted locals lead with `_`, protocol
        parameters are spelled as the spec spells them
      - **two** locals, not one: `params` → `_params` and `result` → `_result`
- [x] T3: regenerate `channels.jl` + the scripted diff filter (S) — SC 3, 4, deps: T2
      - the filter *is* the review; nobody reads 4,000 lines honestly (R2)
      - landed in **one commit with T2**: the emitter change alone leaves
        `--check` stale and T1's gate red, and a commit with a red suite is
        exactly what T7's note forbids
      - `gen/generate.jl --check` → `Generated channel layer is in sync`
      - filter output (SC 4):
        ```
        PASS: remainder empty -- the only change to src/generated/channels.jl
              is params -> _params, result -> _result, and the formatter
              reflow those renames caused.
        ```
      - the filter strips whitespace before comparing **on purpose**: `_params`
        is one character longer, so JuliaFormatter rewraps ~12 lines. A reflow
        is not a change in meaning, and a filter that flagged it would be a
        filter nobody trusted
- [x] T4: `apirequest.jl` stops hand-building its message (S) — D3, SC 2, 5, deps: T3
      - the exact call that produced `DriverError: params: expected array, got
        object` must now succeed
      - it does. Against a local echo server, passing two real `params` entries:
        ```
        QUERY SEEN BY SERVER: colour=octarine&n=8
        SC 2 PASS: params reached the wire as an array
        ```
      - `tasks/m6-api-gaps.md` gap 1 marked resolved in place with the three
        commits that did it
- [ ] T5: open `tasks/m7-api-gaps.md`, empty on purpose (S) — R4, SC 30, no deps
      - **before T6**, or it will not get written at all (M5's lesson, which M6
        confirmed by following it)

T5 ∥ everything — it is a file with a preamble and no dependencies.

### Checkpoint A — the generator is fixed and gated

- [x] T1's check demonstrably failed at the pre-D1 commit and passes now (SC 1)
      — red at `e29cf75` naming both functions, green from `6be2ea9`
- [x] `_api_request_context_fetch` accepts a real `params` argument (SC 2)
      — echo server saw `colour=octarine&n=8`
- [x] `gen/generate.jl --check` reports in sync (SC 3)
- [x] Scripted diff filter shows rename-only changes to `channels.jl` (SC 4)
      — remainder empty modulo the renames and their formatter reflow
- [x] No hand-built message dict in `src/api/apirequest.jl` (SC 5)
- [x] Hermetic and smoke green; `test_smoke_network.jl` SC 14 unchanged
      — hermetic 1648 passed; smoke 2387 passed, both engines, 0 failed

## Phase 2: Part B — the sweep

- [ ] T6: `name` → `frame_name` (S) — D4, SC 6, deps: Checkpoint A
- [ ] T7: `screenshot`/`pdf` split from `_bytes` (M) — D5, SC 7, deps: T6
      - seven in-repo call sites, enumerated in the spec; the grep is what
        proves the enumeration was complete (R3)
      - over the ~5-file guideline deliberately: definition and call sites are
        one atomic change, or the suite is red mid-commit
- [ ] T8: `save_as!(a; path)` (S) — D6, SC 8, deps: T7
      - its own task because Part C's `Download` extends this exact signature
- [ ] T9: `sources` leaves `start_tracing!` (S) — D8, SC 9, deps: T8
      - invert the existing test, don't delete it; keep the guide note
- [ ] T10: `set_default_strict!` cascade (M) — D7, SC 10, 11, deps: Checkpoint A
      - **an example must get shorter**, or the feature is unjustified (SC 11)
- [ ] T11: close five gaps, delete `m5-api-gaps.md` (M) — D9, SC 12, deps: T6–T10
      - the grep walks **all** of `docs/`, not `docs/src` — M6 T17's lesson
      - a gap closed without its reason recorded is a gap re-discovered next
        milestone

T6 ∥ T10. T7 → T8 → T9 is sequential only because all three edit
`src/api/artifacts.jl`.

### Checkpoint B — `m5-api-gaps.md` is gone

- [ ] SC 6–12 all verified
- [ ] `tasks/m5-api-gaps.md` deleted; all five rationales grep-able in `src/`
      or `docs/`
- [ ] Old-name grep across `src`, `test`, **all** of `docs`, `examples`,
      `README.md` returns nothing
- [ ] Docs build warning-free; both examples pass on both engines
- [ ] At least one example lost a redundant `strict = false` (SC 11)

## Phase 3: Part C — the files

- [ ] T12: `downloads.jl` — `Download`, `expect_download`, context keywords (L)
      — D10, D11, deps: Checkpoint B
      - `accept_downloads = nothing` **omits the parameter**; never sends
        `"internal-browser-default"`, which emits no event at all and costs a
        silent timeout (probed — `tasks/m7-probe.md`)
      - `:download` is **not** opt-in; `:dialog` and `:filechooser` are
      - docstrings must say `failure(dl)` is the only non-throwing success check
- [ ] T13: download smoke, both engines (M) — SC 13–16, deps: T12
      - SC 14 asserts `isfile` immediately after `path(dl)` returns, with **no
        `sleep` anywhere** (R5)
      - SC 15 has two halves; the second — `path(dl)` *raises* on a refused
        download — is the one a user gets wrong
- [ ] T14: `dialogs.jl` — `Dialog`, the registry, `with_dialog` (L) — D12,
      deps: T13 — **THE GATE**
      - write the lifetime before the behaviour; reuse M6's dispatcher pattern
        rather than inventing one
      - subscribing to `dialog` is *what* disables the driver's auto-dismiss,
        so there is no room to subscribe speculatively
- [ ] T15: dialog smoke, both engines (M) — SC 17–19, deps: T14
      - ⚠️ **SC 18 is the most important assertion in Part C**: with no handler
        registered, the dialog is auto-dismissed and the page proceeds. It is
        what catches the event-only design's footgun if the design ever drifts
- [ ] T16: `uploads.jl` — `set_input_files!`, `FileChooser` (M) — D13, deps: T15
      - validation lives in exactly one place; `set_files!` delegates
- [ ] T17: upload smoke, asserted **server-side** (M) — SC 20–22, deps: T16
      - a client-side upload assertion proves nothing
      - `webkitdirectory` asserts `is_multiple == false` **on purpose** — probed
        identical on both engines, not an omission
- [ ] T18: audit `DEFERRED_EVENTS` and gate it (S) — D14, SC 23, 24, deps: T17
      - `:route`'s message is rewritten, not deleted — `Route` *is* wrapped
      - prove the gate by re-adding `:download` to the table and watching it fail

T12, T14 and T16 touch disjoint new files and are parallel in principle. Kept
sequential in practice: each is followed by its own smoke task, and doing all
three before any smoke means debugging three new surfaces at once.

### Checkpoint C — the three surfaces work end to end

- [ ] SC 13–24 all pass on Chromium and Firefox
- [ ] No test needs a `sleep` to pass (R1 and R5's shared tripwire)
- [ ] `tasks/m7-api-gaps.md` exists, whatever it contains

## Phase 4: docs and wrap-up

- [ ] T19: `guide/files.md`, the events table, `api.md` (M) — SC 26, deps: T12–T18
      - the guide says why the dialog *registry* is the documented path even
        though `:dialog` is now a real event
- [ ] T20: README status, `bonnie-parity.md` re-score (S) — SC 29, deps: T19
      - check the not-covered list item by item against `names(Playwright)`,
        not against memory
- [ ] T21: final verification of all 30 criteria (M) — deps: everything
      - a criterion that cannot be met **says so** instead of being ticked —
        M6's Checkpoint A is the precedent

### Checkpoint D — milestone complete

- [ ] All 30 criteria verified, each by running it, in the table below
- [ ] Gates confirmed still on: `checkdocs = :exports`, `warnonly = false`,
      `doctest = true`, both engines in smoke and `runexamples.jl`
- [ ] `Project.toml` unchanged since M6 — no new dependency (SC 27)

## Success criteria — how each was verified

Filled in by T21. A criterion that cannot be met says so.

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
| 17 | |
| 18 | |
| 19 | |
| 20 | |
| 21 | |
| 22 | |
| 23 | |
| 24 | |
| 25 | |
| 26 | |
| 27 | |
| 28 | |
| 29 | |
| 30 | |
