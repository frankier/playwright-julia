# Getting started

## Install

```julia
using Pkg
Pkg.add(url = "https://github.com/frankier/playwright-julia")
```

Playwright.jl is not registered yet, so it installs from the repository.

## The first run downloads things

There is no browser in this package, and no browser in its artifacts. On first
use it fetches two things:

- the upstream **`playwright-core` npm package**, at a pinned version. This is
  the same driver the Node, Python and .NET clients use.
- a pinned **Node.js binary** from nodejs.org to run it.

The package assembles both into a Julia scratch space keyed by the two versions.
The driver then downloads the browsers themselves into the standard Playwright
cache, `~/.cache/ms-playwright`, which it shares with any other Playwright
installation on the machine.

So the very first `launch` on a clean machine can take a couple of minutes.
Nothing is wrong. It is downloading a browser.

```julia
using Playwright
install()                            # driver + Chromium + Firefox, ahead of time
install(; browsers = ["chromium"])   # or just the one you need
```

[`Playwright.browsers_path`](@ref) reports where the package looks for browsers.
Check that first when a launch cannot find one.

## A first test

```julia
using Test
using Playwright

@testset "the homepage" begin
    playwright() do pw
        browser = launch(pw.chromium; headless = true)
        try
            page = new_page(browser)
            goto!(page, "https://example.com")

            expect(page; to_have_title = "Example Domain")
            expect(locator(page, "h1"); to_have_text = "Example Domain")
        finally
            close!(browser)
        end
    end
end
```

Three things in that shape are deliberate and worth copying:

1. **[`playwright`](@ref) takes a block.** It shuts the driver subprocess down on
   the way out, however the block ends. There is no `playwright()` that returns a
   handle for you to remember to close.
2. **`close!(browser)` sits in a `finally`.** On some platforms a browser left
   running outlives the test process.
3. **The assertions use [`expect`](@ref), not `@test title(page) == …`.**
   `expect` retries until the condition holds. The `@test` form reads once, and
   fails if the page was a few milliseconds slow. This is the most important
   habit in the package — see [Assertions](@ref).

To collect a screenshot and a trace when a test fails, use the
[`with_page`](@ref) fixture instead of the `try`/`finally` above. See
[Artifacts](@ref).

## Choosing an engine

There are five: `chromium`, `firefox`, `webkit`, `chrome` and `msedge`. The
first three are [`BrowserType`](@ref)s on the handle — `pw.chromium`,
`pw.firefox`, `pw.webkit` — and all three are tested on Linux and macOS
(WebKit is not supported on Windows).

The last two are **not** browser types. Playwright launches Google Chrome and
Microsoft Edge as `chromium` with a `channel`, using whatever build the machine
already has rather than downloading one.

[`engine`](@ref) is where that mapping lives, and it is what to use when the
engine arrives as a *name* — from an environment variable, a test matrix, a
command line — rather than as a field:

```julia
playwright() do pw
    for name in ("chromium", "firefox", "webkit")
        browser = launch(engine(pw, name); headless = true)
        try
            # ...the same test, on every engine
        finally
            close!(browser)
        end
    end
end
```

An unknown name raises immediately, naming all five, which is the point of
asking by name: a typo in an environment variable should say so rather than
surface much later as a missing field.

Two functions answer two different questions, and mixing them up is the most
common mistake here:

- [`engine_name`](@ref) — which of the five you asked for.
- [`browser_name`](@ref) — what is actually running. It answers `"chromium"`
  for Chrome and Edge alike, because they *are* Chromium.

Use `browser_name` when the behaviour follows from the rendering engine
(`pdf` works on the whole Chromium family) and `engine_name` when it follows
from which build you picked.

[What differs between the engines](@ref) has the full list of divergences, and
[`skip_engine`](@ref) for writing your own cross-engine suite.

## Browsers in CI

[`install`](@ref) needs to load Playwright.jl, which a project carrying it as a
**test** dependency cannot do outside `Pkg.test()`. Use `bin/install.jl` instead.
It runs standalone, and activates the checkout itself when the active environment
cannot load the package:

```console
$ julia bin/install.jl                 # driver + Chromium + Firefox
$ julia bin/install.jl chromium        # just the one you need
```

It rejects an unknown browser name before anything downloads.

Set `PLAYWRIGHT_BROWSERS_PATH` to put browsers somewhere you control. That is far
easier to cache and restore than a path in the home directory. Installing and
launching both read it, because the driver subprocess inherits Julia's
environment, so set it once and the two agree:

```console
$ export PLAYWRIGHT_BROWSERS_PATH="$PWD/.playwright"
$ julia bin/install.jl chromium
```

### A GitHub Actions job

This is close to what this repository runs against itself:

```yaml
jobs:
  browser-tests:
    runs-on: ubuntu-latest
    env:
      PLAYWRIGHT_BROWSERS_PATH: ${{ github.workspace }}/.playwright
    steps:
      - uses: actions/checkout@v4
      - uses: julia-actions/setup-julia@v2
      - uses: julia-actions/cache@v2

      - uses: actions/cache@v4
        id: browsers
        with:
          path: ${{ github.workspace }}/.playwright
          # Key on the Playwright version: that is what decides which browser
          # build is needed.
          key: playwright-${{ runner.os }}-1.61.1

      - name: Install browsers
        if: steps.browsers.outputs.cache-hit != 'true'
        run: julia --project=. bin/install.jl

      - uses: julia-actions/julia-runtest@v1
```

Two things that are easy to get wrong:

- **Check that the cache hits.** A key that never matches saves you nothing, and
  it fails silently: the job only stays slow. Read the log of a second run and
  check that it skipped the install step.
- **The driver bundle is separate from the browsers.** It lives in a Julia
  scratch space, which `julia-actions/cache@v2` already covers. Caching it
  yourself as well puts two actions on one path.

## Headless, and the display

Everything here passes `headless = true`, and a CI runner leaves no alternative.
Headless Chromium ships a software rasteriser, so even WebGL content renders with
no GPU and no X display. The pinned headless Firefox renders WebGL too. See
[WGLMakie.jl](@ref) for the measurements.

## Where to go next

- [Locators](@ref) — finding elements
- [Waiting](@ref) — and why it is not sleeping
- [Assertions](@ref) — `expect` and `retry_until`
- [Events](@ref) — popups, console output, page errors
- [Artifacts](@ref) — evidence from a failing test
- [Errors and timeouts](@ref) — what each failure means
