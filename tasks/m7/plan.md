# Implementation Plan: Playwright.jl — Milestone 7 (the generator, the sweep, and the files)

Spec: [`SPEC-M7.md`](../SPEC-M7.md). Earlier plans are archived at
[`tasks/m1/plan.md`](m1/plan.md), [`tasks/m2/plan.md`](m2/plan.md),
[`tasks/m3/plan.md`](m3/plan.md), [`tasks/m4/plan.md`](m4/plan.md),
[`tasks/m5/plan.md`](m5/plan.md) and [`tasks/m6/plan.md`](m6/plan.md).

## Context

M7 is three milestones wearing one spec, and the ordering between them is the
only structural decision in the plan. **A before B before C**, for two
different reasons that happen to point the same way:

- Part A regenerates `src/generated/channels.jl` wholesale. Any Part B or C
  commit that lands first has to be rebased across a 4,000-line mechanical
  diff.
- Part B changes the shape of `save_as!` and splits the artifact family. Part C
  adds `Download`, which is a new member of that family. M6 wrote the lesson
  down after learning it: *new names should be born with the right shape rather
  than renamed a week later.*

**Part A is the smallest part and carries the sharpest test-first
requirement.** D2's no-shadow check must be written before D1's fix and must be
seen to fail — otherwise there is no evidence the fix is real rather than
incidental, and the whole argument for doing the class rather than the instance
evaporates. This is the one task in the milestone where writing the test second
makes the task worthless.

**Part B is nine decisions already made, and the risk is entirely in the call
sites.** Every rename is mechanical; what is not mechanical is finding the
seventh place `screenshot(page)` was called. `SPEC-M7.md` D5 enumerates the
in-repo sites, and T11's grep is what proves the enumeration was complete.

**Part C is the largest hand-written surface since M6's Part B**, and its risk
profile is inherited almost exactly: a dialog that nobody answers hangs the
page, in the same way and for the same reason that an unsettled route did.
M6's D5/D6/D7 are re-used rather than re-derived, which is why T14 is a large
task with a small design.

**The probe is already done.** `tasks/m7-probe.md` settled both open questions
against both engines before the spec was finished, which removes the probe task
M4 and M5 each needed and pre-empts three bugs that would otherwise have been
found in T13 and T17.

## Architecture Decisions

Recorded as D1–D14 in `SPEC-M7.md`. The ones that drive this plan:

- **D1/D2 — underscore every emitted local, and gate it.** The reason T1 exists
  as its own task ahead of the fix, and the reason T3 is verified by a scripted
  diff filter rather than by reading.
- **D5/D6 — the artifact family splits capture from export.** Drives T7 and T8,
  and is the constraint that forces Part B ahead of Part C.
- **D9 — five gaps close as deliberate.** T11 is a documentation task with a
  deletion at the end, not a cleanup. A gap closed without its reason recorded
  is a gap that gets re-discovered next milestone.
- **D10/D11 — `Download` wraps `Artifact`; the failure path throws.** T12's
  whole shape. The probe finding that `path(dl)` *raises* on a denied download
  is what makes T13's assertions non-obvious.
- **D12 — dialogs use a handler registry, and auto-dismiss survives.** The
  central decision of Part C and the source of R1. Subscribing to `dialog` is
  *what* disables the driver's auto-dismiss, so the design has no room to
  subscribe speculatively.
- **D13 — uploads get both the direct setter and the chooser**, with payload
  validation in exactly one place so T16 has one thing to test rather than two.
- **D14 — `DEFERRED_EVENTS` is audited and gated.** T18 exists because the
  table was found to be lying about `:download`, and a table that drifts once
  will drift again.

## Dependency Graph

```
PART A — must complete entirely before Part B begins

T1 test_codegen.jl no-shadow check   ← MUST FAIL FIRST (D2)
     ▼
T2 gen/generate.jl — underscore every emitted local  [D1]
     ▼
T3 regenerate channels.jl + scripted diff review     [SC 3, 4]
     ▼
T4 apirequest.jl hand-built call removed             [D3, SC 5]

T5 open tasks/m7-api-gaps.md, empty          [∥ everything, no deps]

     ══════════ Checkpoint A: the generator is fixed and gated ══════════

PART B — the sweep

T6 name → frame_name                 [D4]   ┐
T7 screenshot/pdf → _bytes split     [D5]   │ T6 ∥ T10 genuinely;
     ▼                                      │ T7 → T8 → T9 share artifacts.jl
T8 save_as!(a; path)                 [D6]   │
     ▼                                      │
T9 sources leaves start_tracing!     [D8]   ┘
T10 set_default_strict! cascade      [D7]   ← the only new behaviour in Part B
     ▼
T11 close five gaps, delete m5-api-gaps.md  [D9, SC 12]  ← the grep lives here

     ══════════ Checkpoint B: m5-api-gaps.md is gone ══════════

PART C — the files

T12 downloads.jl — Download, expect_download, context keywords  [D10, D11]
     ▼
T13 download smoke, both engines            [SC 13–16]
T14 dialogs.jl — Dialog, registry, with_dialog  [D12]  ← THE GATE
     ▼
T15 dialog smoke incl. auto-dismiss survival    [SC 17–19]
T16 uploads.jl — set_input_files!, FileChooser  [D13]
     ▼
T17 upload smoke, asserted server-side          [SC 20–22]
T18 DEFERRED_EVENTS audit + the gate            [D14, SC 23, 24]

     ══════════ Checkpoint C: all three surfaces work end to end ══════════

T19 docs: guide/files.md, events.md table, api.md   [deps: T12–T18]
T20 README status, bonnie-parity re-score           [deps: T19]
T21 final verification of all 30 criteria           [deps: everything]

     ══════════ Checkpoint D: milestone complete ══════════
```

**Real parallelism is limited and worth naming precisely.** T5 is parallel to
everything. T6 and T10 are parallel to the T7→T8→T9 chain, which is sequential
only because all three edit `src/api/artifacts.jl`. In Part C, T12, T14 and T16
touch disjoint new files and are parallel in principle — but each is followed
immediately by its own smoke task, and doing all three before any smoke would
mean debugging three new surfaces at once. Sequential in practice, deliberately.

## Risks and Mitigations

**R1 — a dialog test hangs in CI.** The highest-severity risk, and a
near-exact repeat of M6's R1/R3: a dialog nobody answers blocks the page until
a 30-second timeout, producing ten wasted CI minutes and no diagnostic.
- *Mitigation:* T14 writes the registry's lifetime before its behaviour, reusing
  M6's dispatcher pattern rather than inventing one. Every dialog test in T15
  carries an explicit timeout. D12's "unsettled dialogs are dismissed and warned
  about" rule is tested directly, not assumed.
- *Tripwire:* if a T15 test needs a `sleep` to pass, the lifetime is wrong. Fix
  the lifetime, not the test. (M6's tripwire, restated because it worked.)

**R2 — the regenerated diff is unreviewable.** T3 produces a mechanical change
across every generated function. Nobody can read 4,000 lines and honestly claim
the change was rename-only.
- *Mitigation:* SC 4 verifies it by a scripted diff filter — strip the expected
  `params` → `_params` substitution from the diff and assert the remainder is
  empty. Plus `--check` for staleness and the full suite for behaviour. The
  review is the script, and the script is the deliverable.

**R3 — Part B's D5 break misses a call site.** Seven are enumerated in the
spec; the enumeration was made by grep and greps have holes. M6 T17 found
exactly this: the old-name walk covered `docs/src` and so missed
`docs/bonnie-parity.md`, which still held four old spellings.
- *Mitigation:* T11's grep walks **all** of `docs/`, not `docs/src`, and covers
  `src`, `test`, `examples` and `README.md`. It is run after every Part B task,
  not once at the end. The docs build and both examples at Checkpoint B are the
  backstop.

**R4 — scope creep during Part B.** Part B puts the entire public surface under
the eye at once, in a milestone whose explicit subject is fixing API
deficiencies. Every unrelated wart will look both cheap and in-scope.
- *Mitigation:* T5 opens `tasks/m7-api-gaps.md` *before* Part B starts — M5's
  lesson that a gap record opened late is a gap record half written. Boundaries
  make anything past D4–D9 "ask first". The rule is unchanged from M6 and it
  held there.

**R5 — a download test leaves temp files or races the driver.** The driver
writes downloads to `/tmp/playwright-artifacts-*`, and `path` blocks until the
file is complete — which is exactly the sort of thing a test can accidentally
paper over with a `sleep`.
- *Mitigation:* SC 14 asserts `isfile` immediately after `path(dl)` returns,
  with no `sleep` anywhere in the test. That single assertion is the whole
  proof that the blocking semantics were inherited correctly.

**R6 — engine divergence in downloads and dialogs.** These are the surfaces
where Chromium and Firefox most often differ.
- *Mitigation:* largely retired before the plan was written. `tasks/m7-probe.md`
  found the two engines in exact agreement on every probed case. Residual risk
  sits in dialog *behaviour* rather than dialog payloads; M6 SC 16 is the
  precedent if an assertion has to narrow to what holds on both.

## Verification Checkpoints

**Checkpoint A — the generator is fixed** (after T4, before any Part B code)
- T1's check demonstrably failed at the pre-D1 commit and passes now (SC 1)
- `_api_request_context_fetch` accepts a real `params` argument (SC 2)
- `gen/generate.jl --check` in sync (SC 3)
- Scripted diff filter shows rename-only changes (SC 4)
- No hand-built message dict in `src/api/apirequest.jl`; hermetic and smoke
  green, `test_smoke_network.jl` SC 14 unchanged and passing (SC 5)

**Checkpoint B — the sweep is complete** (after T11)
- SC 6–12 all verified
- `tasks/m5-api-gaps.md` deleted, each closed gap's rationale grep-able in
  `src/` or `docs/`
- Old-name grep across `src`, `test`, **all** of `docs`, `examples`,
  `README.md` returns nothing
- Docs build warning-free; both examples pass on both engines
- At least one example got shorter because of `set_default_strict!` (SC 11)

**Checkpoint C — the three surfaces work** (after T18)
- SC 13–24 all pass on Chromium and Firefox
- No test needs a `sleep` to pass (R1 and R5's shared tripwire)
- `tasks/m7-api-gaps.md` exists, whatever it contains

**Checkpoint D — milestone complete** (after T21)
- All 30 criteria verified, each by running it, in a table in `tasks/todo.md`
- Gates confirmed still on: `checkdocs = :exports`, `warnonly = false`,
  `doctest = true`, both engines in smoke and `runexamples.jl`
- `Project.toml` unchanged since M6 — no new dependency (SC 27)

## Tasks

### T1 — The no-shadow check, written to fail (S) — D2, SC 1, no deps

- **Description:** Add to `test/test_codegen.jl` a check that scans the emitted
  source for any local binding not matching `^_`, and separately that no
  generated function has a keyword argument colliding with a local. **Write and
  run this before touching `gen/generate.jl`.** It must fail, naming
  `_api_request_context_fetch` and `_cdp_session_send`.
- **Acceptance:** The check fails at `HEAD`, and its failure message identifies
  both offending functions by name rather than reporting a count.
- **Verify:** `julia --project=. -e 'using Pkg; Pkg.test()'` — red, in the
  expected testset only. Record the failure output; it is SC 1's evidence.
- **Files:** `test/test_codegen.jl`

### T2 — Underscore every emitted local (S) — D1, deps: T1

- **Description:** Rename the emitter's locals in `gen/generate.jl` so no
  protocol parameter can shadow one — `params` → `_params` throughout the
  emitted bodies. The rule is the deliverable: *emitted locals lead with `_`;
  protocol parameters are spelled as the spec spells them.*
- **Acceptance:** The generator emits `_params`; T1's check passes when run
  against freshly generated output. `gen/generate.jl` itself is unchanged in
  behaviour otherwise.
- **Verify:** Generate to a scratch path and diff against the checked-in file;
  the only differences are the local renames.
- **Files:** `gen/generate.jl`

### T3 — Regenerate, and prove the diff (S) — SC 3, 4, deps: T2

- **Description:** Run `gen/generate.jl`, commit the regenerated
  `src/generated/channels.jl` as one commit. Write the scripted diff filter that
  R2 depends on: strip the expected substitution from `git diff` and assert the
  remainder is empty.
- **Acceptance:** `--check` reports in sync. The filter script reports an empty
  remainder. Full hermetic and smoke suites green.
- **Verify:** `julia --project=gen gen/generate.jl --check`; the filter script;
  both suites.
- **Files:** `src/generated/channels.jl` (regenerated, never hand-edited),
  the filter script (scratch, output recorded in `tasks/todo.md`)

### T4 — `apirequest.jl` stops hand-building its message (S) — D3, SC 2, 5, deps: T3

- **Description:** Replace the hand-built dict with a call to
  `_api_request_context_fetch`, delete the comment pointing at
  `tasks/m6-api-gaps.md`, and mark that entry resolved with this commit's hash.
- **Acceptance:** No hand-built message dict remains in the file.
  `Playwright.fetch`'s public behaviour is unchanged.
  `test_smoke_network.jl` SC 14 (fulfil-from-upstream) passes untouched.
- **Verify:** Smoke suite, both engines. Plus a direct call passing a real
  `params` argument — the exact call that produced
  `DriverError: params: expected array, got object` must now succeed (SC 2).
- **Files:** `src/api/apirequest.jl`, `tasks/m6-api-gaps.md`

### T5 — Open `tasks/m7-api-gaps.md`, empty (S) — R4, SC 30, no deps

- **Description:** Create the file with its preamble, before Part B has a line
  of code in it. M5's lesson, restated by M6's own gap file: *a gap record
  opened late is a gap record half written — by then the surprises have been
  absorbed and no longer read as surprises.*
- **Acceptance:** The file exists, is empty of findings on purpose, and says so.
- **Verify:** It is committed before T6.
- **Files:** `tasks/m7-api-gaps.md`

### T6 — `name` → `frame_name` (S) — D4, SC 6, deps: Checkpoint A

- **Description:** Mechanically identical to M6's twelve renames. One in-repo
  call site (`test/test_frames.jl:25`), plus `api.md` and the frames guide.
- **Acceptance:** `frame_name` exported, `name` absent from `names(Playwright)`,
  no old spelling anywhere.
- **Verify:** Hermetic and smoke green; the old-name grep (R3's walk).
- **Files:** `src/api/frames.jl`, `src/Playwright.jl`, `test/test_frames.jl`,
  `test/test_exports.jl`, `docs/src/api.md`, `docs/src/guide/frames.md`

### T7 — `screenshot`/`pdf` split from `_bytes` (M) — D5, SC 7, deps: T6

- **Description:** `screenshot` and `pdf` require `path` and return it; new
  `screenshot_bytes` and `pdf_bytes` return `Vector{UInt8}`. Every function
  type-stable. Update all seven call sites the spec enumerates.
- **Acceptance:** `screenshot(page)` is a `MethodError`;
  `screenshot(page; path)` returns the path; `screenshot_bytes(page)` returns
  bytes. Same three for `pdf`. Both new names have docstrings and `api.md`
  entries in this commit.
- **Verify:** Hermetic and smoke green; the docs build; `runexamples.jl` on both
  engines, since `examples/wglmakie_jl.jl:126` is one of the changed sites.
- **Files:** `src/api/navigation.jl`, `src/api/artifacts.jl`,
  `src/Playwright.jl`, `test/test_artifacts.jl`, `test/test_smoke.jl`,
  `test/test_parity.jl`, `test/test_closed.jl`, `test/test_fixtures.jl`,
  `examples/wglmakie_jl.jl`, `docs/src/guide/artifacts.md`, `docs/src/api.md`

> Over the ~5-file guideline, and deliberately: the definition and its call
> sites are one atomic change. Splitting it would mean a commit where the suite
> is red, which Boundaries forbid.

### T8 — `save_as!(a; path)` (S) — D6, SC 8, deps: T7

- **Description:** `path` becomes a keyword, matching the other three members.
  Called out as its own task because Part C's `Download` extends this exact
  signature, and it must be right before that happens.
- **Acceptance:** All four artifact-family calls take `path` as a keyword and
  return it. A test chains `save_as!(a; path = p) |> isfile`.
- **Verify:** Hermetic and smoke green.
- **Files:** `src/api/artifacts.jl`, `test/test_artifacts.jl`,
  `docs/src/guide/artifacts.md`

### T9 — `sources` leaves `start_tracing!` (S) — D8, SC 9, deps: T8

- **Description:** Remove the keyword. Its runtime `ArgumentError` becomes a
  `MethodError` — earlier and better feedback. Rewrite the guide note from
  "raises" to "is not accepted"; the note itself stays, because a reader coming
  from `playwright-python` still needs to be told why the keyword is absent.
- **Acceptance:** `start_tracing!(ctx; sources = false)` is a `MethodError`.
  `test/test_artifacts.jl:192` inverted rather than deleted.
- **Verify:** Hermetic green; docs build.
- **Files:** `src/api/artifacts.jl`, `test/test_artifacts.jl`,
  `docs/src/guide/artifacts.md`

### T10 — `set_default_strict!` (M) — D7, SC 10, 11, deps: Checkpoint A

- **Description:** A strictness cascade following the existing timeout cascade,
  resolved at `locator(...)` construction with frame → page → context
  precedence, an explicit `strict =` keyword still winning.
- **Acceptance:** The full precedence chain works: explicit keyword > frame >
  page > context > `true`. **At least one example loses a redundant
  `strict = false`** — the feature is justified by a call site getting shorter,
  not by argument (SC 11).
- **Verify:** A new hermetic testset proving each of the five levels is reached,
  by overriding exactly one at a time. `runexamples.jl` on both engines.
- **Files:** `src/timeouts.jl`, `src/api/locators.jl`, `src/Playwright.jl`,
  `test/test_timeouts.jl`, `examples/oxygen_jl.jl` or `examples/genie_jl.jl`,
  `docs/src/api.md`

### T11 — Close five gaps, delete the file (M) — D9, SC 12, deps: T6–T10

- **Description:** Record the rationale for gaps 1, 2, 5, 6 and 8 in the
  docstring or guide page that owns each, then delete
  `tasks/m5-api-gaps.md`. Its content will have become either a commit or a
  documented decision — nothing is left "recorded". Also home to R3's grep,
  widened per M6 T17's lesson to walk **all** of `docs/`.
- **Acceptance:** The file is gone. Each of the five rationales is findable by
  grepping `src/` and `docs/` for that gap's key phrase.
- **Verify:** The five greps, run and recorded. Docs build warning-free with
  `checkdocs = :exports` still on.
- **Files:** `src/api/locators.jl`, `src/api/expect.jl`, `src/api/evaluate.jl`,
  `src/api/waiting.jl`, `docs/src/guide/locators.md`, `tasks/m5-api-gaps.md`
  (deleted)

### T12 — `downloads.jl` (L) — D10, D11, deps: Checkpoint B

- **Description:** The `Download` struct wrapping `Artifact` plus `url` and
  `suggested_filename`; `save_as!`/`path`/`delete_file!` forwarding methods;
  `cancel!`, `failure`, and the `artifact(dl)` escape hatch. `expect_download`
  over the existing event machinery. `:download` leaves `DEFERRED_EVENTS` with
  a **non**-opt-in `EventSpec`. `new_context` gains `accept_downloads` and
  `downloads_path`.
- **Acceptance:** `accept_downloads` maps `true`→`"accept"`, `false`→`"deny"`,
  `nothing`→**parameter omitted**. Never `"internal-browser-default"` — the
  probe found that value emits no event at all, so the mistake costs a silent
  timeout. Docstrings state that `failure(dl)` is the only non-throwing success
  check.
- **Verify:** `test/test_downloads.jl` hermetic against the fake connection:
  construction from a synthetic payload, all three forwarding verbs, `failure`
  returning `nothing` vs. a string, and the three-way keyword mapping including
  the omission case.
- **Files:** `src/api/downloads.jl`, `src/api/events.jl`,
  `src/api/lifecycle.jl`, `src/Playwright.jl`, `test/test_downloads.jl`

### T13 — Download smoke, both engines (M) — SC 13–16, deps: T12

- **Description:** Real downloads against the fixture server, both engines.
- **Acceptance:** SC 13 (`suggested_filename` matches `Content-Disposition`,
  `save_as!` writes identical bytes); SC 14 (`isfile` immediately after
  `path(dl)` returns, **no `sleep` anywhere** — R5's tripwire); SC 15
  (`failure` is `nothing` vs. a string, **and** `path(dl)` raises on the refused
  one); SC 16 (`artifact(dl)`'s verbs exercised, not just exported).
- **Verify:** `PLAYWRIGHT_JL_SMOKE=1`, Chromium and Firefox.
- **Files:** `test/test_smoke_files.jl`, `test/fixtures/m7.html`

### T14 — `dialogs.jl` (L) — D12, deps: T13 — **the gate**

- **Description:** `Dialog` with `dialog_type`, `message`, `default_value`,
  `accept!(d; prompt_text)`, `dismiss!`. The handler registry —
  `on_dialog!` / `off_dialog!` / `with_dialog(page; handler) do … end` — reusing
  M6's dispatcher-task pattern, not a new one.
- **Acceptance:** All three of M6's inherited rules hold: an unsettled dialog is
  dismissed and warned about once per registration; a throwing handler's
  exception is collected and rethrown at release while the dialog is still
  dismissed; handlers run on a dispatcher task and never on the transport reader
  task. **Write the lifetime before the behaviour** — that ordering is what made
  M6's equivalent work.
- **Verify:** `test/test_dialogs.jl` hermetic: registration/removal, the
  auto-dismiss-and-warn path, the throwing handler, and the reader-task
  assertion. Explicit timeouts throughout.
- **Files:** `src/api/dialogs.jl`, `src/api/events.jl`, `src/Playwright.jl`,
  `test/test_dialogs.jl`

### T15 — Dialog smoke, both engines (M) — SC 17–19, deps: T14

- **Description:** Real `alert`, `confirm` and `prompt` against the fixture.
- **Acceptance:** SC 17 (all four cases produce the correct observable effect —
  a `confirm` accepted and dismissed must differ in the DOM); **SC 18 — with no
  handler registered, the dialog is auto-dismissed and the page proceeds.** That
  is the criterion that catches the event-only design's footgun if the design
  ever drifts, and it is the single most important assertion in Part C. SC 19
  (settles-nothing warns once; throws surfaces out of `with_dialog`; page
  proceeds either way).
- **Verify:** `PLAYWRIGHT_JL_SMOKE=1`, both engines, every test time-boxed.
- **Files:** `test/test_smoke_files.jl`, `test/fixtures/m7.html`

### T16 — `uploads.jl` (M) — D13, deps: T15

- **Description:** `set_input_files!` on `Locator` and `ElementHandle`, taking
  a path, a vector of paths, the in-memory `(name, mime_type, buffer)` form, or
  nothing (clears). `FileChooser` wrapping the event's `element` and
  `isMultiple`, with `set_files!` delegating to `set_input_files!` so payload
  validation lives in exactly one place. `:filechooser` leaves
  `DEFERRED_EVENTS` as an **opt-in** spec.
- **Acceptance:** Paths and buffer are mutually exclusive, raising
  `ArgumentError` at the call site before any message reaches the driver — the
  treatment M6 D15 gave `fulfill!`'s body sources.
- **Verify:** `test/test_uploads.jl` hermetic: the validation, the empty call,
  and that both dispatch paths reach the right generated command with the right
  selector and strictness.
- **Files:** `src/api/uploads.jl`, `src/api/events.jl`, `src/Playwright.jl`,
  `test/test_uploads.jl`

### T17 — Upload smoke, asserted server-side (M) — SC 20–22, deps: T16

- **Description:** Real uploads, with the fixture server echoing back what it
  received — the assertion has to be server-side or it proves nothing.
- **Acceptance:** SC 20 (filename and bytes echoed back, for single, multi and
  in-memory forms); SC 21 (`ArgumentError` before the wire); SC 22
  (`is_multiple` is `false` / `true` / **`false`** for plain / `multiple` /
  `webkitdirectory` — probed identical on both engines, so the
  `webkitdirectory` case asserts `false` on purpose).
- **Verify:** `PLAYWRIGHT_JL_SMOKE=1`, both engines.
- **Files:** `test/test_smoke_files.jl`, `test/fixtures/m7.html`,
  `test/fixtures/upload.csv`

### T18 — Audit `DEFERRED_EVENTS`, and gate it (S) — D14, SC 23, 24, deps: T17

- **Description:** Three entries disappear with Parts C's events. Re-read every
  remaining entry against current source in the same commit — the drift is the
  finding, not the entry. `:route`'s message is **rewritten, not deleted**:
  `Route` is wrapped, it simply is not exposed as an event because `route!` is
  the supported path.
- **Acceptance:** `test/test_events.jl` gains a gate that fails if any event in
  the deferred table is actually present in `events_for` on any owner.
- **Verify:** The gate proved by temporarily re-adding `:download` to the
  deferred table and watching it fail.
- **Files:** `src/api/events.jl`, `test/test_events.jl`

### T19 — Docs (M) — deps: T12–T18

- **Description:** New `docs/src/guide/files.md` covering all three surfaces;
  the events guide's supported-events table grows; `api.md` gains every new
  name. The guide says why the dialog *registry* is the documented path even
  though `:dialog` is now a real event.
- **Acceptance:** Zero errors, zero warnings, with `checkdocs = :exports`,
  `warnonly = false` and `doctest = true` all still on and none weakened
  (SC 26).
- **Verify:** `julia --project=docs docs/make.jl`.
- **Files:** `docs/src/guide/files.md`, `docs/src/guide/events.md`,
  `docs/src/api.md`, `docs/make.jl`

### T20 — README and parity (S) — SC 29, deps: T19

- **Description:** README Status rewritten for milestones 1–7; downloads, file
  choosers and dialogs leave the not-covered list. `docs/bonnie-parity.md`
  re-scored where uploads and downloads apply.
- **Acceptance:** No stale claim survives — the not-covered list is checked
  item by item against what M7 shipped.
- **Verify:** Read against `names(Playwright)`, not against memory.
- **Files:** `README.md`, `docs/bonnie-parity.md`

### T21 — Final verification (M) — deps: everything

- **Description:** Run all 30 success criteria and record how each was verified
  in `tasks/todo.md`, M5/M6 style. A criterion that cannot be met says so
  instead of being ticked — M6's Checkpoint A is the precedent.
- **Acceptance:** Every criterion has a line naming what was run and what it
  produced. Pass counts recorded for hermetic and smoke.
- **Verify:** Both suites, both engines; docs build; `--check`; `format(".")`;
  `runexamples.jl`; `git diff` on `Project.toml` empty since M6.
- **Files:** `tasks/todo.md`
