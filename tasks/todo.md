# TODO: Playwright.jl — Milestone 9 (five engines and three platforms)

Spec: `SPEC-M9.md`. See `tasks/plan.md` for full task descriptions, acceptance
criteria, and verification steps. Milestones 1–8 are archived under `tasks/m1/`
… `tasks/m8/`. The spec-phase probe findings go in `tasks/m9-probe.md` (T5).

Sizes: (S) small, (M) medium, (L) large. ◆ marks the three tasks whose size is
not knowable in advance.

**The rule for Phase 0:** `.gitattributes` (T3) lands *before* the CI scaffold
(T4). A Windows checkout without it rewrites every text file, and the scaffold's
whole value is that its red list is trustworthy rather than a mixture of real
portability bugs and line-ending noise (R6).

**The rule for Part A:** T11 before T12. The machinery that makes a skip cost a
documented row exists *before* the work that creates the temptation to skip.
Same shape as M8's T13-before-T14 rule (D4).

**The rule for Part B:** climb the rungs in order — hermetic, then driver
assembly, then smoke. A failure found at the wrong rung costs ten times what it
should, and on macOS it costs the queue as well (D6, R1).

**The rule for Part C:** T19 is one task, not two. Splitting the cache key from
the install step publishes a cache that promises more than it holds, which is
exactly the bug D13 exists to prevent — and it only shows up on a cache *hit*,
so T19 is verified by a second, fully cached run.

**The tripwire, all parts:** a skip with no `engines.md` row is not a skip, it
is a hidden failure. If a test goes quiet on an engine and nobody can say why in
one sentence, that is a bug in this package until proven otherwise.

**Checkpoint C is the budget checkpoint.** If it lands late, that is when to ask
about deferring a platform or an engine — not at T21 (R1, Assumption 11).

**R3's threshold:** more than **fifteen** divergence rows in `engines.md` means
stop and re-scope. At that point the page is the deliverable and the smoke suite
wants restructuring around engine capabilities rather than engine names, which
is a different milestone.

## Phase 0: the scaffold

- [ ] **T1** (S) Open `tasks/m9-api-gaps.md`, empty on purpose. Fifth turn of
      the instrument. Must be committed before the first `src/` change — SC 32
- [ ] **T2** (S) Branch `m9-engines-and-platforms`, draft PR, the live platform
      table in its description (D14) — SC 24 (first half)
- [ ] **T3** (M) `.gitattributes`; renormalise in one commit that changes
      nothing else (D7) — SC 16 (first half)
- [ ] **T4** (M) CI scaffold: hermetic on 3 OS × 2 Julia, existing suite
      unchanged, **expected red**. Plus the throwaway `diagnostics` job
      answering OQ 1, 3, 5 on all three platforms
- [ ] **T5** (L) `tasks/m9-probe.md`: every OQ answered or deferred with a
      reason; the local five-engine sweep on Fedora (OQ 2, 4); T4's red
      transcribed into a numbered list — that list is Part B's content. **State
      the divergence count as a number** and check it against R3

**Checkpoint 0** — the instrument works, the red is captured, and OQ 3 has
either confirmed D3a or amended it. **If OQ 3 comes back wrong, stop and amend
the spec** — D3a and D13 both fall, and that is an hour's work here against a
checkpoint's at T19 (R2).

## Phase 1: Part A — the engines (Linux)

- [ ] **T6** (S) `webkit` on `PlaywrightAPI`; the docstring stops saying two
      (D1) — SC 1
- [ ] **T7** (M) `Engine`, `engine`, `engine_name`, `launch(::Engine)`; five
      names, closed set; `channel` present-vs-absent **on the wire** (D1a) —
      SC 2, 3
- [ ] **T8** (M) `SMOKE_ENGINES` takes a comma list; `examples/common.jl` shares
      the validation; engine loops stop using `getfield` (D5) — SC 10
- [ ] **T9** (M) `install`: `with_deps`, the branded names, the system-install
      warning before the driver runs (D3, D3a) — SC 7, 8, 11
- [ ] **T10** (M) The two launch-failure messages, injected rather than observed
      (D3, D3a) — SC 9
- [ ] **T11** (M) `skip_engine`, `docs/src/engines.md`, and the gate that makes
      them agree — **watched failing** (D4) — SC 6
- [ ] **T12** ◆ (L) Five engines green on Linux; every divergence a skip *and* a
      row; package-side assumptions to `m9-api-gaps.md` and fixed — SC 5

**Checkpoint A** — SC 1–11. Five engines, one platform, on the machine where a
failure can actually be debugged.

## Phase 2: Part B — the platforms

- [ ] **T13** (M) `node_platform` / `node_url` for all six claimed OS/arch
      pairs; unsupported cases name the value — SC 13 *(queue-independent)*
- [ ] **T14** (M) Real filesystem paths asserted with `basename`/`joinpath`,
      never a `/`-separated literal (D8) — SC 17 *(queue-independent)*
- [ ] **T15** (L) The `driver` CI job on 3 OS — the cheap rung between hermetic
      and smoke — plus the Windows member-filter fix, still member-limited
      (D9) — SC 14
- [ ] **T16** (M) macOS aarch64 assembly; first run of the `arm64` branch — SC 15
- [ ] **T17** (L) T5's failure list emptied; the D11 gates carry their
      explaining comment — SC 12, 16 (second half)

**Checkpoint B** — SC 12–17. Any red past here is a browser, not a portability
bug. That distinction is the whole reason this phase exists separately.

## Phase 3: Part C — the matrix

- [ ] **T18** (M) Fourteen smoke jobs: ubuntu ×5, macos ×5, windows ×4 (no
      WebKit), `fail-fast: false`, 60-minute timeouts (D12, D15) — SC 19
- [ ] **T19** (M) Two engine classes: bundled installs one engine and caches per
      engine; branded does neither; Linux WebKit runs `--with-deps` under
      `sudo -E` outside the cache gate (D13). **Verified by a second, fully
      cached run** — SC 20, 21
- [ ] **T20** ◆ (L) Windows smoke green, four engines — SC 18 (first half)
- [ ] **T21** ◆ (L) macOS smoke green, five engines, including OQ 6's timing
      question — SC 18 (second half)
- [ ] **T22** (S) All fourteen durations **including macOS queue time**, into
      the table below (D15) — SC 22
- [ ] **T23** (S) Delete the `diagnostics` job; examples job confirmed
      unchanged; PR out of draft — SC 23, 24 (second half)

**Checkpoint C** — SC 18–24. **The budget checkpoint.**

## Phase 4: the paperwork

- [ ] **T24** (L) `engines.md` complete and in the sidebar; getting-started,
      index, api.md — SC 26, 30
- [ ] **T25** (M) README: WebKit off the not-covered list, three platforms
      claimed, Chrome and Edge named as channels; the stale fixture updated to a
      case that is still stale — SC 29
- [ ] **T26** (S) `docs/bonnie-parity.md` re-scored by M9, both axes, with a
      reason either way — SC 31
- [ ] **T27** (M) Counts per engine and total; codegen, format, `Project.toml`,
      gaps file — SC 25, 27, 28, 32

**Checkpoint D** — SC 25–32.

---

## Success criteria

Filled in as each lands, with **what was run**, not what was intended. The M5–M8
discipline: a criterion that cannot be met says so rather than being reworded
until it passes.

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
| 31 | |
| 32 | |

## The platform table

Mirrors the PR description (D14). This is what makes the state of fourteen jobs
legible without opening fourteen logs.

| Task | Linux | Windows | macOS |
|---|---|---|---|
| T4 scaffold | | | |
| T15 driver | | | |
| T17 hermetic | | | |
| T20/T21 smoke | | | |

## Job durations (T22, SC 22)

The number that decides whether D12's grid survives. macOS queue time is
recorded separately from run time because they have different causes and
different fixes.

| OS | Engine | Run | Queue |
|---|---|---|---|
| ubuntu | chromium | | |
| ubuntu | firefox | | |
| ubuntu | webkit | | |
| ubuntu | chrome | | |
| ubuntu | msedge | | |
| windows | chromium | | |
| windows | firefox | | |
| windows | chrome | | |
| windows | msedge | | |
| macos | chromium | | |
| macos | firefox | | |
| macos | webkit | | |
| macos | chrome | | |
| macos | msedge | | |

## Suite counts (T27, SC 25)

M8 recorded 2417 hermetic / 3348 smoke on two engines. The smoke number will
jump for a reason that is not new coverage — five engines multiplying existing
testsets — so it is recorded per engine as well as in total, or it means
nothing.

| | chromium | firefox | webkit | chrome | msedge | total |
|---|---|---|---|---|---|---|
| smoke | | | | | | |

Hermetic (engine-independent): _____
