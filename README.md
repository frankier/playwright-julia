# Playwright.jl

[![CI](https://github.com/frankier/playwright-julia/actions/workflows/CI.yml/badge.svg)](https://github.com/frankier/playwright-julia/actions/workflows/CI.yml)
[![Docs](https://github.com/frankier/playwright-julia/actions/workflows/docs.yml/badge.svg)](https://frankier.github.io/playwright-julia/dev/)

Drive real browsers from Julia through the official
[Playwright](https://playwright.dev) automation engine — end-to-end testing,
scraping, and screenshot/PDF generation without leaving Julia or hand-rolling
CDP. The same architecture as `playwright-python`: a pinned Playwright driver
(Node.js) runs as a subprocess and Julia speaks its JSON protocol over stdio.

**📖 [Documentation](https://frankier.github.io/playwright-julia/dev/)** — the
guide, the examples and the full API reference live there.

## Install

```julia
using Pkg
Pkg.add(url = "https://github.com/frankier/playwright-julia")
```

Not registered yet.

## Quick start

```julia
using Playwright

playwright() do pw
    browser = launch(pw.chromium; headless = true)
    try
        page = new_page(browser)
        goto(page, "https://example.com")

        expect(page; to_have_title = "Example Domain")
        expect(locator(page, "h1"); to_have_text = "Example Domain")

        screenshot(page; path = "example.png")
    finally
        close(browser)
    end
end
```

This runs on a clean machine with only Julia installed: the first use
downloads the Playwright driver and the browser automatically, which takes a
couple of minutes. To do it ahead of time — strongly recommended in CI:

```console
$ julia bin/install.jl              # driver + Chromium + Firefox
$ julia bin/install.jl chromium     # just the one you need
```

`bin/install.jl` runs standalone, activating the checkout itself if the active
environment cannot load the package — which is the case a project carrying
Playwright.jl as a *test* dependency hits. See
[Getting started](https://frankier.github.io/playwright-julia/dev/getting-started/)
for caching browsers in GitHub Actions.

## Waiting is not sleeping

The one idea worth knowing before reading anything else. Every assertion
retries in the browser until it holds, so a test never has to guess how long a
page will take:

```julia
sleep(2)                                                   # don't
@test text_content(locator(page, "#status")) == "ready"

expect(locator(page, "#status"); to_have_text = "ready")   # do
```

## Examples

Four runnable scripts under [`examples/`](examples/), each driving a real Julia
web stack in a real browser:

| Script | Stack |
|---|---|
| [`http_jl.jl`](examples/http_jl.jl) | HTTP.jl — the pattern, with nothing else in the way |
| [`oxygen_jl.jl`](examples/oxygen_jl.jl) | Oxygen.jl — a page and the JSON API it calls |
| [`genie_jl.jl`](examples/genie_jl.jl) | Genie.jl — routing, and a 25-second warm-up |
| [`wglmakie_jl.jl`](examples/wglmakie_jl.jl) | WGLMakie.jl — WebGL, screenshotted and traced |

```console
$ julia --project=examples examples/runexamples.jl      # all of them, both engines
```

## Testing this package

```console
$ julia --project=. -e 'using Pkg; Pkg.test()'                       # hermetic
$ PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()' # + real browsers
```

The hermetic suite needs no Node.js and no browsers. The smoke suite launches
headless Chromium and Firefox against local HTML fixtures served in-process.

Build the docs locally with `julia --project=docs docs/make.jl`; the build
never launches a browser.

## The channel layer is generated

`src/generated/channels.jl` — one type per protocol interface, one function per
protocol command — is generated from Playwright's own protocol spec, vendored
under `protocol/spec/` at the pinned version. The generated code is checked in;
the generator never runs at build or load time and adds no runtime dependency.

```console
$ julia --project=gen gen/fetch_spec.jl        # re-vendor protocol/spec/*.yml
$ julia --project=gen gen/generate.jl          # regenerate the channel layer
$ julia --project=gen gen/generate.jl --check  # non-zero exit if it is stale
```

The user-facing API is hand-written on top of that layer: the spec carries no
documentation and no notion of the idiomatic way to call something, so a fully
generated API would be a transliteration of TypeScript rather than Julia.
**Never edit `src/generated/` by hand.**

## Status

Chromium and Firefox, on Linux, synchronous API. Milestones 1–5 are complete:
the protocol and driver layer, the broad API, driver-side waiting and retrying
assertions, artifacts and the failure path, and the documentation site.

Not yet covered: WebKit; network interception and routing; downloads, file
choosers and dialogs; HAR recording; persistent contexts; a Julia trace
*viewer* or any trace parsing; an async API. The network events (`:request`,
`:response`, …) are deferred rather than rejected — `Request` and `Response`
exist in the generated layer but have no accessors yet.

[`docs/bonnie-parity.md`](docs/bonnie-parity.md) records the driving use case:
replacing a hand-rolled CDP test harness with public API, row by row.

## Licence

MIT — see [`LICENSE`](LICENSE).
