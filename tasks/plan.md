# Implementation Plan: Playwright.jl — Milestone 9 (five engines and three platforms)

Spec: [`SPEC-M9.md`](SPEC-M9.md). Earlier plans are archived at
[`tasks/m1/plan.md`](m1/plan.md), [`tasks/m2/plan.md`](m2/plan.md),
[`tasks/m3/plan.md`](m3/plan.md), [`tasks/m4/plan.md`](m4/plan.md),
[`tasks/m5/plan.md`](m5/plan.md), [`tasks/m6/plan.md`](m6/plan.md),
[`tasks/m7/plan.md`](m7/plan.md) and [`tasks/m8/plan.md`](m8/plan.md).

## Context

**This plan's subject is a feedback loop, not a feature.** M1–M8 were API
milestones: write the code, run the suite locally, push a green commit. M9 adds
one small type and three functions, and then spends most of its length on two
platforms the developer cannot run and three engines the suite has never seen.
The inner loop for the majority of the tasks below is *push and wait for
fourteen CI jobs*, one platform of which queues.

Everything unusual about the ordering follows from that:

- **The instrument is built before the work** (D14). T2–T4 open a branch, a
  draft PR and a three-OS hermetic job that runs the *existing* suite and is
  expected to go red. That red is not a failure of the milestone; it is Part B's
  task list, and it is captured before anything is fixed.
- **`.gitattributes` lands before the scaffold**, not with Part B (T3 before
  T4). A Windows checkout without it rewrites every text file, so the scaffold's
  red would be a mixture of real portability bugs and line-ending noise — and
  the whole value of the scaffold is that its failure list is trustworthy.
- **A driver-assembly job sits between hermetic and smoke** (T15). This is an
  elaboration of D6's logic rather than a new decision: D6 puts the hermetic
  tier first because it is the cheapest signal, and assembling a Node bundle and
  asking it its version is the next cheapest — two minutes against a smoke job's
  twenty, with no browser involved. Part B's hardest unknowns (OQ 1, OQ 5) are
  answerable at that rung.
- **Part A happens on Linux, entirely, before any platform work.** Not because
  of code dependencies — there are almost none — but so that a WebKit failure
  means WebKit. Debugging a new engine and a new platform in the same red job is
  the thing this ordering exists to prevent.

**What is genuinely coupled, and what only looks it:**

- **T7's `Engine` blocks almost everything after it.** The engine loops, the
  `SMOKE_ENGINES` parsing, the branded install work and the whole matrix all
  name engines by string. T7 is the second code task for that reason.
- **OQ 3 can invalidate two decisions**, so it is answered at T4 rather than
  discovered at T19. If the runner images do not ship Chrome and Edge where
  Playwright's channel lookup finds them, D3a's "CI never installs them" and
  D13's "branded jobs need no cache" both fall, and the branded jobs need an
  install step that needs root on Linux. That is a spec amendment, and it is
  much cheaper as one at T4 than as one at Checkpoint C.
- **Parts B and C are not sequential the way the phases suggest.** Part B's
  fixes are *verified by* Part C's jobs. The phases are a reading order; the
  actual loop alternates. The checkpoints, not the phase boundaries, are the
  real gates.

**The size risk is T12 and nothing else.** Every other task here is bounded and
mostly mechanical. T12 — getting five engines green on Linux and adjudicating
each divergence — is bounded only by how different WebKit turns out to be, and
the M8 surfaces (HAR replay, persistent contexts, WebSocket routing) have never
seen a third engine. R3 is how the plan keeps that from eating the milestone.

## Architecture Decisions

Recorded as D1–D15 in `SPEC-M9.md`. The ones that drive this plan:

- **D1a — the engine mapping lives in one value.** T7 is early because five
  string-named engines with two of them being channels is a mapping that four
  separate callers would otherwise each copy.
- **D3a — branded browsers are found, not installed.** This is why the branded
  jobs in T19 are *simpler* than the bundled ones (no install, no cache) and
  why T4 must confirm the premise first.
- **D4 — a skip costs a documented row.** T11 builds the machinery that makes
  that enforceable *before* T12 creates the pressure to skip things, which is
  the same shape as M8's T13-before-T14 rule.
- **D6 — cheapest tier first**, extended by this plan with the driver-assembly
  rung at T15.
- **D13 — two engine classes in the workflow.** T19 is a single task because
  splitting the cache key change from the install change would publish a cache
  that lies, which is precisely the bug D13 exists to prevent.
- **D14 — the PR is the instrument.** T2 before T6, and one attributable fix
  per push throughout.

## Dependency Graph

```
T1  gaps file ─┐
T2  branch+PR ─┼─→ T3 .gitattributes ─→ T4 scaffold+diagnostics ─→ T5 probe
               │                                                     │
               │        ┌────────────────────────────────────────────┘
               │        │
               ▼        ▼
   Part A (Linux)   T6 webkit field ─→ T7 Engine ─┬─→ T8  SMOKE_ENGINES
                                                  ├─→ T9  install: with_deps + branded
                                                  │      └─→ T10 the two error messages
                                                  └─→ T11 skip_engine + engines.md gate
                                                         └─→ T12 five engines green ◆
                                                              │
                       ┌──────────────────────────────────────┘
                       ▼
   Part B          T13 node_platform/url ─┐
                   T14 path assertions ───┼─→ T17 hermetic green ×3 OS
                   T15 driver job ────────┼─→ T16 macOS aarch64 assembly
                                          │
                       ┌──────────────────┘
                       ▼
   Part C          T18 matrix ─→ T19 cache+install classes ─┬─→ T20 Windows smoke ◆
                                                            └─→ T21 macOS smoke ◆
                                                                 └─→ T22 durations
                                                                      └─→ T23 undraft
                       ▼
   Paperwork       T24 docs ─→ T25 README ─→ T26 bonnie ─→ T27 final

   ◆ = the three tasks whose size is not knowable in advance
```

**What the graph says that the phase list does not:** T13 and T14 have no
dependency on Part A at all and could be done at any point after T5. They are
placed in Part B because they are Part B's subject, but if T12 stalls they are
the work to pick up rather than sitting idle waiting for a CI queue.

## Risks

**R1 — The feedback loop is a CI queue, and macOS is the critical path.**
Five macOS smoke jobs plus two macOS hermetic jobs against a concurrency cap
well below the other platforms. A careless task ordering could spend a day per
iteration.
*Mitigation:* the cheap rungs exist and are used in order (hermetic → driver
assembly → smoke), one attributable fix per push (D14), and T13/T14 held in
reserve as queue-independent work. SC 22 measures the real cost so the estimate
stops being a guess after Checkpoint 0.

**R2 — OQ 3 can invalidate D3a and D13.** If the runner images do not supply
Chrome and Edge in a form Playwright's channel lookup finds, four of the
fourteen smoke jobs need an install step, and on Linux that step needs root.
*Mitigation:* T4 ships a throwaway diagnostics job whose entire purpose is to
answer this on all three platforms, before a line of Part A is written. A spec
amendment at T4 costs an hour; the same amendment at T19 costs a checkpoint.

**R3 — T12 is unbounded.** Five engines across the whole smoke suite, including
three M8 surfaces that have never run on anything but Chromium and Firefox. The
divergence count could be three rows or thirty, and thirty changes the shape of
the milestone.
*Mitigation:* three things. T11's machinery lands first, so every skip is
already forced to cost a documented row before there is any pressure to skip.
T5's local sweep produces a *count* before T12 starts, so the size is known
rather than discovered. And the count has a threshold: **more than fifteen
divergence rows means stop and re-scope**, because at that point `engines.md` is
the deliverable and the smoke suite needs restructuring around engine
capabilities rather than engine names — which is a different milestone.

**R4 — The branded browsers move under us.** Chrome and Edge come from the
runner image and update on Google's and Microsoft's schedules. A matrix green
today can go red tomorrow with no commit in between.
*Mitigation:* accepted deliberately (D3a) — that signal is worth having. The
plan's job is only to make such a failure *attributable*: T7's `engine_name`
distinguishes Chrome from bundled Chromium in every test name, and T24's
`engines.md` says out loud that these two jobs test a moving target.

**R5 — A platform fix regresses a working platform.** Every `Sys.iswindows()`
branch is a fork in code that Linux users run today.
*Mitigation:* the full hermetic matrix runs on every push from T4 onward, so
Linux regression is caught in the same run that proves the Windows fix. The
Boundaries rule stands: a branch that cannot be justified in its own commit
message does not land.

**R6 — The scaffold's red is untrustworthy if line endings are in it.**
*Mitigation:* T3 before T4, and T5 does not begin until the scaffold has run
once with `.gitattributes` in place.

**R7 — The usual one, fifth turn: adjacent warts look cheap.** M5–M8 each
recorded this and each was right. Three new engines and two new platforms is a
large surface for "while I'm here".
*Mitigation:* `tasks/m9-api-gaps.md`, opened empty at T1, before any `src/`
change.

---

# Tasks

Sizes: **(S)** under an hour, **(M)** a focused session, **(L)** more than one
session — and, per M6's rule, an (L) that has not shown a green test in a day is
a task that should have been split.

## Phase 0 — the scaffold

### T1 — Open `tasks/m9-api-gaps.md`, empty (S)

- **Acceptance:** the file exists, states it is empty on purpose, and names what
  M9 inherits as *not* gaps — anything already recorded in `m8-api-gaps.md`, and
  the fact that beta/dev channels are a deliberate exclusion rather than a gap.
- **Verify:** committed before any `src/` change.
  `git log --diff-filter=A --format=%H -- tasks/m9-api-gaps.md` precedes the
  first `src/` commit on the branch. **SC 32.**
- **Files:** `tasks/m9-api-gaps.md`

### T2 — Branch, draft PR, and the live platform table (S)

- **Acceptance:** branch `m9-engines-and-platforms`; a draft PR whose
  description carries the table D14 specifies — task, platforms green, platforms
  red — with every row empty at this point. `tasks/plan.md` and `tasks/todo.md`
  rotated to `tasks/m8/` (already done) and M9's committed.
- **Verify:** `gh pr view` shows the draft and the table. The PR predates the
  first `src/` commit. **SC 24** (first half).
- **Files:** `tasks/plan.md`, `tasks/todo.md`, PR description

### T3 — `.gitattributes` (M)

- **Acceptance:** every text file normalised to LF, binary fixtures marked
  binary (D7). Existing tracked files renormalised in one commit that changes
  nothing else, so the diff is legible.
- **Verify:** `git ls-files --eol` reports `w/lf` throughout on Linux;
  `format(".")` and `gen/generate.jl --check` still green. **SC 16** (first
  half). The Windows half is proved at T17.
- **Files:** `.gitattributes`, and whatever renormalisation touches

### T4 — The CI scaffold and the diagnostics job (M)

- **Acceptance:** the hermetic job matrices over `ubuntu-latest`,
  `windows-latest`, `macos-latest` × Julia `1.10`/`1`, running the existing
  suite unchanged — no engine axis, no new smoke job. Alongside it, a
  **throwaway** `diagnostics` job on all three platforms that reports: the
  runner's Chrome and Edge presence and versions, whether the pinned driver's
  channel lookup finds them, the Windows 7z member-filter behaviour on a Node
  `.zip`, and the resulting browser-cache path lengths.
- **Verify:** the run completes. Two platforms are expected red on the hermetic
  job and that is the point. The diagnostics job is green on all three and its
  log answers OQ 1, OQ 3 and OQ 5.
- **Files:** `.github/workflows/CI.yml`
- **Note:** the diagnostics job is deleted at T23. It is scaffolding, and
  scaffolding that ships is technical debt with a job name.

### T5 — `tasks/m9-probe.md`: the answers, and the divergence count (L)

- **Acceptance:** every Open Question answered or explicitly deferred with a
  reason. Specifically: OQ 1, 3, 5 from T4's diagnostics log; OQ 2 and OQ 4 from
  a **local** sweep on Fedora running the full smoke suite against webkit,
  chrome and msedge; OQ 6, 7, 8 marked as needing the smoke legs that do not
  exist yet. The Windows and macOS hermetic failures from T4 are transcribed
  into a numbered list — that list *is* Part B's task content.
- **Verify:** the file exists and is committed before T6. The divergence count
  is stated as a number and checked against R3's threshold of fifteen.
- **Files:** `tasks/m9-probe.md`
- **Note:** if the sweep cannot run Edge on Fedora, say so in the file rather
  than guessing. An unanswerable question answered honestly is worth more than
  a plausible one.

**Checkpoint 0** — the instrument works, the red is captured, and OQ 3 has
either confirmed D3a or amended it.

## Phase 1 — Part A, the engines (Linux)

### T6 — `webkit` on `PlaywrightAPI` (S)

- **Acceptance:** `start_playwright` reads `root.initializer["webkit"]`;
  `PlaywrightAPI` gains the field; the docstring stops saying "Fields `chromium`
  and `firefox`" (D1).
- **Verify:** smoke — `pw.webkit isa BrowserType` and
  `browser_name(pw.webkit) == "webkit"` against the real driver. **SC 1.**
- **Files:** `src/objects.jl`, `src/api/lifecycle.jl`, `test/test_smoke.jl`

### T7 — `Engine`, `engine`, `engine_name`, `launch(::Engine)` (M)

- **Acceptance:** the type and three functions D1a specifies, exported and
  documented. Five names, closed set, `ArgumentError` naming all five otherwise.
  `launch(::Engine)` forwards `channel` for the branded two, omits the key
  entirely for the other three, and lets an explicit `channel` keyword win.
- **Verify:** hermetic, against the fake driver: all five mappings; the error;
  `channel` present-vs-absent asserted **on the wire** in `test_connection.jl`'s
  style, because "omitted" and "null" are different messages; and the override.
  **SC 2, SC 3.**
- **Files:** `src/objects.jl`, `src/api/lifecycle.jl`, `src/Playwright.jl`,
  `test/test_connection.jl`, `docs/src/api.md`

### T8 — `SMOKE_ENGINES` takes a list, and `examples/common.jl` shares it (M)

- **Acceptance:** `PLAYWRIGHT_JL_ENGINE` accepts one name, a comma-separated
  list, or absence (all five); validated against the same closed set with the
  same error (D5). `examples/common.jl` drops its hand-rolled validation and
  uses `engine`. Every smoke engine loop launches via `engine(pw, name)` rather
  than `getfield`.
- **Verify:** hermetic — one name, a list, absence, an unknown name, and an
  empty string. The unknown-name case must **throw**, not yield an empty vector
  that passes by vacuum. **SC 10.**
- **Files:** `test/runtests.jl`, `examples/common.jl`, every `test_smoke*.jl`
  engine loop

### T9 — `install`: `with_deps`, and the branded names (M)

- **Acceptance:** `install(; browsers, with_deps = false)`; `with_deps = true`
  raises `ArgumentError` off Linux before any download (D3).
  `browsers_from_args` accepts `"chrome"` and `"msedge"` and still rejects
  unknown names. A branded name warns once that this is a system-wide install,
  and on Linux that it needs root, **before** invoking the driver (D3a).
  `bin/install.jl` grows `--with-deps`. `DEFAULT_BROWSERS` unchanged.
- **Verify:** hermetic — the command carries `--with-deps`; the off-Linux
  refusal; the warning asserted with `@test_logs` and no install performed; the
  default still exactly two. **SC 7, SC 8, SC 11.**
- **Files:** `src/driver.jl`, `bin/install.jl`, `test/test_driver.jl`

### T10 — The two launch-failure messages (M)

- **Acceptance:** a WebKit launch failing on missing system libraries produces
  an error naming `--with-deps`; a branded launch failing on an absent browser
  produces one naming `bin/install.jl` and the fact that it is a system install
  (D3, D3a). Both wrap the driver's message rather than replacing it.
- **Verify:** hermetic by injecting the driver's message shape, since neither
  failure can be arranged on a machine that has the browsers. The todo table
  records that these were injected rather than observed. **SC 9.**
- **Files:** `src/api/lifecycle.jl`, `src/errors.jl`, `test/test_errors.jl`

### T11 — `skip_engine`, `engines.md`, and the gate that ties them (M)

- **Acceptance:** `skip_engine(name, engine, reason)` logs at `@info` and
  returns a `Bool`. `docs/src/engines.md` exists with the row format D4
  specifies — engine, platform where the platform is what makes it true, what
  differs, what to do instead, upstream link where it is Playwright's. A test
  reads the page and the skip reasons and requires them to agree.
- **Verify:** the gate is watched failing — add a skip with no row and see the
  suite go red, then remove it. A gate not seen failing is decoration. **SC 6.**
- **Files:** `test/test_engines.jl` (new, or `test/runtests.jl` helpers),
  `docs/src/engines.md`, `docs/make.jl`
- **Note:** T11 lands before T12 for the M8 T13-before-T14 reason: the
  machinery that makes skipping expensive must exist before the work that
  creates the temptation.

### T12 — Five engines green on Linux ◆ (L)

- **Acceptance:** the full smoke suite passes with all five engines. Every
  divergence found is a `skip_engine` call with a reason and a matching
  `engines.md` row; every divergence that is *this package's* assumption rather
  than Playwright's goes to `tasks/m9-api-gaps.md` and gets fixed.
- **Verify:** `PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg;
  Pkg.test()'` green locally with no engine filter, and the same on the Linux CI
  legs. Per-engine counts recorded. **SC 5.**
- **Files:** every `test_smoke*.jl`, `docs/src/engines.md`, possibly `src/api/*`
- **Note:** R3's threshold applies here. Fifteen rows is the number at which
  this stops being a task and becomes a conversation.

**Checkpoint A** — SC 1–11. Five engines, one platform. The divergence list is
complete and documented.

## Phase 2 — Part B, the platforms

### T13 — `node_platform` and `node_url`, exhaustively (M)

- **Acceptance:** all six claimed OS/arch pairs asserted, and the unsupported
  cases raise with the offending value in the message.
- **Verify:** hermetic, pure functions, runs everywhere. **SC 13.**
- **Files:** `test/test_driver.jl`
- **Note:** queue-independent. This is the task to pick up while waiting on CI.

### T14 — Path assertions compare paths (M)

- **Acceptance:** no test asserts a *real* filesystem path against a
  `/`-separated literal (D8). Fixture paths that never touch a filesystem are
  left alone — rewriting them is churn with no signal.
- **Verify:** the grep is recorded in the todo table and comes back empty; the
  suite is unchanged and green on Linux. **SC 17.**
- **Files:** `test/test_artifacts.jl`, `test/test_downloads.jl`,
  `test/test_smoke_files.jl`, `test/test_smoke_persistent.jl`, and whatever the
  grep finds
- **Note:** queue-independent, like T13.

### T15 — The driver-assembly job, and the Windows fix (L)

- **Acceptance:** a new `driver` CI job on all three platforms that runs
  `bin/install.jl` for the driver only and asserts `driver_cmd("--version")`
  works — the cheap rung between hermetic and smoke. Whatever T4's diagnostics
  found about the Windows member filter is fixed in `install_driver`, keeping
  extraction member-limited (D9).
- **Verify:** the job is green on all three platforms. **SC 14.**
- **Files:** `.github/workflows/CI.yml`, `src/driver.jl`
- **Note:** if the member filter cannot be made to work member-limited on
  Windows, that is the Ask First D9 names — stop, do not extract the whole
  archive.

### T16 — macOS aarch64 assembly (M)

- **Acceptance:** the driver assembles from
  `node-v24.17.0-darwin-arm64.tar.xz`. First execution of `node_platform`'s
  `arm64` branch.
- **Verify:** T15's `driver` job green on `macos-latest`. **SC 15.**
- **Files:** `src/driver.jl` if anything needs fixing; possibly nothing

### T17 — Hermetic green on three platforms (L)

- **Acceptance:** T5's transcribed failure list is empty. No test skipped on
  Windows or macOS that is not skipped on Linux for a reason D10/D11/D12 already
  names; the Windows orphan-check gate and the branded-engine gate both carry
  their explaining comment (D11).
- **Verify:** six hermetic jobs green. **SC 12, SC 16** (second half).
- **Files:** whatever the list holds; `test/test_smoke.jl` for the D11 gates

**Checkpoint B** — SC 12–17. Three platforms, hermetic and driver-assembly
green. Any red past this point is a browser, not a portability bug.

## Phase 3 — Part C, the matrix

### T18 — The smoke matrix (M)

- **Acceptance:** fourteen smoke jobs — ubuntu ×5, macos ×5, windows ×4 with
  WebKit excluded — `fail-fast: false`, timeouts at 60 minutes (D12, D15).
- **Verify:** the run enumerates exactly fourteen jobs with the right names.
  **SC 19.**
- **Files:** `.github/workflows/CI.yml`

### T19 — Two engine classes: install and cache (M)

- **Acceptance:** bundled-engine jobs install exactly their own engine and cache
  under a key containing it; branded-engine jobs run neither step; the Linux
  WebKit job runs `--with-deps` under `sudo -E`, unconditionally, outside the
  cache-hit gate (D13).
- **Verify:** a **second, fully cached run** in which every job still passes.
  The bug this guards against — a cache that promises more than it holds — only
  appears on a hit, so a single cold run proves nothing. **SC 20, SC 21.**
- **Files:** `.github/workflows/CI.yml`
- **Note:** one task, not two. Splitting the key change from the install change
  publishes a lying cache in between.

### T20 — Windows smoke green, four engines ◆ (L)

- **Acceptance:** chromium, firefox, chrome and msedge green on
  `windows-latest`. Divergences documented per D4 — including any that are
  Windows-specific for an engine that passes elsewhere, which `engines.md`'s row
  format is built to express.
- **Verify:** four jobs green. **SC 18** (first half).
- **Files:** `test/test_smoke*.jl`, `docs/src/engines.md`, possibly `src/`

### T21 — macOS smoke green, five engines ◆ (L)

- **Acceptance:** all five green on `macos-latest`, including the OQ 6 timing
  question — the `expect` retry assertions and the M8 WebSocket tests behaving
  as they do on Linux.
- **Verify:** five jobs green. **SC 18** (second half).
- **Files:** as T20
- **Note:** the queue makes this the slowest task in the milestone regardless of
  how much is actually wrong. Batch the fixes here more than elsewhere, and
  accept the attribution cost D14 normally forbids — recording in the todo table
  that this task deviated from the one-fix-per-push rule and why.

### T22 — Durations, including queue time (S)

- **Acceptance:** wall-clock for all fourteen smoke jobs plus macOS queue time,
  recorded in the todo table. This is the number that decides whether D12's grid
  survives (D15).
- **Verify:** the table is filled from a real run. **SC 22.**
- **Files:** `tasks/todo.md`

### T23 — Undraft, and delete the scaffolding (S)

- **Acceptance:** T4's diagnostics job removed; the examples job confirmed
  unchanged (Linux, two engines); the PR out of draft with its platform table
  complete.
- **Verify:** `gh pr view` shows ready-for-review; the workflow has no
  `diagnostics` job. **SC 23, SC 24** (second half).
- **Files:** `.github/workflows/CI.yml`, PR description

**Checkpoint C** — SC 18–24. **The budget checkpoint.** Fourteen jobs green. If
this slips, the conversation is about which platform or engine to defer, per
Assumption 11.

## Phase 4 — the paperwork

### T24 — Documentation (L)

- **Acceptance:** `engines.md` complete and in the sidebar, saying out loud that
  the branded jobs test a moving target (R4). `getting-started.md`'s "Choosing an
  engine" no longer says WebKit is untested and covers `engine`. `index.md`'s
  not-covered sentence agrees with the README's. `api.md` carries the three new
  names.
- **Verify:** `julia --project=docs docs/make.jl` — zero errors, zero warnings,
  `checkdocs = :exports`, `warnonly = false`, `doctest = true` unchanged.
  **SC 26, SC 30.**
- **Files:** `docs/src/engines.md`, `docs/src/getting-started.md`,
  `docs/src/index.md`, `docs/src/api.md`, `docs/make.jl`

### T25 — README and the not-covered gate (M)

- **Acceptance:** WebKit off the not-covered list, the remaining three still
  individually justified, the platform claim widened from Linux to three, the
  engine list updated everywhere it appears — including that Chrome and Edge are
  channels rather than engines.
- **Verify:** `test_exports.jl`'s not-covered assertion green, with its stale
  fixture updated to a case that is still stale. **SC 29.**
- **Files:** `README.md`, `test/test_exports.jl`

### T26 — Bonnie parity, re-scored (S)

- **Acceptance:** `docs/bonnie-parity.md` gains a "Re-scored by milestone 9"
  section saying whether more engines or more platforms change any row — with a
  reason either way rather than silence.
- **Verify:** the section exists and addresses both axes. **SC 31.**
- **Files:** `docs/bonnie-parity.md`

### T27 — Final verification (M)

- **Acceptance:** per-engine and total counts recorded, hermetic and smoke,
  against M8's 2417 / 3348. `gen/generate.jl --check` green, `src/generated/`
  diff empty from the first commit to the PR head, `format(".")` clean,
  `Project.toml` diff empty. `tasks/m9-api-gaps.md`'s final contents reported.
- **Verify:** the todo table's SC rows are all filled with what was run.
  **SC 25, SC 27, SC 28, SC 32.**
- **Files:** `tasks/todo.md`, `tasks/m9-api-gaps.md`

**Checkpoint D** — SC 25–32. The milestone is reportable.

## Verification Checkpoints

| Checkpoint | Tasks | SC | The question it answers |
|---|---|---|---|
| 0 | T1–T5 | — | Does the instrument work, and is D3a still true? |
| A | T6–T12 | 1–11 | Do five engines work, on the platform we can debug? |
| B | T13–T17 | 12–17 | Is the package portable, before any browser is involved? |
| C | T18–T23 | 18–24 | Does the grid pass, and what does it cost? |
| D | T24–T27 | 25–32 | Can someone else read what we did? |
