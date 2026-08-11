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

- [x] **T1** (S) Open `tasks/m9-api-gaps.md`, empty on purpose. Fifth turn of
      the instrument. Must be committed before the first `src/` change — SC 32
- [x] **T2** (S) Branch `m9-engines-and-platforms`, draft PR, the live platform
      table in its description (D14) — SC 24 (first half)
- [x] **T3** (M) `.gitattributes`; renormalise in one commit that changes
      nothing else (D7) — SC 16 (first half)
- [x] **T4** (M) CI scaffold: hermetic on 3 OS × 2 Julia, existing suite
      unchanged, **expected red**. Plus the throwaway `diagnostics` job
      answering OQ 1, 3, 5 on all three platforms
- [x] **T5** (L) `tasks/m9-probe.md`: every OQ answered or deferred with a
      reason; the local five-engine sweep on Fedora (OQ 2, 4); T4's red
      transcribed into a numbered list — that list is Part B's content. **State
      the divergence count as a number** and check it against R3

**Checkpoint 0** — the instrument works, the red is captured, and OQ 3 has
either confirmed D3a or amended it. **If OQ 3 comes back wrong, stop and amend
the spec** — D3a and D13 both fall, and that is an hour's work here against a
checkpoint's at T19 (R2).

## Phase 1: Part A — the engines (Linux)

- [x] **T6** (S) `webkit` on `PlaywrightAPI`; the docstring stops saying two
      (D1) — SC 1
- [x] **T7** (M) `Engine`, `engine`, `engine_name`, `launch(::Engine)`; five
      names, closed set; `channel` present-vs-absent **on the wire** (D1a) —
      SC 2, 3
- [x] **T8** (M) `SMOKE_ENGINES` takes a comma list; `examples/common.jl` shares
      the validation; engine loops stop using `getfield` (D5) — SC 10
- [x] **T9** (M) `install`: `with_deps`, the branded names, the system-install
      warning before the driver runs (D3, D3a) — SC 7, 8, 11
- [x] **T10** (M) The two launch-failure messages, injected rather than observed
      (D3, D3a) — SC 9
- [x] **T11** (M) `skip_engine`, `docs/src/engines.md`, and the gate that makes
      them agree — **watched failing** (D4) — SC 6
- [ ] **T12** ◆ (L) Five engines green on Linux; every divergence a skip *and* a
      row; package-side assumptions to `m9-api-gaps.md` and fixed — SC 5

**Checkpoint A** — SC 1–11. Five engines, one platform, on the machine where a
failure can actually be debugged.

## Phase 2: Part B — the platforms

- [x] **T13** (M) `node_platform` / `node_url` for all six claimed OS/arch
      pairs; unsupported cases name the value — SC 13 *(queue-independent)*
- [x] **T14** (M) Real filesystem paths asserted with `basename`/`joinpath`,
      never a `/`-separated literal (D8) — SC 17 *(queue-independent)*
- [x] **T15** (L) The `driver` CI job on 3 OS — the cheap rung between hermetic
      and smoke — plus the Windows member-filter fix, still member-limited
      (D9) — SC 14
- [x] **T16** (M) macOS aarch64 assembly; first run of the `arm64` branch — SC 15
- [ ] **T17** (L) T5's failure list emptied; the D11 gates carry their
      explaining comment — SC 12, 16 (second half)

**Checkpoint B** — SC 12–17. Any red past here is a browser, not a portability
bug. That distinction is the whole reason this phase exists separately.

## Phase 3: Part C — the matrix

- [x] **T18** (M) Fourteen smoke jobs: ubuntu ×5, macos ×5, windows ×4 (no
      WebKit), `fail-fast: false`, 60-minute timeouts (D12, D15) — SC 19
- [x] **T19** (M) Two engine classes: bundled installs one engine and caches per
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

- [x] **T24** (L) `engines.md` complete and in the sidebar; getting-started,
      index, api.md — SC 26, 30
- [x] **T25** (M) README: WebKit off the not-covered list, three platforms
      claimed, Chrome and Edge named as channels; the stale fixture updated to a
      case that is still stale — SC 29
- [x] **T26** (S) `docs/bonnie-parity.md` re-scored by M9, both axes, with a
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
| 1 | `browser_name(pw.webkit) == "webkit"` against the real driver, test_smoke.jl. Green on all smoke jobs. |
| 2 | `test_connection.jl` "engines" testset, hermetic against the fake driver: all five mappings, and `ArgumentError` naming all five for `edge`, `Chrome`, `""`. |
| 3 | Wire assertions in the same testset: no `channel` key at all for chromium/firefox/webkit, `channel == name` for chrome/msedge, and an explicit keyword overriding both. |
| 4 | `test_fixtures.jl` "browser_name on a running Browser": `engine_name(bt) == eng` while `browser_name(browser) == "chromium"` for chrome and msedge, asserted as an inequality. |
| 5 | Run 31451533031: all five `ubuntu-latest` smoke jobs green — chromium, firefox, webkit, chrome, msedge. WebKit's first run anywhere. |
| 6 | `test_engines.jl`. **Watched failing**: an invented reason added to test_smoke_har.jl reddened the suite naming the file, engine and unmatched words; then removed. |
| 7 | `Playwright.install_args(["webkit"], true) == ["install", "--with-deps", "webkit"]`, and `check_with_deps(true, :windows)` / `(true, :macos)` throw. Asserted on the command, never run. |
| 8 | `warn_branded_install` under `Test.collect_test_logs`, for chrome and msedge, on `:linux` (says root) and `:macos`. No install performed. Bundled names log nothing. |
| 9 | **Injected, not observed** — neither failure can be arranged on a machine that has the browsers. The message shapes are copied from a real driver: the missing-dependency banner came out of the Fedora sweep. |
| 10 | `parse_engine_names`: one name, a list, spaces, blank (= all five); and `edge`/`safari`/`Chrome`/`chromium,safari`/`chromium,` all throw naming all five. |
| 11 | `DEFAULT_BROWSERS == ["chromium", "firefox"]`, asserted directly, and the README's install section unchanged. |
| 12 | Run 31451533031: all six hermetic jobs green (ubuntu/windows/macos x 1.10/1). macOS was green from the very first scaffold run; Windows needed one fix (test_har.jl:454). |
| 13 | `test_driver.jl`: all six OS/arch pairs for both `node_platform` and `node_url`, plus `i686` and `plan9` naming the offending value. No src change was needed. |
| 14 | `Driver assembly (windows-latest)` green: `contents=.complete, node.exe, package` and `Version 1.61.1`. The member filter matched a forward-slashed path unchanged (OQ 1). |
| 15 | `Driver assembly (macos-latest)` green from `node-v24.17.0-darwin-arm64.tar.xz`. First execution of node_platform's arm64 branch; nothing needed fixing. |
| 16 | `.gitattributes` committed before the scaffold. `git ls-files --eol` is `w/lf` throughout on Linux. Renormalisation touched exactly one tracked file (protocol/LICENSE-PLAYWRIGHT, CRLF). |
| 17 | `grep -rnE '@test.*"[^"]*/[^"]*"' test/*.jl` — remaining hits are wire params handed to the fake driver and comment text in generated source, neither of which touches a filesystem. |
| 18 | macOS **5/5 green**. Windows chromium and chrome green; firefox and msedge blocked on a GitHub runner network fault, not on this package — see the note below. |
| 19 | `yaml.safe_load` over CI.yml enumerates exactly 14 smoke jobs after the WebKit-on-Windows exclude, `fail-fast: false`, and the hermetic job at 3 OS x 2 Julia. |
| 20 | Run 31451533031, a fully cached run: `Cache restored from key: playwright-Linux-webkit-pw1.61.1-node24.17.0`, `playwright-macOS-firefox-…`, `playwright-Linux-chromium-…` — per-engine keys, restored, and every job still passed. The branded jobs have no cache step at all. |
| 21 | Same run: the Linux WebKit job logs `Installing Playwright browsers` *after* a cache hit, because the `--with-deps` step sits outside the cache-hit gate. System packages are not in the workspace and a hit still needs them. |
| 22 | Fourteen durations plus queue time recorded below, from run 31443812400 (cold). Worst macOS queue 3m19s; slowest job Windows Firefox at 12m48s against a 60-minute timeout. |
| 23 | The `diagnostics` job is deleted — it answered OQ 1, 3 and 5 and its work is done. The examples job is untouched: `ubuntu-latest`, engines `[chromium, firefox]`, verified by parsing the workflow. |
| 24 | PR #9 opened draft before the first `src/` change — `git log` puts the m9-api-gaps commit and the PR ahead of the webkit field. Carries the platform table. |
| 25 | Per engine and in total below, from run 31446202297. |
| 26 | `julia --project=docs docs/make.jl`: zero errors, zero warnings, with checkdocs = :exports, warnonly = false, doctest = true all unchanged. engines.md is in the sidebar. |
| 27 | `gen/generate.jl --check` green locally and in CI on every push; `format(".")` returns true. |
| 28 | `git diff <first commit>..HEAD -- Project.toml` is empty. (CI briefly rewrote it as root under the broken sudo step — that was in the runner's workspace, never committed, and is fixed.) |
| 29 | README rewritten; `test_exports.jl`'s not-covered gate green, with its stale fixture given a "WebKit" claim so it is still testing a case that is stale. |
| 30 | getting-started's "Choosing an engine" rewritten for five engines; index.md's not-covered sentence agrees with the README's. |
| 31 | `tasks/bonnie-parity.md` gains "Re-scored by milestone 9": no row changes, with the reason on both axes. |
| 32 | `git log --diff-filter=A -- tasks/m9-api-gaps.md` is commit 1 on the branch; the first src/ commit is 5th. |

## The platform table

Mirrors the PR description (D14). This is what makes the state of fourteen jobs
legible without opening fourteen logs.

| Task | Linux | Windows | macOS |
|---|---|---|---|
| T4 scaffold (hermetic, existing suite) | green | 1 failure | green |
| T15 driver assembly | green | green | green |
| T17 hermetic | green | green | green |
| T20/T21 smoke | in progress | in progress | in progress |

## Job durations (T22, SC 22)

The number that decides whether D12's grid survives. macOS queue time is
recorded separately from run time because they have different causes and
different fixes.

| OS | Engine | Run | Queue |
|---|---|---|---|
| ubuntu | chromium | 3m27s | 1s |
| ubuntu | firefox | 6m20s | 7s |
| ubuntu | webkit | 6m57s | 1s |
| ubuntu | chrome | 4m25s | 0s |
| ubuntu | msedge | 5m48s | 0s |
| windows | chromium | 7m11s | 1s |
| windows | firefox | 12m48s | 0s |
| windows | chrome | 7m37s | 2s |
| windows | msedge | 8m25s | 0s |
| macos | chromium | 2m55s | 49s |
| macos | firefox | 6m58s | 1s |
| macos | webkit | 5m54s | **3m19s** |
| macos | chrome | 5m40s | 27s |
| macos | msedge | 7m26s | 1s |

Measured on run 31443812400, a cold run with no browser cache. Queue is
measured from the earliest job start in the run.

**D12's grid survives, and R1 was pessimistic.** The fear was that GitHub's
macOS concurrency cap would serialise five macOS smoke jobs plus two macOS
hermetic ones, costing a day per iteration. It did not: every one of the
fourteen started within 3m19s of the first, and the worst macOS queue was that
same 3m19s. Total wall clock for the whole matrix is bounded by the slowest
single job, not by a queue.

The slowest job is Windows Firefox at 12m48s, comfortably inside D15's 60
minutes — which is doing its job as a hang detector rather than as a budget.
Nothing here argues for trimming the matrix (Assumption 11), so nothing is
trimmed.

## Suite counts (T27, SC 25)

M8 recorded 2417 hermetic / 3348 smoke on two engines. The smoke number moves
for a reason that is not new coverage — five engines multiplying existing
testsets — so it is recorded per engine as well as in total, or it means
nothing.

Passing assertions per engine, `ubuntu-latest`, run 31446202297:

| | chromium | firefox | webkit | chrome | msedge | total |
|---|---|---|---|---|---|---|
| smoke | 3057 | 3061 | 3002 | 3051 | 3051 | 15222 |

Hermetic (engine-independent): **2591**, up from M8's 2417. The 174 new
assertions are the `engines` testset (83), the `node_platform`/`node_url`
sweep, `install`'s `with_deps` and branded-name behaviour, the two launch
failure messages, and `test_engines.jl`'s documentation gate.

**Reading the smoke numbers.** These are not comparable to M8's 3348 and
should not be read as a regression. M8's figure was one run of a two-engine
loop; each column here is a whole-suite run against one engine, so the
per-engine number is the like-for-like one. It sits a little above M8's
because the engine-metadata and parity testsets gained assertions, and the
spread between columns is the divergence count made visible:

- webkit is ~55 below chromium — the four skipped download assertions, the
  unreachable-host assertion, and the two `args` testsets.
- chrome and msedge sit 6 below chromium — the console-event skip.
- firefox is slightly above chromium, which is the `firefox_user_prefs` leg.

Every gap is accounted for by a row in `docs/src/engines.md`. A column that
dropped for a reason not on that page would be the thing to worry about.
