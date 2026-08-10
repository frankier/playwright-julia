# Playwright.jl

Drive real browsers — Chromium, Firefox and WebKit — from Julia, through the
official Playwright automation engine.

```julia
using Playwright

playwright() do pw
    browser = launch(pw.chromium; headless = true)
    try
        page = new_page(browser)
        goto!(page, "https://example.com")
        expect(locator(page, "h1"); to_have_text = "Example Domain")
    finally
        close!(browser)
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

Testing Julia web applications in a real browser. The examples drive
[HTTP.jl](@ref), [Oxygen.jl](@ref), [Genie.jl](@ref) and [WGLMakie.jl](@ref) —
a plain server, a micro-framework, a full framework, and a WebGL app — and each
one is a script you can copy.

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

This package supports five engines — `chromium`, `firefox`, `webkit`, and
Google Chrome and Microsoft Edge as channels — on Linux, macOS and Windows.
WebKit on Windows is the one combination not covered, deliberately; see
[What differs between the engines](@ref).

It does not support service workers, trace *parsing* (traces are written, but
nothing here reads one back), or an async API. See the README for the full list
of what it covers.

It is not registered yet, so install it by URL — see
[Getting started](@ref).
