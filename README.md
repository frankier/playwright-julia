# Playwright.jl

Drive real browsers from Julia through the official
[Playwright](https://playwright.dev) automation engine — end-to-end testing,
scraping, and screenshot/PDF generation without leaving Julia or hand-rolling
CDP. The same architecture as `playwright-python`: a pinned Playwright driver
(Node.js) runs as a subprocess and Julia speaks its JSON protocol over stdio.

## Quick start

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

This runs on a clean machine with only Julia installed: the first use
downloads the Playwright driver and the browser automatically. To do the
downloads ahead of time (recommended for CI):

```julia
using Playwright
Playwright.install()          # driver + Chromium + Firefox
```

Browsers land in the standard Playwright cache (`~/.cache/ms-playwright`),
shared with any other Playwright installation on the machine. The driver
lives in a Julia scratch space keyed by the pinned Playwright version.

## API (milestone 1)

| Function | Purpose |
|---|---|
| `playwright(f)` | Start the driver, run `f(pw)`, guarantee shutdown |
| `pw.chromium`, `pw.firefox` | The launchable `BrowserType`s |
| `launch(bt; headless=true)` | Launch a browser |
| `new_page(browser)` | New page in a fresh context |
| `goto(page, url; timeout=30_000, wait_until="load")` | Navigate |
| `title(page)` | Document title |
| `locator(page, selector)` | Lazy, strict selector handle |
| `text_content(loc)` | Element's text content |
| `click(loc)` | Click (waits for actionability) |
| `fill(loc, value)` | Set an input's value (extends `Base.fill`) |
| `input_value(loc)` | Read an input's value |
| `screenshot(page; path=nothing)` | PNG screenshot, returned and/or written |
| `close(page)`, `close(browser)` | Close (extends `Base.close`) |

Failures surface as `PlaywrightError` carrying the driver's message and its
call log (so a timeout tells you which selector it was waiting for).

## Testing

```
julia --project=. -e 'using Pkg; Pkg.test()'                       # hermetic unit tests
PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()' # + real-browser smoke tests
```

Unit tests need no Node.js or browsers. The smoke suite launches headless
Chromium and Firefox against local HTML fixtures served in-process.

## Status

Milestone 1: a minimal vertical slice proving the architecture — Chromium and
Firefox, the API above, sync only. Not yet covered: WebKit, events, network
interception, downloads, tracing, and the rest of Playwright's surface.
