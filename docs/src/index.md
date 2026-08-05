# Playwright.jl

Drive real browsers — Chromium and Firefox — from Julia, through the official
Playwright automation engine.

```julia
using Playwright

playwright() do pw
    browser = launch(pw.chromium; headless = true)
    try
        page = new_page(browser)
        goto(page, "https://example.com")
        expect(locator(page, "h1"); to_have_text = "Example Domain")
    finally
        close(browser)
    end
end
```

## What it is

Playwright.jl speaks Playwright's own JSON protocol to the same driver the
Node, Python and .NET clients use. There is no browser code in this package and
no scraping of anyone's internals: the driver is the upstream
`playwright-core` npm package, run by a pinned Node binary, both downloaded and
assembled on first use.

That has one consequence worth stating up front, because it decides whether
this package suits you: **the first run downloads a driver and a browser.** See
[Getting started](@ref) for how to do that once, in CI, rather than on every
run.

## What it is for

Testing Julia web applications in a real browser. The examples drive HTTP.jl,
Oxygen.jl, Genie.jl and WGLMakie.jl — a plain server, a micro-framework, a full
framework, and a WebGL app — and each one is a script you can copy.

The design leans hard on one idea, inherited from Playwright: **waiting is not
sleeping**. Every assertion retries until it holds or its timeout runs out, so
a test does not need to know how long the page will take.

```julia
# Not this
sleep(2)
@test text_content(locator(page, "#status")) == "ready"

# This
expect(locator(page, "#status"); to_have_text = "ready")
```

## Where to go next

| If you want to | Read |
|---|---|
| install it and write a first test | [Getting started](@ref) |
| find elements | [Locators](@ref) |
| stop using `sleep` | [Waiting](@ref) and [Assertions](@ref) |
| catch popups, console output, page errors | [Events](@ref) |
| get a screenshot or a trace out of a failing test | [Artifacts](@ref) |
| know which error means what | [Errors and timeouts](@ref) |
| look a function up | [API reference](@ref) |

## Status

Milestones 1–5 are complete: the protocol layer, locators and evaluation,
waiting and assertions, artifacts and the failure path, and this
documentation. The package is not registered yet.

Chromium and Firefox are supported on Linux. WebKit is not tested.
