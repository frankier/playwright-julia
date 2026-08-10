# Spec: Playwright.jl — Milestone 9 (five engines and three platforms)

Successor to [`SPEC.md`](SPEC.md) (M1), [`SPEC-M2.md`](SPEC-M2.md),
[`SPEC-M3.md`](SPEC-M3.md), [`SPEC-M4.md`](SPEC-M4.md),
[`SPEC-M5.md`](SPEC-M5.md), [`SPEC-M6.md`](SPEC-M6.md),
[`SPEC-M7.md`](SPEC-M7.md) and [`SPEC-M8.md`](SPEC-M8.md), all eight complete.
Tech stack, driver architecture, the codegen/API split, code style, testing
layout and boundaries carry over unchanged unless contradicted here.

M9 clears the first entry on the README's not-covered list and widens the
support claim from one engine-pair on one platform to five engines on three
platforms, in three parts:

- **Part A — the engines.** `pw.webkit` becomes a launchable engine, and the
  branded Chromium channels — Google Chrome and Microsoft Edge — become
  first-class testable targets. Five engines, three of which are
  `BrowserType`s and two of which are channels on one of those three (D1a).
- **Part B — the platforms.** Playwright.jl runs on Windows and macOS. The
  driver assembly already *has* branches for both and has never executed
  either of them; this part is about making those branches true.
- **Part C — the matrix.** GitHub Actions runs the hermetic suite and the smoke
  suite across the platform × engine grid, with WebKit-on-Windows excluded.

**M9 is different in kind from M1–M8, and the plan has to respect that.**
Every previous milestone was new API surface, verifiable on the developer's own
machine before it was pushed. M9 is barely new API — Part A adds one struct
field, one small type and two functions — and its hardest half is unverifiable
locally by construction: the developer runs Fedora, and Part B's entire subject
is the two platforms that are not Fedora.

That single fact drives D14, which inverts the usual ordering: **the CI matrix
lands first, as the instrument, not last, as the celebration.** Work happens on
a branch with an open pull request from the first commit, and the Windows and
macOS jobs are the substitute for a local test run. A milestone whose feedback
loop is a CI queue is a milestone where a wrong order costs days rather than
minutes.

**Ordering: C's scaffold, then A, then B, then C's completion.** Part C is
split. Its scaffold — the branch, the PR, the OS axis running the *existing*
suite unchanged — comes before any source change, because it is the only way to
find out what Part B has to fix. Part A follows, on Linux, where it can be
driven locally and where a WebKit failure means WebKit and not Windows. Part B
consumes the scaffold's failures. Part C then closes with the engine axis, the
cache keys and the README.

## Assumptions

Calls this spec makes without being told. Correct any that are wrong.

1. **New spec, not a rewrite.** `SPEC-M9.md` joins its eight predecessors; none
   of them are edited. `tasks/plan.md` and `tasks/todo.md` are rotated into
   `tasks/m8/` first, as M1–M7 were.
2. **Breaking changes are allowed** and follow the M6/M7/M8 rule: no
   deprecation shims, old spellings simply stop existing. M9 expects to break
   almost nothing — `PlaywrightAPI` gains a field, which is an internal
   constructor change, and no exported call changes meaning.
3. **Playwright stays pinned at 1.61.1**, Node at 24.17.0. WebKit is already in
   the vendored protocol spec, the pinned driver already ships its installer,
   and `channel` is already a wire-asserted `launch` keyword
   (`test_connection.jl:297`). No `gen/fetch_spec.jl` run is part of this
   milestone.
4. **No regeneration.** `src/generated/` is untouched, and
   `gen/generate.jl --check` stays green at every commit without anyone running
   the generator.
5. **No new package dependency.** Part B is path handling and archive
   extraction with what is already there. If Windows needs something p7zip_jll
   cannot do, that is an Ask First (see Boundaries), not a silent `[deps]` line.
6. **x86_64 on Linux and Windows, aarch64 on macOS.** `macos-latest` is Apple
   Silicon, so Part B's macOS leg is the first execution of `node_platform`'s
   `arm64` branch as well as its `darwin` branch. Intel macOS is not a target
   and is not tested.
7. **Windows means the GitHub `windows-latest` runner**, x64, with the standard
   toolchain. No MSYS, no WSL, no Cygwin. If a fix only works under one of
   those, it is not a fix.
8. **WebKit is a first-class engine for testing, not for defaults.** It joins
   the smoke engine list and the matrix, but `install()` with no arguments
   still installs two browsers (D2). The download is not imposed on a user who
   never asked for it.
9. **The branded browsers are used where they are found, not installed by CI**
   (D3a). Chrome and Edge are system packages, not Playwright downloads: they
   need root on Linux, they cannot live in `PLAYWRIGHT_BROWSERS_PATH`, and they
   cannot be cached. GitHub's runner images ship both. CI consumes what the
   image provides and pins nothing.
10. **The engines will differ, and that is data, not failure.** WebKit is not a
    Chromium reskin, and Chrome and Edge are not the bundled Chromium — they
    are a different build, on a release channel that moves under us. Some
    fraction of the existing smoke assertions will not hold on all five. The
    milestone's job is to find out which, decide each deliberately, and write
    the answer where a *user* can read it (D4) — not to reach green by
    narrowing tests until they stop asking.
11. **A part is not silently thinned.** Same rule M8 ran under. If a checkpoint
    slips, that is a conversation. Specifically: shipping WebKit on Linux only,
    or Windows without the smoke suite, is a cut whatever it is called. The one
    exclusion this spec makes up front is WebKit on Windows, and it is a
    decision (D12), not a slip.
12. **The examples stay on Linux, on the two bundled engines** (D10). They are
    a demonstration of Julia web stacks, not a portability test of this
    package.
13. **The pull request is squash-merged at the end**, and its intermediate
    commits are working commits, not a curated history. CI green on the PR head
    is the gate, not CI green on every commit in it.

## Objective

### Part A — the engines

Three `BrowserType`s, and two branded channels on one of them:

```julia
playwright() do pw
    for name in ("chromium", "firefox", "webkit", "chrome", "msedge")
        browser = launch(engine(pw, name); headless = true)
        try
            page = new_page(browser)
            goto!(page, "https://example.com")
            expect(page; to_have_title = "Example Domain")
        finally
            close!(browser)
        end
    end
end
```

`engine(pw, name)` is the whole of the new surface (D1a). It exists because the
five things that loop iterates are not five of a kind: `"webkit"` names a field
on `pw`, while `"chrome"` names `pw.chromium` *plus* `channel = "chrome"`. Every
caller with a name in a variable — the test matrix, `examples/common.jl`, a
user's `ENV` — would otherwise carry that mapping itself.

```console
$ julia bin/install.jl webkit              # a Playwright download
$ sudo -E julia bin/install.jl --with-deps webkit
$ julia bin/install.jl chrome              # a system package install (D3a)
```

### Part B — the platforms

```console
PS> julia --project=. -e 'using Pkg; Pkg.test()'                       # Windows
$  julia --project=. -e 'using Pkg; Pkg.test()'                        # macOS
```

Both green, hermetic and smoke. There is no new API here at all. The
deliverable is that `install_driver` assembles a working bundle from
`node-v24.17.0-win-x64.zip` and `node-v24.17.0-darwin-arm64.tar.xz`, that the
tests stop assuming a `/`-separated filesystem where they actually touch one,
and that a Windows checkout's line endings do not change what the suite reads.

### Part C — the matrix

```
Hermetic:  {ubuntu, windows, macos} × {1.10, 1}                       6 jobs
Smoke:     ubuntu  × {chromium, firefox, webkit, chrome, msedge}      5 jobs
           macos   × {chromium, firefox, webkit, chrome, msedge}      5 jobs
           windows × {chromium, firefox,         chrome, msedge}      4 jobs
Examples:  ubuntu  × {chromium, firefox}                    2 jobs, unchanged
Codegen, format, docs:  ubuntu                                 unchanged
```

Fourteen smoke jobs. D12 explains why that is the trade and what it costs.

### What M9 is *not*

- **Not service workers, not a trace viewer, not an async API.** The other
  three entries on the not-covered list stay there, and the README keeps
  justifying each one.
- **Not Intel macOS, not Linux aarch64, not 32-bit anything** (Assumption 6).
- **Not WebKit on Windows** (D12).
- **Not beta or dev channels.** `chrome-beta`, `msedge-dev` and the rest remain
  reachable through `launch(...; channel = ...)`, which already works. They are
  not engine names, not installed, and not in the matrix (D1a).
- **Not an engine-specific feature.** Nothing in Part A adds API only one
  engine can use. If WebKit exposes something the others do not, it goes in
  `tasks/m9-api-gaps.md`.
- **Not a rewrite of the smoke suite.** The engine loops already iterate
  `SMOKE_ENGINES`. Part A lengthens that vector and changes how a name becomes
  a launch; it does not restructure how tests are written.
- **Not headed browsers on Windows or macOS.** Everything runs headless. The
  examples' xvfb arrangement is Linux-only and stays that way (D10).

## Decisions

# Part A — the engines

## D1 — `PlaywrightAPI` gains a `webkit` field

The root initializer already carries `webkit` alongside `chromium` and
`firefox`; `start_playwright` simply does not read it. The field is added, and
the docstring stops saying "Fields `chromium` and `firefox`". That is the
entire WebKit-as-a-type change.

## D1a — An engine name is not a field name, so `engine(pw, name)` is the mapping

This is the decision the branded browsers force, and it is worth stating
plainly because the alternative looks cheaper than it is.

Playwright does not model Chrome and Edge as browser types. They are the
`chromium` type launched with `channel = "chrome"` or `"msedge"` — a keyword
this package already supports and already asserts on the wire. So the naive
reading of "add Chrome and Edge" is "nothing to do; tell users to pass
`channel`". That reading fails the moment a *name* is in a variable, which is
exactly the case this milestone creates: `PLAYWRIGHT_JL_ENGINE`, the CI matrix,
`examples/common.jl`, and every smoke testset's engine loop. Each of them would
carry its own copy of "chrome means chromium plus a channel", and the copies
would drift.

So the mapping lives in one place, as a small value:

```julia
struct Engine
    browser_type::BrowserType
    name::String                          # "chrome"
    channel::Union{String,Nothing}        # "chrome", or nothing for a bundled engine
end

engine(pw, "webkit")   # Engine(pw.webkit,   "webkit", nothing)
engine(pw, "msedge")   # Engine(pw.chromium, "msedge", "msedge")
engine(pw, "edge")     # ArgumentError naming all five
```

`launch(::Engine; kwargs...)` forwards `channel` unless the caller passed one,
in which case the caller wins and the `Engine`'s channel is ignored — with no
warning, because passing `channel = "chrome-beta"` to
`engine(pw, "chrome")` is a coherent thing to want and not a mistake.

`engine_name(e)` returns the engine name. **It is deliberately not
`browser_name`**, which asks the *browser* what it is and answers `"chromium"`
for all three Chromium engines. The two questions have different answers and
therefore need different spellings — conflating them is the single most likely
source of a wrong skip in D4, since a test that branches on
`browser_name(browser) == "chromium"` will now catch Chrome and Edge too, which
is usually right and occasionally not.

Five names, closed set: `"chromium"`, `"firefox"`, `"webkit"`, `"chrome"`,
`"msedge"`. Other channels stay reachable through `launch`'s keyword and are
not engine names (see "What M9 is not").

`Engine`, `engine` and `engine_name` are the only new exported names in the
milestone.

## D2 — WebKit is opt-in to install, and `launch` still installs it for you

`DEFAULT_BROWSERS` stays `["chromium", "firefox"]`. `julia bin/install.jl` with
no arguments keeps doing what the README says it does, and a first-time user
does not pay for a third browser download to run the quick-start example.

This is safe *because* `launch` already self-heals: `lifecycle.jl:281` installs
a missing engine on first use. `launch(engine(pw, "webkit"))` on a machine that
only ran `bin/install.jl` works — it just pauses once to download.

CI names each engine explicitly, which is what D13's per-engine cache key wants
anyway.

## D3 — Linux WebKit needs system libraries, so `install` gains `with_deps`

WebKit is the engine that does not ship its own world. On a stock Ubuntu runner
`playwright install webkit` succeeds and then the browser fails to launch on a
missing shared library. The driver's own answer is `install --with-deps`, which
runs the distribution's package manager and therefore needs root.

```julia
install(; browsers = ["webkit"], with_deps = true)
```

```console
$ sudo -E julia bin/install.jl --with-deps webkit
```

`with_deps = true` on Windows or macOS is an `ArgumentError`, not a silent
no-op: the driver has nothing to do there and a script that passes it is
confused about what it is running on.

The alternative — CI carrying its own `apt-get install libwoff1 …` list — was
rejected because that list is a function of the pinned Playwright version and
would drift silently the first time the pin moves. The driver already knows the
list; asking it is the maintainable answer.

**The failure mode this creates is the one to guard.** A user on Linux who does
*not* pass `with_deps` gets an auto-install from `launch` (D2) and then a launch
failure whose message is the driver's. Part A catches that case and names the
fix, because "missing libraries" with no mention of `--with-deps` is a support
question rather than an error message.

## D3a — Branded browsers are found, not installed; CI never installs them

`playwright install chrome` does not download a browser into
`PLAYWRIGHT_BROWSERS_PATH`. It installs Google Chrome as a **system package** —
apt on Linux (root), a `.dmg` on macOS, a `.exe` on Windows. Three consequences,
each of which changes something:

1. **`browsers_from_args` accepts `"chrome"` and `"msedge"`** and passes them
   through to the driver, so a *user* can run `julia bin/install.jl chrome`.
   Unknown names are still rejected before anything starts.
2. **`install` warns, once, that a branded name is a system-wide change**, and
   on Linux says it needs root. An installer that silently invokes `sudo apt`
   on someone's workstation because they typed a browser name is not acceptable
   behaviour; saying so first is.
3. **CI never runs it.** GitHub's runner images already ship Chrome and Edge on
   all three platforms (OQ 3 confirms exactly which). The branded smoke jobs
   therefore skip the browser-install step entirely and skip the browser cache
   entirely — there is nothing in the workspace to cache (D13). This also means
   those jobs test whatever version the runner image currently has, which is a
   moving target *by design*: a Chrome stable release that breaks this package
   is a thing worth finding out about, and pinning it away would be pretending
   users are on a version they are not.

**The corresponding failure mode:** a branded launch on a machine without that
browser. Playwright's own message for this is reasonable but does not know
about `bin/install.jl`. Part A checks it and names both the install command and
the fact that it is a system install — the same treatment D3 gives the WebKit
case, for the same reason.

## D4 — Every engine divergence is a named skip and a documented row

Assumption 10 says the engines will differ. This decides what happens each time
they do, and the rule is that a divergence costs the same whether it is small or
large, so there is no incentive to hide a small one:

1. The test says so at the call site, with a reason:
   ```julia
   @testset "…" for name in SMOKE_ENGINES
       skip_engine(name, "webkit", "no Page.pdf outside Chromium") && continue
       …
   end
   ```
   `skip_engine` logs at `@info` and returns a `Bool`. A skip that is not
   visible in the test output does not exist.
2. It gains a row in **`docs/src/engines.md`**, a new documentation page: what
   differs, on which engine, and what to do instead. This is the user-facing
   deliverable of Part A and the reason the part is worth more than a struct
   field.
3. If the divergence is Playwright's, the row says so and links upstream. If it
   is *this package's* — an assumption baked into a wrapper — it is a bug and
   goes in `tasks/m9-api-gaps.md` instead.

The three are not alternatives. A skip with no row is an unfinished skip.

**Two divergence classes are new with the branded engines**, and the page needs
both: things Chrome or Edge do that bundled Chromium does not (proprietary
codecs, DRM, an enterprise policy layer), and things that differ *by platform
for the same engine* — Edge on macOS is not Edge on Windows. A row therefore
names a platform when the platform is what makes it true.

## D5 — `SMOKE_ENGINES` accepts a list, because five is where one-at-a-time stops being free

`PLAYWRIGHT_JL_ENGINE` currently means "exactly one engine, or all of them".
With five engines the local full run is far longer than it was, and the useful
middle case — "the two that already worked, while I fix the third" — has no
spelling.

```console
$ PLAYWRIGHT_JL_ENGINE=webkit julia …                    # one, as before
$ PLAYWRIGHT_JL_ENGINE=chromium,firefox julia …          # the middle case
$ julia …                                                # all five
```

Parsed once in `runtests.jl`, validated against the five known names with the
same error `engine` raises (D1a), and shared with `examples/common.jl`. An
unknown name in the variable fails the run immediately rather than producing an
empty engine loop that passes by vacuum — which is the actual risk, and the
reason this is a decision and not a convenience.

**The default is all five, and that is a real cost to a contributor**, roughly
2.5× M8's smoke run on one machine. It is the right default anyway: a default
that silently tests less than CI is how a contributor discovers a WebKit
failure from a red PR instead of from their own terminal. `CONTRIBUTING`-level
guidance to narrow the variable while iterating belongs in `engines.md`.

# Part B — the platforms

## D6 — The hermetic suite is the first gate on every platform, and it needs no browser

`Pkg.test()` without `PLAYWRIGHT_JL_SMOKE` needs no Node, no browser and no
network. It is therefore the cheapest possible Windows and macOS signal — a
couple of minutes against a smoke job's fifteen — and it comes first in the
matrix and first in the task order.

This is not only sequencing. It also partitions Part B's failures into two
kinds that want different fixes: a hermetic failure on Windows is *this
package's* portability bug (a path, a line ending, a string comparison), while a
smoke failure is the driver bundle or the browser. Finding the first kind under
the second kind's 15-minute feedback loop is how a week disappears.

## D7 — Line endings are normalised in the repository, by `.gitattributes`

A Windows checkout with the default `core.autocrlf` rewrites every text file on
the way to disk. The repository currently has no `.gitattributes`, so the
behaviour is whatever the runner's git is configured for — exactly the kind of
thing that produces a failure no one can reproduce.

```
* text=auto eol=lf
*.png binary
*.zip binary
*.har.zip binary
```

Every file in the working tree is LF on all three platforms. This is a
prerequisite for the codegen check (byte-for-byte against generated output), the
formatting check, and any hermetic test that reads a fixture and compares its
text.

Both checks stay Linux-only jobs regardless — but a *developer* on Windows
should not see them fail for a reason unrelated to their change, and the
fixture-reading tests run everywhere.

## D8 — Path assertions compare paths, not strings

The hermetic tests are mostly safe already, because their `/tmp/pw/thing.zip`
values are opaque strings handed to a fake driver and read back unchanged. The
exposure is where a test builds a path on one side and asserts on the other:
`joinpath` produces `\` on Windows and a literal `"dir/file"` does not.

The rule for Part B: anywhere a test constructs a real filesystem path, assert
with `basename`, `isfile`, or a `joinpath`-built expectation — never against a
`/`-separated literal. Fixture paths that never touch a filesystem stay as they
are; rewriting them would be churn with no signal.

## D9 — The Node archive's member extraction is probed before it is trusted

`install_driver` limits extraction to one archive member, because 7z refuses the
Node dist's npm/npx symlinks. On Windows the archive is a `.zip`, the member is
`node-v24.17.0-win-x64/node.exe`, and **whether 7z matches that
forward-slashed path on Windows is unverified**. It is one of the things in this
milestone that cannot be reasoned about and must be run (OQ 1).

The decision is the shape of the answer, not the answer: if the member filter
misbehaves, the fix is the filter — a different separator, or 7z's `-i!` include
switch — and not "extract the whole archive on Windows", which brings back the
symlink failure the member limit exists to avoid. If extraction cannot be made
member-limited on some platform, that is an Ask First.

`chmod(node_dest, 0o755)` stays. On Windows Julia's `chmod` touches the
read-only bit and is harmless; special-casing it would be noise.

## D10 — The examples stay on Linux, on two engines, deliberately

Genie's 25-second warm-up, WGLMakie's minute of SwiftShader shader compilation,
and Firefox-under-xvfb are the slowest and most environment-dependent thing in
this repository. Running them across three platforms and five engines would
multiply the longest job in CI by fifteen, and what it would test is Genie's and
Makie's portability, not Playwright.jl's.

The README and the examples' own docs say so, so that a Windows user who runs
them and hits a Makie problem knows whose problem it is.

## D11 — The orphan-process check stays Unix-only, and says why

`playwright_browser_pids` shells out to `pgrep -f ms-playwright` and is already
gated behind `Sys.isunix()`. A Windows equivalent via `tasklist` is a half-page
of parsing for one assertion, on the platform where the failure it guards
against is least likely to be noticed anyway.

**It is also wrong for the branded engines on every platform**: Chrome and Edge
do not live under `ms-playwright`, so the `pgrep` pattern cannot see them and
the check silently passes by matching nothing. That is worse than not running,
so the check is additionally gated to bundled engines, with the gap named.

The gates stay, with a comment naming what is not covered. Writing that down is
the deliverable; the parser is not.

# Part C — the matrix

## D12 — Fourteen smoke jobs: the full grid, minus WebKit on Windows

WebKit on Windows is excluded. Everything else is the full cross product,
`fail-fast: false`.

The remaining temptation is to trim further — Chrome only on Linux, Edge only
on Windows — and it is the wrong trade for this package specifically. The whole
*point* of a browser-automation binding is that the caller's combination works,
and the combinations are exactly what a trimmed matrix stops testing. Edge on
macOS is a genuinely different thing from Edge on Windows, and a user who hits
it should not be the one to discover it.

What it costs, stated rather than discovered:

- **Fourteen smoke jobs at roughly 15–25 minutes.** Free-tier public-repo
  minutes are not the constraint; **concurrency is**. GitHub caps concurrent
  macOS jobs well below the other platforms, so the five macOS smoke jobs plus
  two macOS hermetic jobs will queue rather than run in parallel. Expect macOS
  to be the critical path of every CI run for the rest of this repository's
  life. SC 19 records the real numbers so that this stays a known cost rather
  than a mystery.
- If those numbers come back bad enough to change the answer, **trimming the
  matrix is an Ask First** (Assumption 11), not a quiet edit.

The hermetic matrix is 3 OS × 2 Julia versions and does **not** grow an engine
axis, because it launches nothing.

## D13 — Bundled engines install one browser and cache it per engine; branded engines do neither

Today's smoke job matrices on `engine` but runs `julia bin/install.jl`, which
installs both engines, under the key
`playwright-${{ runner.os }}-pw…-node…` with no engine in it. That is consistent
today only by accident: every job installs the same two browsers, so every job
populates the same cache correctly.

Adding engines breaks it. If one job installs only what it needs, it publishes a
cache under a key promising more than it holds, and the next job restores it,
sees a hit, skips the install, and fails to launch.

So for the three bundled engines, both halves change together:

```yaml
key: playwright-${{ runner.os }}-${{ matrix.engine }}-pw…-node…
run: julia bin/install.jl ${{ matrix.engine }}
```

Each job downloads one browser instead of two, which is why this is a saving as
well as a correctness fix.

**The two branded engines take neither step** (D3a, Assumption 9). There is
nothing to download into the workspace and therefore nothing to cache; the
runner image supplies the browser. Their jobs still need the *driver*, which
lands in a Scratch.jl directory that `julia-actions/cache` already covers. A
branded job that runs `bin/install.jl` would be attempting a system package
install on a CI runner, which is exactly what D3a forbids.

**The Linux WebKit job additionally runs the `--with-deps` install under
`sudo -E`** (D3), which the cache cannot restore — system packages do not live
in the workspace. That step runs unconditionally, not behind the cache-hit
check.

The workflow is therefore conditional on engine class in two places and on OS in
one. That is three conditionals in a matrix job, which is at the limit of what
is readable in YAML; if it grows a fourth, the install step becomes a script in
`bin/` that takes the engine name and decides for itself. Not before.

## D14 — The pull request is the instrument, and it is opened before the first source change

The developer cannot run Windows or macOS. Every previous milestone's inner loop
was "change, test locally, commit"; for Part B it is "change, push, wait for the
matrix". That loop is roughly a hundred times slower, and the plan's whole job is
to keep the number of trips through it small.

Therefore:

1. Branch `m9-engines-and-platforms`, and a **draft** pull request, before any
   change to `src/`.
2. The first commit is Part C's *scaffold*: the OS axis added to the hermetic
   job, running the existing suite unchanged, with no engine axis and no
   Windows/macOS smoke job yet. Its purpose is to fail, informatively, and its
   failures are Part B's task list.
3. Every subsequent task pushes to the branch. The PR description carries a live
   table — task, platforms green, platforms red — updated as the milestone runs.
   That table is what "test as you go" means concretely, and it is what makes
   the state of a fourteen-job matrix legible without opening fourteen logs.
4. The PR leaves draft at Checkpoint C, and merges squashed.

The corollary is a discipline: **do not push a speculative fix and a real fix in
the same commit.** With a queued macOS matrix, a green result that cannot be
attributed is worth much less than a slower one that can.

## D15 — All smoke timeouts go to 60 minutes

Linux smoke is 45 minutes today and runs in about 16. Windows process startup,
antivirus scanning of a freshly extracted browser, and a cold Julia
precompilation are all slower, and the first run on a platform has no cache at
all. The timeout goes to 60 for all smoke jobs rather than being tuned per
platform — a timeout's job is to catch a hang, and a hang is a hang everywhere.

Note that a queued macOS job does not consume its timeout while queued, so D12's
concurrency cost and this number are independent.

If a platform genuinely needs more than 60 minutes of *work*, that is a finding
worth its own conversation, not a number to raise.

## Tech Stack

Unchanged from M8. Julia 1.10 and current stable; Playwright 1.61.1; Node
24.17.0; `Downloads`, `Scratch`, `p7zip_jll`, `JSON`, `Base64`, `Dates` and
nothing new (Assumption 5). Test-only: `HTTP`, `JSON`, `Sockets`, `TOML`,
`Test`.

New to M9 on the infrastructure side only: `windows-latest` (x64) and
`macos-latest` (aarch64) GitHub runners, the Chrome and Edge builds those images
ship, and `.gitattributes`.

## Commands

```console
# The suite
$ julia --project=. -e 'using Pkg; Pkg.test()'                          # hermetic
$ PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()'     # + browsers
$ PLAYWRIGHT_JL_SMOKE=1 PLAYWRIGHT_JL_ENGINE=webkit julia --project=. -e 'using Pkg; Pkg.test()'
$ PLAYWRIGHT_JL_SMOKE=1 PLAYWRIGHT_JL_ENGINE=chrome,msedge julia --project=. -e 'using Pkg; Pkg.test()'

# Browsers
$ julia bin/install.jl                          # chromium + firefox (unchanged)
$ julia bin/install.jl webkit
$ sudo -E julia bin/install.jl --with-deps webkit
$ julia bin/install.jl chrome                   # system package install, warns first

# The gates
$ julia --project=gen gen/generate.jl --check
$ julia --project=gen -e 'using JuliaFormatter; format(".")'
$ julia --project=docs docs/make.jl

# The instrument (D14)
$ gh pr create --draft --fill
$ gh pr checks --watch
```

## Project Structure

Unchanged, plus:

```
.gitattributes            NEW — D7, line-ending normalisation
docs/src/engines.md       NEW — D4, what differs between the five engines
tasks/SPEC-M9.md          this file
tasks/m9-api-gaps.md      NEW — opened empty before the first src/ change
tasks/m9-probe.md         NEW — the answers to the Open Questions
tasks/m8/                 NEW — plan.md and todo.md rotated out of tasks/
```

No new file under `src/`. Part A touches `src/objects.jl` (the `webkit` field,
the `Engine` type and their docstrings), `src/api/lifecycle.jl` (reading
`webkit` from the initializer, `engine`, `engine_name`, `launch(::Engine)`) and
`src/driver.jl` (`with_deps`, the branded names, the warning). Part B touches
`src/driver.jl` and the test suite. Part C touches `.github/workflows/CI.yml`.

## Code Style

Unchanged. The new exported function, in the house shape — a docstring that
leads with the reason, an example, and the error named:

```julia
"""
    engine(pw, name) -> Engine

The engine `name` names, ready to [`launch`](@ref). One of `"chromium"`,
`"firefox"`, `"webkit"`, `"chrome"` or `"msedge"`.

The last two are not browser types: Playwright launches Google Chrome and
Microsoft Edge as `chromium` with a `channel`, and this function is where that
mapping lives so that no caller has to carry a copy of it. The point of asking
by name is a name that came from somewhere else — an environment variable, a
test matrix, a command line — where a typo should say so rather than surface as
a missing field much later.

```julia
playwright() do pw
    browser = launch(engine(pw, get(ENV, "ENGINE", "chromium")); headless = true)
end
```

[`engine_name`](@ref) asks an `Engine` which of the five it is. That is a
different question from [`browser_name`](@ref), which asks the running browser
and answers `"chromium"` for Chrome and Edge alike.

Throws `ArgumentError` naming all five when `name` is not one of them.
"""
function engine(pw::PlaywrightAPI, name::AbstractString)
    …
end
```

## Testing Strategy

Two tiers as before: hermetic by default, smoke behind `PLAYWRIGHT_JL_SMOKE=1`.
M9 adds a platform axis to both and three engines to the second.

**What is tested hermetically** — everything Parts A and B can reach without a
browser, which is most of Part B and a useful slice of Part A:

- `engine(pw, name)` for all five names: the right `BrowserType`, the right
  `channel` (`nothing` for the three bundled ones), the right `engine_name`;
  and the `ArgumentError` for anything else. Against the fake driver, so no
  browser is involved.
- `launch(::Engine)` puts `channel` on the wire for the branded two and omits
  the key entirely for the other three — asserted on the wire, in
  `test_connection.jl`'s style, because "omitted" and "null" are different
  messages and only one of them is right.
- An explicit `channel` keyword overriding the `Engine`'s (D1a).
- `node_platform` and `node_url` for all six OS/arch pairs the package claims,
  including the two it cannot run on the developer's machine. Pure functions,
  already testable, now load-bearing on platforms nobody will notice breaking.
- `driver_cmd` producing `node.exe` on Windows — already asserted in
  `test_driver.jl:26`, and now actually executed on Windows.
- `SMOKE_ENGINES` parsing: one name, a comma list, empty, and an unknown name
  (D5). The unknown-name case is the one that matters — it must throw, not
  yield an empty vector.
- `install(; with_deps = true)` refused off Linux (D3), and the branded-name
  warning (D3a), both before any download.

**What needs a browser** — Part A's adjudication work, and the confirmation that
Part B's bundle assembly produced something that runs. The existing smoke files
gain engines rather than new files; the exception is `test_engines.jl`, if D4's
divergence set turns out large enough that scattering it reads worse than
collecting it. That is a call to make at Checkpoint A with the divergence list in
hand, not now.

**What is not tested, and is named rather than omitted:**

- WebKit on Windows (D12).
- Orphan browser processes on Windows, and for branded engines anywhere (D11).
- The examples on any platform but Linux, or any engine but the bundled two
  (D10).
- Intel macOS, Linux aarch64 (Assumption 6).
- Beta and dev channels ("What M9 is not").
- Headed mode anywhere but the Linux examples job.

**The count discipline continues.** M8 recorded 2417 hermetic / 3348 smoke.
M9's smoke count will jump for a reason that is not new coverage — five engines
multiplying existing testsets — so the number is recorded *per engine* as well
as in total, or it means nothing.

## Boundaries

**Always**

- Hermetic suite before every commit; smoke before every push.
- `gen/generate.jl --check` green at every commit, without anyone having run the
  generator (Assumption 4).
- Every engine divergence gets both a named skip and a `docs/src/engines.md`
  row, in the same commit (D4).
- Every new exported name gets a docstring and an `api.md` entry in the commit
  that introduces it.
- Record anything noticed and out of scope in `tasks/m9-api-gaps.md`, opened
  empty before Part A's first line. Fifth turn of the instrument.
- `format(".")` clean before every push.
- Push each fix separately enough to attribute the result (D14).

**Ask first**

- Adding any package dependency (Assumption 5), including anything that would
  make Windows extraction work by a different route than p7zip_jll.
- Moving the pinned Playwright or Node versions — including "WebKit needs a
  newer driver", the most likely form the temptation will take.
- Trimming the smoke matrix beyond D12's stated exclusion, or dropping a
  platform or engine from any part (Assumption 11).
- Pinning a branded browser version in CI, or installing one there (D3a).
- Adding a sixth engine name, including any beta or dev channel.
- Any refactor of existing code beyond D1a's engine plumbing and D5's parsing.
- Extraction that is not member-limited on any platform (D9).

**Never**

- Weaken or `@test_skip` an assertion to make an engine green without a
  `docs/src/engines.md` row saying what it means (D4). This is M9's single most
  likely failure mode and the reason D4 exists.
- Invoke a system package manager from `install` without saying so first (D3a).
- Call user code from the transport reader task (the world-age trap).
- Hand-edit `src/generated/`.
- Format from the `@pw-probe` environment.
- Merge the PR while any platform is red without that being an explicit,
  recorded decision.
- Let a platform-specific fix change behaviour on a platform that was already
  working — every `Sys.iswindows()` branch added is a branch that must be
  justified in the commit that adds it.

## Success Criteria

Each is a thing to run, not a thing to believe. Recorded in a table in
[`tasks/todo.md`](todo.md) in the M5–M8 style, archived to `tasks/m9/` when the
milestone closes.

**Part A — the engines**

1. `pw.webkit` is a `BrowserType` with `browser_name(pw.webkit) == "webkit"`,
   asserted against the real driver.
2. `engine(pw, name)` returns the right `BrowserType` and channel for all five
   names, and raises an `ArgumentError` naming all five for anything else —
   both hermetically.
3. `launch(::Engine)` sends `channel` for `"chrome"` and `"msedge"` and omits
   the key for the other three, asserted on the wire; an explicit `channel`
   keyword wins over the `Engine`'s (D1a).
4. `engine_name` and `browser_name` disagree exactly where they should:
   `engine_name(engine(pw, "msedge")) == "msedge"` while the browser it
   launches reports `"chromium"`. Asserted in smoke, because it is the thing a
   test author will get wrong.
5. The full smoke suite passes on Linux for all five engines.
6. Every testset an engine skips does so through `skip_engine`, logs its reason,
   and has a matching row in `docs/src/engines.md`. Asserted by a test that
   reads the page and the skip reasons and requires them to agree — a skip with
   no row fails the suite.
7. `install(; browsers = ["webkit"], with_deps = true)` reaches the driver with
   `--with-deps`, asserted on the command; and raises `ArgumentError` on Windows
   and macOS before any download.
8. `bin/install.jl chrome` warns that it is a system-wide install, and says it
   needs root on Linux, before invoking the driver (D3a). Asserted on the
   warning, with no install performed.
9. A WebKit launch failing for missing system libraries names `--with-deps`, and
   a branded launch failing for an absent browser names `bin/install.jl` and the
   fact that it is a system install. Proved by running each where it fails, or
   by injecting the driver's message where that cannot be arranged — and the
   todo table says which of the two it was.
10. `PLAYWRIGHT_JL_ENGINE=chrome,msedge` runs exactly two engines; an unknown
    name raises before the first browser starts (D5), asserted hermetically.
11. `bin/install.jl` with no arguments still installs exactly chromium and
    firefox (D2), asserted on `DEFAULT_BROWSERS` and unchanged in the README.

**Part B — the platforms**

12. The hermetic suite passes on `windows-latest` and `macos-latest`, both Julia
    versions, with no test skipped that is not skipped on Linux for a reason
    D10/D11/D12 already named.
13. `node_platform` and `node_url` are asserted for all six claimed OS/arch
    pairs, and the unsupported cases raise with the offending value in the
    message.
14. `install_driver` assembles a working bundle on Windows — the member-limited
    extraction gets `node.exe` out of the `.zip` (D9) — proved by
    `driver_cmd("--version")` running.
15. The same on macOS aarch64, out of `node-v24.17.0-darwin-arm64.tar.xz`. First
    execution of the `arm64` branch.
16. `.gitattributes` is present, and a fresh checkout on Windows produces
    working-tree files that the fixture-reading tests parse identically to
    Linux. Proved by those tests passing on Windows, which is precisely what
    fails without it.
17. No test asserts a real filesystem path against a `/`-separated literal (D8).
    Grep-able, and the grep is in the todo table.
18. The smoke suite passes on Windows for four engines and on macOS for five.

**Part C — the matrix**

19. `CI.yml` runs the hermetic job on three OSes × two Julia versions, and
    fourteen smoke jobs on the grid D12 names, `fail-fast: false`.
20. Bundled-engine smoke jobs install exactly their own engine and cache under a
    key containing that engine; branded-engine jobs run neither the install nor
    the browser cache (D13). Proved by a second, fully cached run in which every
    job still passes — the failure this guards against only appears on a cache
    hit.
21. The Linux WebKit job runs `--with-deps` unconditionally, outside the
    cache-hit gate (D13).
22. All smoke timeouts are 60 minutes (D15), and the wall-clock durations of all
    fourteen jobs — **including macOS queue time** — are recorded in the todo
    table. This is the number that decides whether D12's grid stays affordable.
23. The examples job is unchanged: Linux, two engines (D10).
24. The pull request was opened before the first `src/` change, carried the live
    platform table, and left draft at Checkpoint C (D14).

**Everywhere**

25. Total suite counts recorded per engine and in total, hermetic and smoke, for
    comparison against M8's 2417 / 3348.
26. `julia --project=docs docs/make.jl` — zero errors, zero warnings, with
    `checkdocs = :exports`, `warnonly = false` and `doctest = true` unchanged.
    `engines.md` is in the sidebar.
27. `gen/generate.jl --check` green; `git diff` on `src/generated/` empty from
    the first commit to the PR head; `format(".")` clean.
28. `git diff` on `Project.toml` from the first commit to HEAD: empty
    (Assumption 5).
29. README rewritten: WebKit off the not-covered list, the three remaining
    entries still individually justified, the supported-platform claim widened
    from Linux to three, and the engine list updated everywhere it appears —
    including the fact that Chrome and Edge are channels rather than engines.
    Gated by `test_exports.jl`'s existing not-covered-list assertion, whose
    stale-list fixture is updated to a case that is still stale.
30. `docs/src/getting-started.md`'s "Choosing an engine" section no longer says
    WebKit is untested, and `docs/src/index.md`'s not-covered sentence agrees
    with the README's.
31. `docs/bonnie-parity.md` re-scored by M9: whether more engines or more
    platforms change any row, with a reason either way rather than silence.
32. `tasks/m9-api-gaps.md` exists, was committed before any `src/` change, and
    its final contents are reported — empty or not.

## Checkpoints

**Checkpoint 0 — the scaffold.** Branch, draft PR, `tasks/m9-api-gaps.md`,
`tasks/m8/` rotation, and the hermetic job on three OSes running the *existing*
suite. Expected red on two platforms. The red is the deliverable: it is Part B's
task list, and it must be captured in `tasks/m9-probe.md` before any fix.

**Checkpoint A — five engines on Linux.** SC 1–11. Almost entirely on the
developer's own machine, plus CI confirmation. The divergence list is complete
and `engines.md` exists. This is where the "collect divergences in
`test_engines.jl`?" question from the Testing Strategy gets answered.

**Checkpoint B — three platforms, hermetic.** SC 12–17. The cheap tier green
everywhere. Nothing here needs a browser, so a red at this checkpoint is always
this package's bug and never the environment's.

**Checkpoint C — the full matrix.** SC 18–24. Fourteen smoke jobs green, the PR
out of draft. **This is the budget checkpoint**: if it slips, the conversation is
about which platform or engine to defer, and per Assumption 11 that is a
conversation and not a quiet edit to the matrix.

**Checkpoint D — the paperwork.** SC 25–32. Docs, README, counts, gaps.

## Open Questions

These are what `tasks/m9-probe.md` exists to answer, and several cannot be
answered by reading anything. The probe runs before the plan is written, except
where noted that it needs the scaffold.

1. **Does 7z's member filter match a forward-slashed path inside a `.zip` on
   Windows?** (D9.) Needs the scaffold — a Windows-only question. If the answer
   is no, `install_driver` grows a separator branch and the milestone's first
   real Windows fix is on the critical path for everything else on that
   platform.
2. **Which smoke testsets diverge across the five engines?** (D4.) Answerable
   locally on Fedora for four of them today, and the single largest unknown in
   the milestone's size. The suspects: `Page.pdf` (Chromium-family only),
   `firefox_user_prefs` and `chromium_sandbox`, video recording,
   `executable_path`, the dialog and download flows,
   `is_multiple`/`webkitdirectory`, console message types, and the M8 surfaces —
   HAR replay, persistent contexts, WebSocket routing — none of which have ever
   seen a third engine, let alone a branded one.
3. **Which branded browsers do the three GitHub runner images actually ship, and
   does Playwright's channel lookup find them?** (D3a, Assumption 9.) Determines
   whether the four branded smoke jobs can exist as specified or need an install
   step after all — which would then need root on Linux and change D13. This is
   the highest-leverage question in the list: a wrong answer invalidates a
   decision rather than costing a fix.
4. **Does WebKit launch on a stock `ubuntu-latest` runner after a plain
   `install webkit`, or only after `--with-deps`?** (D3.) Determines whether
   SC 9's error-message work is a nicety or the difference between the Linux
   WebKit job working and not.
5. **What does a Windows browser cache path cost?** Scratch.jl directories plus
   Playwright's own layout under `%LOCALAPPDATA%`, against Windows' path-length
   limit. Suspected fine, unverified, and a nasty one to find late.
6. **Do headless Firefox and WebKit behave on macOS aarch64 the way they do on
   Linux** for the timing-sensitive parts of the suite — the `expect` retry
   assertions and the M8 WebSocket tests? Needs the scaffold's smoke leg.
7. **Is `sudo -E` on the GitHub Linux runner enough for `--with-deps`** to see
   the Julia depot and the assembled driver, or does the install step need to
   run as a separate non-Julia invocation? A five-minute question with a
   day-shaped answer if it is discovered at Checkpoint C.
8. **How much macOS queue time does D12's grid actually cost?** Needs the
   scaffold's macOS legs to measure even roughly. It is the only input to the
   question of whether the full grid survives contact.
