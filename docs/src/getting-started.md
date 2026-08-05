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

- the upstream **`playwright-core` npm package** — the same driver the Node,
  Python and .NET clients drive — at a pinned version;
- a pinned **Node.js binary** from nodejs.org to run it.

They are assembled into a Julia scratch space keyed by both versions. Browsers
themselves are downloaded by the driver into the standard Playwright cache
(`~/.cache/ms-playwright`), shared with any other Playwright installation on
the machine.

This means the very first `launch` on a clean machine can take a couple of
minutes. Nothing is wrong; it is downloading a browser.

```julia
using Playwright
install()                            # driver + Chromium + Firefox, ahead of time
install(; browsers = ["chromium"])   # or just the one you need
```

[`Playwright.browsers_path`](@ref) reports where browsers will be looked for,
which is the first thing to check when a launch cannot find one.

## A first test

```julia
using Test
using Playwright

@testset "the homepage" begin
    playwright() do pw
        browser = launch(pw.chromium; headless = true)
        try
            page = new_page(browser)
            goto(page, "https://example.com")

            expect(page; to_have_title = "Example Domain")
            expect(locator(page, "h1"); to_have_text = "Example Domain")
        finally
            close(browser)
        end
    end
end
```

Three things in that shape are deliberate and worth copying:

1. **[`playwright`](@ref) takes a block.** The driver subprocess is shut down
   on the way out however the block ends. There is no `playwright()` that
   returns a handle for you to remember to close.
2. **`close(browser)` is in a `finally`.** A browser left running outlives the
   test process on some platforms.
3. **The assertions are [`expect`](@ref), not `@test title(page) == …`.**
   `expect` retries until the condition holds; the `@test` form reads once and
   fails if the page was a few milliseconds slow. This is the single most
   important habit in the package — see [Assertions](@ref).

For a test that also collects a screenshot and a trace when it fails, use the
[`with_page`](@ref) fixture instead of the `try`/`finally` above; see
[Artifacts](@ref).

## Choosing an engine

`pw.chromium` and `pw.firefox` are the two supported engines. WebKit exists in
the protocol but is not tested by this package.

```julia
playwright() do pw
    for bt in (pw.chromium, pw.firefox)
        browser = launch(bt; headless = true)
        try
            # ...the same test, on both engines
        finally
            close(browser)
        end
    end
end
```

[`browser_name`](@ref) tells you which one you are on, for the rare case where
the engines genuinely differ and a test has to say so out loud.

## Browsers in CI

[`install`](@ref) needs Playwright.jl to be loadable, which is exactly what a
project carrying it as a **test** dependency does not have outside `Pkg.test()`.
`bin/install.jl` is the way in — it runs standalone, activating the checkout
itself if the active environment cannot load the package:

```console
$ julia bin/install.jl                 # driver + Chromium + Firefox
$ julia bin/install.jl chromium        # just the one you need
```

An unknown browser name is rejected before anything downloads.

Set `PLAYWRIGHT_BROWSERS_PATH` to put browsers somewhere you control, which is
far easier to cache and restore than a path in the home directory. Installing
and launching both read it — the driver subprocess inherits Julia's environment
— so set it once and the two agree:

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

- **Check that the cache actually hits.** A key that never matches is a cache
  that never saves you anything, and it fails silently — the job just stays
  slow. Read the log of a second run and confirm the install step was skipped.
- **The driver bundle is separate from the browsers.** It lives in a Julia
  scratch space, which `julia-actions/cache@v2` already covers by default.
  Caching it yourself as well means two actions writing the same path.

## Headless, and the display

Everything here passes `headless = true`, and on a CI runner there is no
alternative. Headless Chromium in particular ships a software rasteriser, so
even WebGL content renders with no GPU and no X display. Headless Firefox has
no WebGL at all — see [WGLMakie.jl](@ref) for what that does and does not
cover.

## Where to go next

- [Locators](@ref) — finding elements
- [Waiting](@ref) — and why it is not sleeping
- [Assertions](@ref) — `expect` and `retry_until`
- [Events](@ref) — popups, console output, page errors
- [Artifacts](@ref) — evidence from a failing test
- [Errors and timeouts](@ref) — what each failure means
