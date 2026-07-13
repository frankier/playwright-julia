# Spec: Playwright.jl — Playwright client for Julia

## Objective

Build a Julia package (`Playwright.jl`) that lets Julia users drive real browsers
(Chromium & Firefox first) through the official Playwright automation engine, the way
`playwright-python` does for Python.

**Who is the user?** Julia developers who need browser automation: end-to-end
testing of web apps, scraping, and screenshot/PDF generation — without leaving
Julia or hand-rolling CDP.

**Milestone 1 (this spec): minimal vertical slice.** Prove the architecture
end to end. A user can:

```julia
using Playwright

playwright() do pw
    browser = launch(pw.chromium; headless=true)
    page = new_page(browser)
    goto(page, "https://example.com")
    @assert title(page) == "Example Domain"
    loc = locator(page, "h1")
    println(text_content(loc))
    click(locator(page, "a"))
    screenshot(page; path="example.png")
    close(browser)
end
```

Success looks like: the snippet above (or its equivalent) runs on a clean
machine with only Julia installed, downloading the driver and browser
automatically on first use.

## Tech Stack

- **Julia** ≥ 1.10 (LTS), pure-Julia package.
- **Playwright driver**: the official Node.js driver bundle (same one
  `playwright-python` ships), pinned to a specific Playwright version
  (latest stable at implementation time). We spawn it as a subprocess
  (`playwright run-driver` equivalent) and speak its length-prefixed
  JSON message protocol over stdin/stdout.
- **JSON.jl** for protocol (de)serialization.
- **Artifacts / lazy download** for the driver bundle: platform-specific
  driver zips fetched on first use (via a scratch space + `Downloads.jl`,
  or `Artifacts.toml` if the hosting allows). Browsers are installed via the
  driver's own `install` command into the standard Playwright cache dir.
- No Python, no user-managed Node install.

## Commands

```
Instantiate:  julia --project=. -e 'using Pkg; Pkg.instantiate()'
Test:         julia --project=. -e 'using Pkg; Pkg.test()'
REPL dev:     julia --project=.   (Revise-friendly; kaimon session available)
Format:       julia --project=. -e 'using JuliaFormatter; format(".")'
Driver setup: julia --project=. -e 'using Playwright; Playwright.install()'
```

## Project Structure

```
Project.toml            → Package metadata, deps, compat
src/Playwright.jl       → Module root, exports
src/driver.jl           → Driver download/locate/spawn, install()
src/transport.jl        → Length-prefixed JSON pipe transport (read/write loop)
src/connection.jl       → Protocol connection: message dispatch, callbacks,
                          channel-owner object registry (guid → object)
src/objects.jl          → Core object types: BrowserType, Browser,
                          BrowserContext, Page, Locator, ...
src/api.jl              → User-facing sync API: launch, new_page, goto,
                          click, fill, text_content, screenshot, ...
test/runtests.jl        → Test entry point
test/test_smoke.jl      → End-to-end smoke tests against local HTML fixtures
test/fixtures/          → Static HTML pages served locally for tests
docs/                   → (later milestone)
```

## Code Style

Idiomatic Julia: snake_case functions dispatching on concrete types, keyword
arguments for options, blocking user-facing calls backed by async internals.

```julia
"""
    goto(page::Page, url; timeout=30_000, wait_until="load") -> Union{Response,Nothing}

Navigate `page` to `url` and wait for the navigation to finish.
"""
function goto(page::Page, url::AbstractString;
              timeout::Real=30_000, wait_until::AbstractString="load")
    params = Dict{String,Any}("url" => url,
                              "timeout" => timeout,
                              "waitUntil" => wait_until)
    result = send_message(page, "goto", params)
    return from_channel(page.connection, get(result, "response", nothing))
end
```

Conventions:
- Protocol wire names stay camelCase in `Dict`s; the Julia surface is snake_case.
- Verbs as functions on objects (`click(locator)`), not property-style access.
- `Base.close` overloaded for `Browser`/`Page`/etc.; `playwright() do ... end`
  guarantees driver shutdown.
- Errors from the protocol surface as a `PlaywrightError <: Exception` carrying
  the driver's message and log.

## Testing Strategy

- Framework: stdlib `Test`, plain `@testset`s in `test/`.
- **Unit tests** (no browser): transport framing round-trips, message
  dispatch/registry logic against canned protocol traces.
- **Smoke tests** (real browser): serve `test/fixtures/*.html` via an
  in-process `HTTP.jl` server; launch headless Chromium/Firefox; exercise the full
  milestone-1 API surface (navigate, locate, click, fill, text, screenshot).
- CI note: smoke tests require the driver+browser download; gate them behind
  an env var (`PLAYWRIGHT_JL_SMOKE=1`) so unit tests stay fast and hermetic.
- Coverage expectation: every exported function exercised by at least one
  smoke test; transport/connection edge cases (partial reads, error replies,
  driver crash) unit-tested.

## Boundaries

- **Always:** run the unit test suite before commits; keep the driver version
  pinned in one place; keep wire-protocol details out of `api.jl`.
- **Ask first:** adding dependencies beyond JSON3/HTTP(test-only); changing
  the pinned Playwright version; publishing/registering the package; adding
  Firefox/WebKit support (milestone 2).
- **Never:** commit downloaded driver/browser binaries; commit secrets;
  shell out to a user-global `npx`/`node`; scrape real external websites in
  tests (fixtures only — `example.com` allowed only in README docs).

## Success Criteria

1. `Pkg.test()` passes with unit tests on a machine with no Node/browser.
2. With `PLAYWRIGHT_JL_SMOKE=1`, the smoke suite launches headless Chromium/Firefox
   and passes: goto, title, locator text_content, click (with observable DOM
   effect), fill, screenshot file produced (non-empty PNG).
3. First-use experience: `Playwright.install()` (or first `launch`) downloads
   driver + Chromium/Firefox with progress output and no manual steps.
4. The README example runs verbatim from a fresh clone.
5. Clean shutdown: after `playwright() do ... end` returns, no orphan node or
   browser processes remain.

## Open Questions

1. Driver hosting: can we point `Artifacts.toml` at the upstream Azure CDN
   zips (`playwright.azureedge.net/builds/driver/...`) directly, or do we
   lazy-download into a scratch space? (Decide during Phase 2 — affects
   `driver.jl` only.)
2. Exact exported-name set: `new_page` vs `newpage`, `text_content` vs `text`.
   Default: follow snake_case of upstream names.
3. Should `pw.chromium` be a field or `chromium(pw)`? Default: field access on
   an immutable struct — it's data, not behavior.
