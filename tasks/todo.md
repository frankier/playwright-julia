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
- [x] T5: open `tasks/m7-api-gaps.md`, empty on purpose (S) — R4, SC 30, no deps
      - **before T6**, or it will not get written at all (M5's lesson, which M6
        confirmed by following it)
      - landed at `09f34a1`, before Part B had a line of code in it. It has
        since earned two entries — gap 1 during Part B, gap 2 during T19 —
        which is the instrument working rather than the file growing

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

- [x] T6: `name` → `frame_name` (S) — D4, SC 6, deps: Checkpoint A
      - hermetic 1649, smoke 2388 both engines, docs build clean
      - **the grep had a false positive:** `"function $name("` in
        `test_codegen.jl` interpolates a local to build a *generated* function's
        name. `$` joins `.` and `\w` in the negative lookbehind
      - **the grep cannot see `@ref` links at all.** ``[`name`](@ref)`` in
        `guide/locators.md` matches no `name(`-shaped pattern; the docs build
        failed on it, which is the backstop actually doing the work
      - `docs/src/guide/frames.md` in the plan's file list **does not exist** —
        frame docs live in `guide/locators.md`
- [x] T7: `screenshot`/`pdf` split from `_bytes` (M) — D5, SC 7, deps: T6
      - seven in-repo call sites, enumerated in the spec; the grep is what
        proves the enumeration was complete (R3)
      - over the ~5-file guideline deliberately: definition and call sites are
        one atomic change, or the suite is red mid-commit
      - ⚠️ **D5's acceptance is unreachable as written.** It predicts
        `screenshot(page)` is a `MethodError`; it is an `UndefKeywordError`,
        and could not be otherwise — `path` is a *keyword*, which D5 also
        requires, and Julia raises `UndefKeywordError` for a missing required
        keyword. Asserted what actually happens, with the reasoning in the
        test. The real error is the better one: it names the keyword
      - two tests asserted bytes **and** path from one call
        (`test_smoke.jl:452`, `test_artifacts.jl:676`) — exactly what D5 exists
        to split, so each became two calls
      - the Chromium check moved into `pdf_bytes` with `pdf` delegating, so a
        refused `pdf(page; path)` throws before creating an empty file
      - hermetic 1660, smoke 2401 both engines, docs + format clean
- [x] T8: `save_as!(a; path)` (S) — D6, SC 8, deps: T7
      - its own task because Part C's `Download` extends this exact signature
      - the new testset asserts the shared shape across **all four** members,
        so the family cannot drift apart again silently
- [x] T9: `sources` leaves `start_tracing!` (S) — D8, SC 9, deps: T8
      - invert the existing test, don't delete it; keep the guide note
      - landed in one commit with T8 — they interleave in the same three files,
        and splitting after the fact would have meant reconstructing an
        intermediate state that never existed. My sequencing error, not a
        red-suite constraint like T2+T3
- [x] T10: `set_default_strict!` cascade (M) — D7, SC 10, 11, deps: Checkpoint A
      - **an example must get shorter**, or the feature is unjustified (SC 11)
      - `genie_jl.jl`: four `strict = false` gone, 86 → 83 code lines. Genie
        rather than Oxygen because every remaining single-element locator there
        targets an **ID**, unique by HTML spec, so none was leaning on
        strictness. Oxygen and `http_jl.jl` genuinely mix — `http_jl.jl:85`
        asserts on `li.greeting` expecting exactly one — and a page-wide
        default there would have removed a real check to shorten a diff
      - takes a **`Frame`**, unlike `set_default_timeout!`: D7's acceptance
        names a frame level, and without a setter that level is unreachable
      - shares `conn.timeouts` rather than a second table — same cascade, same
        lock, same pruning; an unpruned guid-keyed table leaks for the life of
        the connection
      - `false` is a setting, not an absence, and there is a test named for it
- [x] T11: close five gaps, delete `m5-api-gaps.md` (M) — D9, SC 12, deps: T6–T10
      - the grep walks **all** of `docs/`, not `docs/src` — M6 T17's lesson
      - a gap closed without its reason recorded is a gap re-discovered next
        milestone
      - each rationale grep-able where the surface that owns it lives:

        | Gap | Recorded in | Findable by |
        |---|---|---|
        | 1 | `guide/locators.md` | `invisible to .checkdocs` |
        | 2 | `api/locators.jl` | `missing keyword is the signal` |
        | 5 | `api/expect.jl` | `argument one for` |
        | 6 | `api/locators.jl` | `differing only in whether they wait` |
        | 8 | `api/evaluate.jl` | `arity depends on what you evaluate` |

      - the guide had a **live pointer to the file being deleted**
        (`guide/locators.md:41`, "see `tasks/m5-api-gaps.md`"); it now
        documents `set_default_strict!` instead
      - surviving `m5-api-gaps` mentions are in `SPEC-M5.md` / `SPEC-M7.md`,
        which are historical records rather than live references

T6 ∥ T10. T7 → T8 → T9 is sequential only because all three edit
`src/api/artifacts.jl`.

### Checkpoint B — `m5-api-gaps.md` is gone

- [x] SC 6–12 all verified
- [x] `tasks/m5-api-gaps.md` deleted; all five rationales grep-able in `src/`
      or `docs/` — table under T11
- [x] Old-name grep across `src`, `test`, **all** of `docs`, `examples`,
      `README.md` returns nothing — it runs in `test_exports.jl` on every
      hermetic run, and gained `name` → `frame_name` in T6
- [x] Docs build warning-free; **all 8 example runs** pass on both engines —
      including `wglmakie_jl.jl` on Firefox, which was failing before M7 began
      (`tasks/m7-api-gaps.md` gap 1, fixed on instruction)
- [x] At least one example lost a redundant `strict = false` (SC 11) —
      `genie_jl.jl`, four of them, 86 → 83 code lines

## Phase 3: Part C — the files

- [x] T12: `downloads.jl` — `Download`, `expect_download`, context keywords (L)
      — D10, D11, deps: Checkpoint B
      - `accept_downloads = nothing` **omits the parameter**; never sends
        `"internal-browser-default"`, which emits no event at all and costs a
        silent timeout (probed — `tasks/m7-probe.md`)
      - `:download` is **not** opt-in; `:dialog` and `:filechooser` are
      - docstrings must say `failure(dl)` is the only non-throwing success check
      - **two spec corrections, both from checking rather than assuming.** D10
        asks `new_context` to gain `downloads_path`; it cannot — `downloadsPath`
        is in the `LaunchOptions` mixin, not `ContextOptions`, and `launch` has
        exposed it correctly since before M7. And `test_events.jl` asserted
        `:download` was deferred *on a context*; it is a `Page` event, so on a
        context it is an ordinary "no such event for this owner"
      - the tests use `timeout_fixture`, not `event_fixture`: the latter's
        autoreply task drains `client_messages`, so a test asserting on the
        message it sent loses the race and blocks forever. That cost a hung
        suite before it cost a comment
      - hermetic 1756 passed
- [x] T13: download smoke, both engines (M) — SC 13–16, deps: T12
      - SC 14 asserts `isfile` immediately after `path(dl)` returns, with **no
        `sleep` anywhere** (R5)
      - SC 15 has two halves; the second — `path(dl)` *raises* on a refused
        download — is the one a user gets wrong
      - 32 assertions, 23s, both engines. The fixture server sets a
        `Content-Disposition` filename that deliberately **differs** from the
        URL (`report-2026.csv` from `/download/report.csv`) — without the
        mismatch, SC 13 would pass on a name derived from the path and prove
        nothing
- [x] T14: `dialogs.jl` — `Dialog`, the registry, `with_dialog` (L) — D12,
      deps: T13 — **THE GATE**
      - write the lifetime before the behaviour; reuse M6's dispatcher pattern
        rather than inventing one
      - subscribing to `dialog` is *what* disables the driver's auto-dismiss,
        so there is no room to subscribe speculatively
      - the `dialog` **event** is declared on `browserContext`, the
        **subscription** is accepted on either — so a page-scoped registry
        subscribes to the page's context and filters by the dialog's own page,
        M6 D11's split again
      - the first version **hung the suite**: its helper waited for a fixed
        number of driver messages, and a wrong guess blocks forever instead of
        failing. It uses the unbounded `autoreply!` responder now
      - the unsettled warning is asserted through the registration's flag, not
        `@test_logs` — the warning is emitted on the dispatcher task, spawned
        before the macro installs its logger
      - hermetic 1848 passed
- [x] T15: dialog smoke, both engines (M) — SC 17–19, deps: T14
      - ⚠️ **SC 18 is the most important assertion in Part C**: with no handler
        registered, the dialog is auto-dismissed and the page proceeds. It is
        what catches the event-only design's footgun if the design ever drifts
      - asserted, and asserted through the **DOM** rather than through what
        Julia saw: an accepted `confirm` and a dismissed one write different
        text, so a handler whose answer never reached the browser fails here
        instead of passing
      - the two warnings in the run output are SC 19's, one per engine — the
        once-per-registration rule visible in the log
- [x] T16: `uploads.jl` — `set_input_files!`, `FileChooser` (M) — D13, deps: T15
      - validation lives in exactly one place; `set_files!` delegates
      - the in-memory buffer reaches the wire as **raw bytes**: `to_wire`
        encodes `Vector{UInt8}` itself, and encoding here would have worked
        while quietly duplicating the rule
      - the empty call sends an empty `localPaths` rather than omitting the
        parameter — omitting both leaves the previous selection in place
      - hermetic 1921 passed
- [x] T17: upload smoke, asserted **server-side** (M) — SC 20–22, deps: T16
      - a client-side upload assertion proves nothing
      - `webkitdirectory` asserts `is_multiple == false` **on purpose** — probed
        identical on both engines, not an omission
      - the fixture server records every multipart part into a `Ref` and the
        tests read that; filenames **and full byte contents** compared, for the
        single, multi and in-memory forms alike
      - 102 assertions across T13, T15 and T17, 43s, both engines, no `sleep`
- [x] T18: audit `DEFERRED_EVENTS` and gate it (S) — D14, SC 23, 24, deps: T17
      - `:route`'s message is rewritten, not deleted — `Route` *is* wrapped
      - prove the gate by re-adding `:download` to the table and watching it fail
      - `:download`'s entry had said "Artifact is not wrapped yet" since M4
        wrapped `Artifact` — an error message telling users something false
        about why their event was unsupported. That is this table's failure
        mode, and it is silent
      - the gate is written as a function over its inputs rather than a bare
        assertion, so SC 24 can watch it fail
      - hermetic 1933 passed

T12, T14 and T16 touch disjoint new files and are parallel in principle. Kept
sequential in practice: each is followed by its own smoke task, and doing all
three before any smoke means debugging three new surfaces at once.

### Checkpoint C — the three surfaces work end to end

- [x] SC 13–22 and 24 all pass on Chromium and Firefox — 102 smoke assertions
      across T13, T15 and T17, 43s; hermetic 1933 at T18.
      **SC 23 is half met and is not ticked** — see the table below and
      `m7-api-gaps.md` gap 2. The three events are absent from
      `DEFERRED_EVENTS` as required, but `:dialog` is not in
      `events_for(::Page)` either, so the criterion's second half is false as
      written. Found in T19, recorded rather than quietly ticked
- [x] No test needs a `sleep` to pass (R1 and R5's shared tripwire) — the only
      occurrences of the word in Part C's files are the comments naming the rule
- [x] `tasks/m7-api-gaps.md` exists, whatever it contains — two entries

## Phase 4: docs and wrap-up

- [x] T19: `guide/files.md`, the events table, `api.md` (M) — SC 26, deps: T12–T18
      - the guide says why the dialog *registry* is the documented path even
        though `:dialog` is now a real event
      - ⚠️ **`:dialog` is not a real event.** The line above assumed it was.
        It is absent from `CONTEXT_EVENTS` as well as `PAGE_EVENTS`, so
        `expect_event(page, :dialog)` reports `unknown event` — and since T14
        also removed it from `DEFERRED_EVENTS`, nothing anywhere says why.
        Recorded as `m7-api-gaps.md` gap 2 rather than fixed: it is a change to
        `src/api/events.jl` in a docs task, which is the exact reflex R4 warns
        about. **The guide documents what the code does**, which is that the
        registry is the only path
      - `api.md` needed **no new entries** — T12/T14/T16 added each name as they
        landed, because `checkdocs = :exports` would have failed their commits
        otherwise. The only thing missing was the page the `Dialog` docstring
        already linked to, which is what made the build red
      - the red was a real one, and pre-existing: `Cannot resolve @ref for
        md"[Files, dialogs and uploads](@ref)" in docs/src/api.md`, from
        `dialogs.jl:63`. It also fixed the page's title for me
      - the events table gains `:download` and `:filechooser`; the deferred
        paragraph was stale in three ways and now distinguishes "no accessors
        yet" (`:worker`, `:websocket`, `:bindingcall`) from "wrapped, but not
        event-shaped" (`:route`)
      - docs build: zero errors, zero warnings, with `checkdocs = :exports`,
        `warnonly = false` and `doctest = true` all still on (SC 26); hermetic
        1933 unchanged; `format(".")` clean
- [x] T20: README status, `bonnie-parity.md` re-score (S) — SC 29, deps: T19
      - check the not-covered list item by item against `names(Playwright)`,
        not against memory
      - all eight items checked against the 145 exported names. One leaves the
        list — "downloads, file choosers and dialogs". The other seven stand,
        and **WebKit is the one worth stating**: `install` accepts `"webkit"`,
        but `PlaywrightAPI` has only `chromium` and `firefox` fields, so there
        is no `pw.webkit` to launch. Not covered, confirmed by the struct
      - the parity re-score is **"no row changes", and that is the finding**:
        `bonnie_needs.md` asks for nothing about files in either direction, so
        a row scoring M7's surfaces against it would be inventing the need.
        Two smaller M7 changes do touch it — `frame_name` in blocker 2, and
        `set_default_strict!` easing rather than closing blocker 3
      - the rename grep **did not catch** `` `name` `` in
        `docs/bonnie-parity.md:18`: it sat in a comma-separated list of
        function names, with no `name(`-shaped call to match. Third distinct
        blind spot found in this grep (T6 found `$name(` and `@ref` links) —
        it is a good backstop and not a proof
- [x] T21: final verification of all 30 criteria (M) — deps: everything
      - a criterion that cannot be met **says so** instead of being ticked —
        M6's Checkpoint A is the precedent
      - **28 met, 2 partially met and named as such.** SC 7's second half is
        unreachable *as written* (`UndefKeywordError`, not `MethodError` — the
        keyword the same criterion requires is what makes it so), and SC 23's
        second half is **false**: `:dialog` is in no owner's event table
      - everything re-run at `911e63d` rather than cited from memory: hermetic
        1933, smoke 2776 both engines, docs build clean, `--check` in sync,
        `format(".")` true, `Project.toml` diff empty, all 8 example runs pass

### Checkpoint D — milestone complete

- [x] All 30 criteria verified, each by running it, in the table below — 28
      met, SC 7 and SC 23 partially met with the unmet half stated
- [x] Gates confirmed still on: `checkdocs = :exports`, `warnonly = false`,
      `doctest = true`, both engines in smoke and `runexamples.jl`
- [x] `Project.toml` unchanged since M6 — no new dependency (SC 27):
      `git diff 9d66c21 HEAD -- Project.toml` is 0 lines

## Success criteria — how each was verified

Filled in by T21. A criterion that cannot be met says so.

| SC | Verified by |
|---|---|
| 1 | Run at both commits during T1, not asserted: **red at `e29cf75`** (pre-D1) naming `[:_api_request_context_fetch, :_cdp_session_send]` and `[:params, :result]` rather than reporting a count, **green from `6be2ea9`**. The failure output is recorded verbatim under T1; the green half is re-confirmed by every hermetic run since, including T21's |
| 2 | Verified during T4 against a local echo server, passing two real `params` entries: `QUERY SEEN BY SERVER: colour=octarine&n=8`. The call that produced `DriverError: params: expected array, got object` succeeds. Not re-run at T21 — it needs a throwaway server, and the wire shape it proves is covered by `test_network.jl` on every hermetic run |
| 3 | `julia --project=gen gen/generate.jl --check` → `Generated channel layer is in sync with protocol/spec/`. Re-run at T21 |
| 4 | Scripted diff filter over `src/generated/channels.jl`, run during T3: remainder empty. The only changes are `params` → `_params`, `result` → `_result`, and the JuliaFormatter reflow those renames caused (~12 lines, whitespace-stripped before comparing on purpose) |
| 5 | `grep -nE 'Dict\{String' src/api/apirequest.jl` — three hits, all header dicts; the fetch goes through the generated `_api_request_context_fetch` at line 292. Hermetic and smoke green, `test_smoke_network.jl` SC 14 unchanged |
| 6 | `"frame_name" in names(Playwright)` true, `"name" in names(Playwright)` false. The old-name grep in `test_exports.jl` walks `src/`, `test/`, all of `docs/`, `examples/` and `README.md` on every hermetic run and finds no survivor |
| 7 | One method each for `screenshot`, `screenshot_bytes`, `pdf`, `pdf_bytes`. ⚠️ **Half of this criterion is unreachable as written**: it predicts `screenshot(page)` is a `MethodError`, but `path` is a required *keyword* — which the same criterion demands — so Julia raises `UndefKeywordError`. Asserted what actually happens, with the reasoning in the test. The real error names the missing keyword, which is the better one |
| 8 | `test_artifacts.jl:707` — `@test save_as!(v; path = dest) \|> isfile`, run over all four family members in one testset so they cannot drift apart silently |
| 9 | `test_artifacts.jl:227` — `@test_throws MethodError start_tracing!(f.context; sources = true)`. (The spec says `sources = false`; the keyword does not exist, so either value is the same `MethodError`.) `docs/src/guide/artifacts.md:72` explains the absence without claiming it raises |
| 10 | `test_timeouts.jl:322–360` — all five levels of D7's chain, each proved reachable by overriding exactly one. `set_default_strict!` takes a `Frame` as well as a `Page`/`BrowserContext`, because without a frame setter D7's frame level is unreachable |
| 11 | `examples/genie_jl.jl`: four per-locator `strict = false` replaced by one `set_default_strict!(page, false)`, 86 → **83 code lines** (`grep -vcE '^\s*(#\|$)'`). Genie rather than Oxygen because every remaining single-element locator there targets an **ID** — unique by HTML spec — so none was leaning on strictness. `http_jl.jl:85` genuinely asserts on `li.greeting` expecting exactly one, and a page-wide default there would have deleted a real check to shorten a diff |
| 12 | `tasks/m5-api-gaps.md` is gone (`ls` → No such file). All five rationales found by grepping their key phrases: `invisible to .checkdocs` → `docs/src/guide/locators.md`; `missing keyword is the signal` → `src/api/locators.jl`; `argument one for` → `src/api/expect.jl`; `differing only in whether they wait` → `src/api/locators.jl`; `arity depends on what you evaluate` → `src/api/evaluate.jl` |
| 13 | `test_smoke_files.jl:108`, both engines. The fixture server sets a `Content-Disposition` filename that deliberately **differs** from the URL (`report-2026.csv` from `/download/report.csv`), so the assertion cannot pass on a name derived from the path; `save_as!` bytes compared to what the server sent |
| 14 | `test_smoke_files.jl:123`, both engines. `isfile` asserted on the line immediately after `path(dl)` returns. `sleep` appears nowhere in the file except in the comments naming R5's rule |
| 15 | `test_smoke_files.jl:153`, both engines: a download refused by `accept_downloads = false` still arrives with a correct url and suggested filename, `failure(dl)` is a non-empty string, and `@test_throws` on both `path` and `save_as!` — the half users get wrong. Hermetically, `test_downloads.jl` asserts none of the three `accept_downloads` inputs can produce `"internal-browser-default"` |
| 16 | `test_smoke_files.jl:137`, both engines — `artifact(dl)`'s verbs exercised on the returned `Artifact`, not merely checked for existence |
| 17 | `test_smoke_files.jl:191`, both engines. Each dialog type asserted through its **effect on the page**: an accepted `confirm` and a dismissed one write different text, so a handler whose answer never reached the browser fails rather than passes |
| 18 | `test_smoke_files.jl:230`, both engines. Clicked through an alert and a confirm with nothing registered from Julia, checked the registry really was empty first, and checked the DOM moved on. This is the assertion that catches the event-only design's footgun if the design ever drifts |
| 19 | `test_smoke_files.jl:251`, both engines. A handler that settles nothing warns once per registration and the page proceeds; a handler that throws surfaces out of `with_dialog` with the dialog dismissed anyway; the registry is empty afterwards and the next dialog is the driver's again. The two warnings in the smoke output are this test's, one per engine |
| 20 | `test_smoke_files.jl:300`, `:311`, `:323`, both engines. The fixture server records every multipart part into a `Ref` and the tests read **that**, not the DOM — filenames and full byte contents, for the single, multi and in-memory forms |
| 21 | `test_smoke_files.jl:337`, both engines — the `ArgumentError` arrives before the wire, and the page is untouched by the call that never happened. Also hermetic in `test_uploads.jl`, where the assertion is that nothing was sent |
| 22 | `test_smoke_files.jl:350` and `:365`, both engines. `false` for a plain input, `true` for `multiple`, **`false` for `webkitdirectory`** — asserted on purpose, not by omission: the probe found the engines in exact agreement, so `true` would be wrong on both rather than catching a divergence. `set_files!` through the chooser gets its own server-side leg |
| 23 | ⚠️ **Half met, and not ticked.** First half holds: `:download`, `:dialog` and `:filechooser` are all absent from `DEFERRED_EVENTS` (`[:bindingcall, :route, :websocket, :worker]`), and the gate in `test_events.jl` is written as a function over its inputs so SC 24 can watch it fail. Second half is **false as written**: `:download` and `:filechooser` are in `events_for(::Page)`, but `:dialog` is in neither `PAGE_EVENTS` nor `CONTEXT_EVENTS`, so `expect_event(page, :dialog)` reports `unknown event` — a false "no such event" for a type that is wrapped and documented. Found in T19, recorded as `m7-api-gaps.md` gap 2, and left unfixed because it is a behaviour change discovered during a docs task. The fix is one `DEFERRED_EVENTS` entry parallel to `:route`'s, plus two test lines |
| 24 | `DEFERRED_EVENTS[:route]` reads: *Route is wrapped, but interception is `route!`/`with_route`, not an event*. The M4-era claim that `Artifact` was unwrapped is gone with `:download`'s entry |
| 25 | Hermetic `Pkg.test()`: **1933 passed, 0 failed**, 3m48s. `PLAYWRIGHT_JL_SMOKE=1 Pkg.test()`: **2776 passed, 0 failed**, 11m40s, Chromium and Firefox |
| 26 | `julia --project=docs docs/make.jl` — zero errors, zero warnings. `checkdocs = :exports`, `warnonly = false` and `doctest = true` all still on in `docs/make.jl`, none weakened; the size thresholds are the only tuned settings and predate M7 |
| 27 | `gen/generate.jl --check` in sync; `format(".", verbose = false)` → `true` with a clean tree afterwards; `git diff 9d66c21 HEAD -- Project.toml` → **0 lines**, so no dependency was added since M6 |
| 28 | `julia --project=examples examples/runexamples.jl` — **all 8 runs PASS**, both engines: `http_jl` 24.7s/25.3s, `oxygen_jl` 44.0s/44.5s, `genie_jl` 45.1s/45.6s, `wglmakie_jl` 90.5s/87.7s (chromium/firefox). That includes `wglmakie_jl.jl` on Firefox, which was failing before M7 began — `m7-api-gaps.md` gap 1, fixed on instruction rather than on this file's own authority |
| 29 | README Status rewritten for milestones 1–7, with M7's renames alongside M6's twelve. The not-covered list checked item by item against the 145 names in `names(Playwright)`: "downloads, file choosers and dialogs" removed; the other seven stand. WebKit stays because `PlaywrightAPI` has only `chromium` and `firefox` fields — there is no `pw.webkit` to launch, whatever `install` accepts |
| 30 | `tasks/m7-api-gaps.md` opened at `09f34a1`, empty on purpose, **before** T6 was the first line of Part B. It has since earned two entries |
