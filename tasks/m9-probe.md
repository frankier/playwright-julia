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

**Divergence count so far: 1.** R3's threshold is fifteen. Two more rows are
already on the page from decisions rather than discovery (WebKit-on-Windows,
and the orphan-process check's blind spots), which is still nowhere near the
number at which this stops being a task and becomes a conversation.

The count is *incomplete* — webkit and msedge contribute an unknown number,
and the M8 surfaces (HAR replay, persistent contexts, WebSocket routing) have
still never seen a third engine. Those come from the CI matrix.

### A note on the two failures that were not real

Two runs of the sweep were done in parallel in the same checkout, and both
reported failures in `test_codegen.jl` and `test_driver.jl`. Neither was real:
`test_codegen.jl` tampers with a generated file and restores it, so two suites
in one working directory race on it, and `test_driver.jl` was being edited
while chrome's run read it. Recorded because a future reader finding those
lines in the logs deserves to know they were an artefact of how the sweep was
run, not a finding. **The sweep is a serial operation.**

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

**Not answered in the first run — my bug — and re-running.**

The two steps that measure it both threw `UndefVarError`: a `for` at top level
in `julia -e` is soft scope, so assigning the accumulator inside the loop
warned and then failed. The other diagnostics steps were written `if:
always()` and answered OQ 1 and OQ 3 regardless, which is the only reason this
cost nothing.

What is already known from the OQ 1 output: the driver directory on Windows is
109 characters
(`C:\Users\runneradmin\.julia\scratchspaces\<uuid>\driver-1.61.1-node-24.17.0`),
leaving roughly 150 for everything Playwright nests beneath the browser root.
Suspicion remains "fine", now with one real number under it.

## OQ 6 — Do headless Firefox and WebKit behave on macOS the way they do on Linux?

**Open.** Needs the macOS smoke legs, which is Part C. Nothing in the hermetic
or diagnostics results speaks to it.

Encouraging but not evidence: macOS hermetic was green on both Julia versions
in the very first run, and the macOS driver assembly worked first time.

## OQ 7 — Is `sudo -E` enough for `--with-deps` on the GitHub Linux runner?

**Open.** Needs the Linux WebKit smoke job. Untestable anywhere else.

## OQ 8 — How much macOS queue time does the grid cost?

**Open, but the first data point is mild.** In the T4 run, the six hermetic
jobs across three platforms all completed inside a few minutes with no visible
macOS queueing. That is two macOS jobs, not seven, so it does not settle D12 —
but it does not look like the catastrophe R1 budgets for either. T22 records
the real numbers.

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
