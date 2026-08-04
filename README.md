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

### Installing browsers in CI

`Playwright.install()` needs Playwright.jl to be loadable, which is exactly what
a project carrying it as a **test** dependency does not have outside
`Pkg.test()`. `bin/install.jl` is the way in — it runs standalone, activating
the checkout itself if the active environment cannot load the package:

```console
$ julia bin/install.jl                 # driver + Chromium + Firefox
$ julia bin/install.jl chromium        # just the one you need
```

An unknown browser name is rejected before anything downloads.

Set `PLAYWRIGHT_BROWSERS_PATH` to put browsers somewhere you control, which is
usually easier to cache and restore in CI than a path in the home directory.
Installing and launching both read it — the driver subprocess inherits Julia's
environment — so set it once, in the shell or in `ENV`, and the two agree:

```console
$ export PLAYWRIGHT_BROWSERS_PATH="$PWD/.playwright"
$ julia bin/install.jl chromium
```

For a package with Playwright.jl in `[targets] test` rather than `[deps]`, a
GitHub Actions job looks like this. The cache key is the Playwright version,
because that is what decides which browser build is needed:

```yaml
- uses: julia-actions/setup-julia@v2
- uses: julia-actions/cache@v2

- name: Cache Playwright browsers
  uses: actions/cache@v4
  with:
    path: ~/.cache/ms-playwright
    key: playwright-${{ runner.os }}-1.61.1

- name: Install browsers
  run: julia --project=. -e 'using Pkg; Pkg.instantiate()' &&
       julia --project=. ~/.julia/packages/Playwright/*/bin/install.jl chromium

- uses: julia-actions/julia-runtest@v1
```

If you would rather not chase the package path, the same thing in one line
against the test environment:

```console
$ julia --project=. -e 'using Pkg; Pkg.activate(temp=true); Pkg.add("Playwright"); using Playwright; Playwright.install(browsers=["chromium"])'
```

`Playwright.browsers_path()` reports where browsers will be looked for, which
is the first thing to check when a launch cannot find one.

## A fuller example

```julia
using Playwright

playwright() do pw
    browser = launch(pw.chromium; headless=true, chromium_sandbox=false,
                     args=["--disable-dev-shm-usage"])
    ctx = new_context(browser; viewport=(width=1280, height=720))
    page = new_page(ctx)
    goto(page, url)

    # Arbitrary JavaScript, values in and out
    @assert evaluate(page, "1 + 1") == 2
    @assert evaluate(page, "x => x.a * 2", (a = 21,)) == 42

    # Several matches: countable, indexable, iterable
    sliders = locator(page, "input[type=range]"; strict=false)
    @assert count(sliders) == 2
    for slider in sliders
        println(input_value(slider))
    end

    # Reach into an iframe
    inner = frame_locator(page, "iframe")
    click(locator(inner, "button"))
    println(evaluate(content_frame(inner), "document.title"))

    # Keep a value in the browser; released on the way out of the block
    evaluate_handle(page, "() => window.app") do app
        @assert evaluate(app, "a => a.ready") === true
    end

    # Why did that fail?
    for err in page_errors(page)
        @warn "page error" err.message
    end

    close(ctx)
    close(browser)
end
```

## API

### Lifecycle

| Function | Purpose |
|---|---|
| `playwright(f)` | Start the driver, run `f(pw)`, guarantee shutdown |
| `pw.chromium`, `pw.firefox` | The launchable `BrowserType`s |
| `launch(bt; headless=true, …)` | Launch a browser — see options below |
| `new_context(browser; viewport, user_agent, …)` | Isolated profile; the unit of test isolation |
| `new_page(browser)` / `new_page(context)` | New page; from a browser it owns the context it created |
| `contexts(browser)`, `pages(context)` | What is currently open |
| `close(page)`, `close(context)`, `close(browser)` | Close (extends `Base.close`) |

`launch` options, all optional and omitted from the wire when unset: `args`,
`chromium_sandbox`, `env`, `firefox_user_prefs`, `executable_path`, `channel`,
`slow_mo`, `proxy`, `downloads_path`. `executable_path` and `channel` are what
make `CHROME_BIN`-style provisioning work against a browser the machine
already has.

### Navigation and capture

| Function | Purpose |
|---|---|
| `goto(page, url; timeout=30_000, wait_until="load")` | Navigate |
| `title(page)` | Document title |
| `screenshot(page; path=nothing)` | PNG screenshot, returned and/or written |

### Locators

| Function | Purpose |
|---|---|
| `locator(page, selector; strict=true)` | Lazy selector handle |
| `count(loc)`, `nth(loc, i)`, `first(loc)`, `last(loc)` | Work with several matches (`nth` is 1-based) |
| iteration, `loc[i]`, `collect(loc)` | One single-element `Locator` per match |
| `click(loc)`, `fill(loc, value)` | Act (waits for actionability) |
| `dispatch_event(loc, type, event_init=missing)` | Fire a synthetic DOM event |
| `text_content(loc)`, `inner_text(loc)`, `inner_html(loc)` | Read content |
| `input_value(loc)`, `get_attribute(loc, name)` | Read values |
| `is_visible(loc)`, `is_checked(loc)`, `is_enabled(loc)` | Read state |

A `Locator` is iterable but deliberately **not** an `AbstractArray`: indexing
is a network call and the length is not stable. Iteration samples the match
set once, with a `count` round-trip, when the loop starts.

### JavaScript

| Function | Purpose |
|---|---|
| `evaluate(target, expression, arg=missing)` | Run JS in a page, frame or handle; returns a Julia value |
| `evaluate_handle(target, expression, arg=missing)` | Keep the result in the browser as a `JSHandle` |
| `evaluate_handle(f, target, expression, …)` | Block form — disposes the handle on the way out, throw or not |
| `dispose(handle)` | Release a handle explicitly |
| `eval_on_selector(target, selector, expression, …)` | Run JS with the matched element as its argument |
| `eval_on_selector_all(target, selector, expression, …)` | ...with *all* matches as an array |

Numbers come back as `Float64` — JavaScript has one number type — so
`evaluate(page, "1 + 1")` is `2.0`, which still `== 2`.

### Frames

| Function | Purpose |
|---|---|
| `frames(page)` | Main frame first, then descendants |
| `frame_locator(page, selector)` | Scope into an iframe |
| `locator(fl, selector)` | Address an element inside it |
| `content_frame(fl_or_loc)` | The `Frame` an iframe element contains |
| `owner_frame(loc)` | The frame containing an element |
| `parent_frame(frame)`, `url(frame)`, `name(frame)` | Frame tree and identity |

### Diagnostics

| Function | Purpose |
|---|---|
| `console_messages(page)` | Buffered `ConsoleMessage`s (`type`, `text`, `location`, `timestamp`) |
| `page_errors(page)` | Uncaught `PageError`s (`message`, `name`, `stack`) |
| `clear_console_messages(page)`, `clear_page_errors(page)` | Reset the buffers for per-test isolation |

Failures surface as a `PlaywrightError` carrying the driver's message and its
call log (so a timeout tells you which selector it was waiting for).

### Waiting

Wait driver-side rather than sleeping. The condition is re-checked *in the
browser*, so a late element is picked up the moment it arrives:

| Function | Purpose |
|---|---|
| `wait_for_selector(target, sel; state)` | Wait for `:attached`, `:detached`, `:visible` or `:hidden` |
| `wait_for_function(target, expr, arg; polling)` | Wait for a JS predicate to go truthy |

Both work on a `Page`, a `Frame` or a `Locator`.

```julia
wait_for_selector(page, "#late"; state=:visible)
wait_for_function(page, "() => window.ready === true")
```

### Retrying assertions

`expect` retries in the browser until the condition holds or the timeout runs
out, and returns the locator so calls chain:

```julia
expect(locator(page, "h1"); to_have_text = "Hello")
expect(locator(page, "li"; strict=false); to_have_count = 3)
expect(locator(page, "#box"); to_have_value = r"^se")
expect(locator(page, "#link"); to_have_attribute = "href" => "/somewhere")
expect(locator(page, "#gone"); to_be_visible = false)
expect(locator(page, "h1"); to_have_text = Not("Goodbye"))
```

Matchers: `to_have_text`, `to_contain_text`, `to_have_value`, `to_have_count`,
`to_have_attribute`, `to_be_visible`, `to_be_hidden`, `to_be_enabled`,
`to_be_disabled`, `to_be_checked`. Wrap any expectation in `Not(...)` to negate
it.

A failure raises `AssertionFailure` naming both values, so you do not have to
re-run the test to find out what was actually there:

```
to_have_text failed on locator("h1")
  expected: "Goodbye"
  received: "Hello"
  (gave up after 5000ms of retrying)
```

`retry_until(f; timeout, interval)` is the escape hatch for conditions `expect`
cannot express. Prefer `expect` where it fits — it retries inside the browser,
so it neither round-trips per attempt nor misses a state that flickers between
polls.

### Events

Subscribing happens *before* the action that triggers the event, which is why
the primary form takes a block — an event fired synchronously by the action is
still caught:

```julia
popup = expect_event(ctx, :page) do
    click(locator(page, "#open-popup"))
end

msg = expect_event(ctx, :console; predicate = m -> m.text == "ready") do
    click(locator(page, "#go"))
end
```

| Owner | Event | Payload |
|---|---|---|
| `Page` | `:close`, `:crash` | the `Page` |
| `Page` | `:frameattached`, `:framedetached` | `Frame` |
| `BrowserContext` | `:page` | `Page` — this is how you catch a popup |
| `BrowserContext` | `:close` | the `BrowserContext` |
| `BrowserContext` | `:console` | `ConsoleMessage` |
| `BrowserContext` | `:pageerror` | `PageError` |

Anything else raises `ArgumentError`. Network events (`:request`, `:response`,
…), `:dialog` and `:download` are deferred rather than designed away — their
payload types have no accessors yet, so handing one back would look like
support without being it.

`wait_for_event(target, event)` waits for something already in flight, and
`with_events(f, target, event)` collects several:

```julia
errors = with_events(ctx, :pageerror) do stream
    click(locator(page, "#break-everything"))
    retry_until(() -> length(stream) >= 1; timeout=5_000)
    pending_events(stream)
end
```

Buffers are unbounded, so nothing that happens inside the block is dropped.
`length(stream)` peeks; `pending_events(stream)` drains.

### Default timeouts

Every `timeout` keyword defaults to a cascade — the call's own keyword, then
the page's setting, then the context's, then 30 s — so one setting shortens
every wait beneath it, instead of each miss costing 30 s:

```julia
ctx = new_context(browser)
set_default_timeout!(ctx, 2_000)       # a missing element fails in 2 s
page = new_page(ctx)
set_default_timeout!(page, 5_000)      # ...but this page gets 5 s
```

`set_default_navigation_timeout!` does the same for navigations, which fall
back to the action setting when they have none of their own. `launch`'s own
`timeout` is deliberately outside the cascade: it bounds browser *startup*,
where there is no page or context to inherit from.

### Errors

Branch on the kind of failure rather than on message text:

| Type | Raised when |
|---|---|
| `TimeoutError` | an operation exceeded its timeout |
| `TargetClosedError` | the page, context or browser closed under the call |
| `AssertionFailure` | a retrying assertion never matched |
| `DriverError` | anything else, including JS exceptions |

All four are `<: PlaywrightError` and carry `.message`, `.name` and `.stack`,
so `catch e isa PlaywrightError` still catches everything.

> **Changed in milestone 3.** `PlaywrightError` was a concrete struct and is now
> an abstract supertype. `catch e isa PlaywrightError` and `e.message` are
> unaffected; only `PlaywrightError(msg)` as a *constructor* breaks — use
> `DriverError(msg)`. Construction was internal to this package.

## Testing

```
julia --project=. -e 'using Pkg; Pkg.test()'                       # hermetic unit tests
PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()' # + real-browser smoke tests
```

Unit tests need no Node.js or browsers. The smoke suite launches headless
Chromium and Firefox against local HTML fixtures served in-process.

## The channel layer is generated

`src/generated/channels.jl` — one type per protocol interface and one function
per protocol command — is generated from Playwright's own protocol spec,
vendored under `protocol/spec/` at the pinned version. The generated code is
checked in; the generator never runs at build or load time and adds no runtime
dependency.

```
julia --project=gen gen/fetch_spec.jl        # re-vendor protocol/spec/*.yml
julia --project=gen gen/generate.jl          # regenerate the channel layer
julia --project=gen gen/generate.jl --check  # non-zero exit if it is stale
```

The user-facing API above is hand-written on top of that layer: the spec
carries no documentation and no notion of the idiomatic way to call something,
so a fully generated API would be a transliteration of TypeScript rather than
Julia. Never edit `src/generated/` by hand.

## Status

Milestone 3: fast, precise and quiet. Driver-side waiting instead of
hand-rolled polling, retrying assertions instead of `sleep`, a settable default
timeout instead of a 30 s stall per miss, an error taxonomy specific enough to
branch on, race-free event subscription, `evaluate` on a `Locator`, and a
standalone browser installer. Chromium and Firefox, sync only.

Milestone 2 got the API broad enough to *write* an end-to-end suite:
`evaluate` and the value codec, frames and iframes, multi-match locators,
`dispatch_event`, full launch options, explicit context lifecycle, and
console/error diagnostics.

[`docs/bonnie-parity.md`](docs/bonnie-parity.md) records the driving use case:
replacing a hand-rolled CDP test harness with public API, row by row.

Not yet covered: WebKit; network interception and routing; downloads, file
choosers and dialogs; PDF; video and tracing; persistent contexts; an async
API. The network events (`:request`, `:response`, …) are deferred rather than
rejected — `Request` and `Response` exist in the generated layer but have no
accessors yet, so lifting them is a payload-mapping entry plus a small
accessor set.
