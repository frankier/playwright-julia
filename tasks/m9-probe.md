# M9 probe: the answers

What `SPEC-M9.md`'s Open Questions turned out to be, and the failure list the
T4 scaffold produced. Written from three sources: the throwaway `diagnostics`
CI job on all three platforms, a local five-engine sweep on Fedora, and the
first three-platform hermetic run.

**One honesty note about ordering.** The plan puts this file before Part A.
In practice T6–T12 were written while the first CI runs were in flight, and
this file was completed afterwards from the logs of the run that T4 triggered.
The *data* below all predates the fixes it describes — the scaffold's red was
captured before anything was changed — but the file itself was not committed
before Part A's first line, and saying so is cheaper than pretending.

---

## OQ 1 — Does 7z's member filter match a forward-slashed path inside a `.zip` on Windows?

**Yes. No fix needed, and D9's contingency is not exercised.**

The `diagnostics` job on `windows-latest` assembled the driver from
`node-v24.17.0-win-x64.zip` with the member filter unchanged:

```
node_platform=win-x64
driver_dir=C:\Users\runneradmin\.julia\scratchspaces\…\driver-1.61.1-node-24.17.0
contents=.complete, node.exe, package
Version 1.61.1
```

`node.exe` came out of the archive with the filter written as
`node-v24.17.0-win-x64/node.exe`, forward slash and all, and `driver_cmd
("--version")` ran. p7zip normalises separators internally.

This was the milestone's most likely Windows blocker and it does not exist.
**T15's "Windows member-filter fix" is therefore a no-op**, and T15 reduces to
adding the driver-assembly CI job.

## OQ 2 — Which smoke testsets diverge across the five engines?

**Partially answered. The count is small, and it is not the number R3 was
worried about.**

Answered locally for chromium, firefox and chrome. **Not answerable locally for
webkit or msedge** — see OQ 4 and the note below.

| Engine | Result of the local sweep |
|---|---|
| chromium | green (baseline) |
| firefox | green (baseline) |
| chrome | 3005 tests, 10 failures — **all but one a test bug, not a divergence** |
| webkit | could not launch at all on Fedora (OQ 4) |
| msedge | not installable on Fedora; no Edge build for this distribution |

Chrome's failures resolve into three groups:

1. **Four sites asserting `browser_name(browser) == eng`.** False for chrome
   and msedge, which report `"chromium"`. This is the exact confusion D1a
   predicted and named in advance. A test bug, fixed, and now asserted the
   other way round as SC 4.
2. **The `pdf` testsets branching on `eng == "chromium"`**, expecting chrome to
   *refuse*. It does not, and should not: `pdf` is a Chromium-family
   capability, the package's own gate reads `browser_name`, and the test was
   asking a different question from the code. A test bug, fixed.
3. **One genuine divergence.** `expect_event(ctx, :console; timeout = 1_000)`
   with an empty block is expected to time out. On Chrome it does not — the
   branded build emits console messages of its own with no page doing anything.
   Skipped on chrome with an `engines.md` row.

**Divergence count after the first full matrix: 4 skips**, against R3's
threshold of fifteen. Two further `engines.md` rows come from decisions rather
than discovery (WebKit-on-Windows, and the orphan-process check's blind spots),
so the page has six rows in total — nowhere near the number at which this stops
being a task and becomes a conversation.

Worth stating plainly, because it was the milestone's largest unknown: **the
M8 surfaces held.** HAR replay, persistent contexts and WebSocket routing had
never seen a third engine, let alone a branded one, and none of them produced
a single divergence on any of the five.

### A note on the two failures that were not real

Two runs of the sweep were done in parallel in the same checkout, and both
reported failures in `test_codegen.jl` and `test_driver.jl`. Neither was real:
`test_codegen.jl` tampers with a generated file and restores it, so two suites
in one working directory race on it, and `test_driver.jl` was being edited
while chrome's run read it. Recorded because a future reader finding those
lines in the logs deserves to know they were an artefact of how the sweep was
run, not a finding. **The sweep is a serial operation.**

### Continued: what the matrix added

WebKit's first run anywhere held 3023 of 3030 assertions on Linux and 3039 of
3042 on macOS. Three genuine divergences, all new, all documented:

1. **It rejects unknown command-line args instead of ignoring them.** This
   *falsifies a claim the suite was written to assert* — that
   engine-irrelevant launch options are ignored rather than rejected. True for
   the other four; WebKit exits on a Chromium flag it does not recognise. The
   claim is still tested on four engines and WebKit's exception is documented,
   which is exactly the case D4 exists for.
2. **It resolves an unreachable host instead of raising.** A closed port on
   localhost comes back as something WebKit will hand over.
3. **Headless, it emits no `:download` event** for a `Content-Disposition`
   attachment. All four download assertions waited out their budget.

One more failure was *not* a divergence: Windows Firefox failed the cascade
test because that test set a 1s context default and then navigated, so `goto!`
inherited the budget it was setting up. A cold Firefox on Windows takes longer
than a second to load a page off localhost. A test bug, and platform-agnostic
once fixed.

**Left deliberately unskipped:** an intermittent WebKit segfault at launch on
macOS aarch64 — two crashes in a full run, both immediately after `<launched>`,
in unrelated testsets. Skipping for flakiness would hide real coverage, so it
goes back through CI to find out whether it is deterministic before anything is
decided about it.

## OQ 3 — Which branded browsers do the runner images ship, and does the channel lookup find them?

**All three images ship both, and the pinned driver's channel lookup finds all
six combinations. D3a stands unamended, and D13 with it.**

This was the highest-leverage question in the list — a wrong answer would have
invalidated a decision rather than costing a fix (R2). It came back right.

| Runner | Chrome | Edge | Launched via `channel` |
|---|---|---|---|
| `ubuntu-latest` | `/usr/bin/google-chrome`, `/opt/google/chrome/chrome` | `/usr/bin/microsoft-edge`, `/opt/microsoft/msedge/msedge` | chrome 150.0.7871.128, msedge 150.0.4078.83 |
| `windows-latest` | `C:\Program Files\Google\Chrome\Application\chrome.exe` | `C:\Program Files (x86)\Microsoft\Edge\Application\msedge.exe` | chrome 151.0.7922.72, msedge 151.0.4129.59 |
| `macos-latest` | `/Applications/Google Chrome.app` | `/Applications/Microsoft Edge.app` | chrome 150.0.7871.187, msedge 150.0.4078.105 |

Every one launched headless and reported `browser_name == "chromium"`,
confirming both halves of D1a at once.

Note the versions already differ across platforms in the same run, and Windows
is a major version ahead. That is R4 in the wild on day one, and it is the
reason `engines.md` says out loud that these two jobs test a moving target.

**Consequence:** the four branded smoke jobs need no install step and no
browser cache, exactly as D13 specifies.

## OQ 4 — Does WebKit launch on a stock runner after a plain `install webkit`?

**On Fedora: no, and `--with-deps` cannot help there either.**

The local sweep installed webkit successfully and then failed to launch it, 95
times, all with one root cause:

```
╔══════════════════════════════════════════════════════╗
║ Host system is missing dependencies to run browsers. ║
║ Please install them with the following command:      ║
║                                                      ║
║     sudo playwright install-deps                     ║
╚══════════════════════════════════════════════════════╝
```

So SC 9's error-message work is **not a nicety** — it is the difference between
that message and a user knowing what to type. That is now what the error says.

The Fedora part is worse than D3 anticipated: `install-deps` is Debian/Ubuntu
only, and the driver says as much ("your OS is not officially supported by
Playwright"). `--with-deps` on Fedora has nothing to install. **This package's
WebKit testing therefore happens on Ubuntu CI, not on the maintainer's
workstation**, and that is a permanent property of this repository rather than
a temporary state. `engines.md` says so.

No system packages were installed on the developer's machine to work around
this. Doing so to make a local run go green would have been an unreviewable
change to someone's workstation in service of a test.

**Still open:** whether `ubuntu-latest` + `--with-deps` is sufficient. It is
what D3 predicts and what the Linux WebKit smoke job will prove or disprove.

## OQ 5 — What does a Windows browser cache path cost?

**Comfortably under the limit. Suspicion confirmed, with numbers.**

The first run's two measuring steps threw `UndefVarError` — a `for` at top
level in `julia -e` is soft scope, so assigning the accumulator inside the loop
warned and then failed. My bug. The other steps were written `if: always()` and
answered OQ 1 and OQ 3 regardless, which is the only reason it cost nothing.
Re-run:

| Path | Length | Limit |
|---|---|---|
| Driver scratch directory | 105 | — |
| Deepest file in the driver bundle | 174 | 260 |
| Browser root (`${workspace}/.playwright`) | 50 | — |
| Deepest file under a browser install | 176 | 260 |

The deepest of either is 176 characters, leaving 84 to spare. Note the driver's
own deepest path is a vendored Markdown file inside `playwright-core`, not
anything this package creates — so the margin is not something a change here
would erode.

## OQ 6 — Do headless Firefox and WebKit behave on macOS the way they do on Linux?

**Firefox: yes, entirely. WebKit: yes apart from an intermittent launch
segfault.**

macOS Firefox was green on the first full matrix run, timing-sensitive parts
included — the `expect` retry assertions and the M8 WebSocket tests all held
with no macOS-specific adjustment. That was the specific worry and it did not
materialise. macOS Chromium, Chrome and Edge were green too.

macOS WebKit held 3039 of 3042. Its three failures were the download and
unreachable-host divergences it also shows on Linux, plus the segfault noted
above — no *timing* divergence at all.

## OQ 7 — Is `sudo -E` enough for `--with-deps` on the GitHub Linux runner?

**Yes, as a single step, exactly as D13 specifies.**

`sudo -E julia bin/install.jl --with-deps webkit` ran as its own step, outside
the cache-hit gate, and the Linux WebKit job then launched the browser and ran
3030 assertions. `-E` preserved enough environment for the depot and the
assembled driver to be found; no separate non-Julia invocation was needed.

This is the five-minute question with a day-shaped answer if discovered late,
and the answer is the cheap one.

## OQ 8 — How much macOS queue time does the grid cost?

**About three minutes, worst case. R1 was pessimistic and D12's grid
survives.**

On a full fourteen-job cold run, every job started within **3m19s** of the
first, and that worst case was macOS WebKit. There was no serialisation of the
five macOS smoke jobs — GitHub ran them concurrently.

The slowest single job is Windows Firefox at 12m48s, so the matrix's wall clock
is bounded by that rather than by a queue. Full table in
[`todo.md`](todo.md#job-durations-t22-sc-22).

The practical constraint turned out to be something the spec did not anticipate
at all: `cancel-in-progress` in the workflow's concurrency group means each
push kills the run in flight. With a fourteen-job matrix that is a real cost,
and it argues for batching pushes more than D14's one-fix-per-push rule
suggests — the attribution D14 wants comes from the commit, not from the run.

---

## The T4 scaffold's failure list — Part B's task content

The hermetic suite, existing and unchanged, on three platforms × two Julia
versions. **This is the list T17 has to empty.**

| Platform | Result |
|---|---|
| `ubuntu-latest` 1.10 | green |
| `ubuntu-latest` 1 | green |
| `macos-latest` 1.10 | **green** |
| `macos-latest` 1 | **green** |
| `windows-latest` 1.10 | 2391 pass, **1 fail** |
| `windows-latest` 1 | 1 fail (same) |

**The whole list is one item.**

1. `test_har.jl:454` — `occursin(abspath(HAR_FIXTURE), text)` where `text` came
   from `string(warnings[1].kwargs)`. Rendering a `Base.Pairs` shows String
   values with `repr`, which escapes backslashes, so the assertion compared
   `D:\a\...\api.har` against `D:\\a\\...\\api.har`. Pure D8. Fixed by
   comparing the kwarg *values* rather than searching a rendered string, which
   is the stronger assertion anyway.

That is the entire portability debt this package had accumulated over eight
milestones, and macOS had none at all. Two things paid for that:
`.gitattributes` landing before the scaffold, so none of this was line-ending
noise (R6), and the suite's existing habit of building paths with `joinpath`.

The D8 grep across `test/` afterwards comes back with no real-path literals —
the remaining hits are wire params handed to the fake driver and comment text
in generated source, neither of which touches a filesystem.
