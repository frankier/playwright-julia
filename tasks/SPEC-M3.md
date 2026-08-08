# Spec: Playwright.jl — Milestone 3

Successor to [`SPEC.md`](SPEC.md) (milestone 1) and [`SPEC-M2.md`](SPEC-M2.md)
(milestone 2), both complete. Tech stack, driver architecture, two-layer
codegen/API split, code style and boundaries carry over unchanged unless
contradicted here.

## Assumptions

Calls this spec makes without being told. Correct any that are wrong.

1. **New spec, not a rewrite.** `SPEC.md` and `SPEC-M2.md` stay as the record of
   milestones 1–2; this is `SPEC-M3.md`.
2. **Layering is unchanged.** Codegen emits the channel layer into
   `src/generated/channels.jl`; everything user-facing stays hand-written in
   `src/api/`. No new runtime dependencies.
3. **Playwright stays pinned at 1.61.1.** `PLAYWRIGHT_VERSION` in `src/driver.jl`
   remains the single source of truth and selects the protocol spec.
4. **Sync-only.** Events are delivered through blocking waits and buffers, never
   by invoking user callbacks from the transport reader task. This is deliberate:
   the reader task cannot call closures defined after it started (world-age), so
   no user code runs on it, ever.
5. **Acceptance is general Playwright parity, not Bonnie parity.** The gaps below
   were found by porting Bonnie.jl's e2e suite, but the success criteria are
   phrased against upstream (`playwright-python`) semantics and this repo's own
   fixtures. Bonnie is not a dependency and not a test gate.
6. **Julia floor stays 1.10.** Nothing here needs newer.

## Objective

Milestone 2 made the API broad enough to *write* a browser test suite. Milestone 3
makes it possible to write one that is **fast, precise and quiet**: real
auto-waiting instead of hand-rolled polling, retrying assertions instead of
`sleep`, a settable default timeout instead of a 30-second stall on every miss,
and errors specific enough to branch on.

**The user** is a Julia developer writing an e2e suite. Today they hand-roll
`wait_count` / `poll_js` loops on top of a blanket `catch e isa PlaywrightError`,
thread `timeout=2_000` through every call by hand, and reach into `loc.frame` /
`loc.selector` (struct fields, not API) to evaluate JS against a located element.
Every one of those workarounds should be deletable when this milestone lands.

**The seven gaps** (numbered as raised; the spec resolves all seven):

| # | Gap | Milestone 3 |
|---|---|---|
| 1 | No `wait_for_selector` / `wait_for_function` — auto-waiting is Playwright's headline feature but is unreachable | `wait_for_selector`, `wait_for_function` on `Page`/`Frame`/`Locator` (`frame.waitForSelector`, `frame.waitForFunction` are already generated) |
| 2 | `evaluate` / `eval_on_selector` don't take a `Locator`; `fill_range!` in `SPEC-M2.md` reaches into private fields | `evaluate(loc, expr, arg)`, `evaluate_all(loc, …)`, `element_handle(loc)`; `frame(loc)` / `selector(loc)` / `is_strict(loc)` blessed as public accessors |
| 3 | No settable default timeout — a missing element stalls a retry loop for 30 s | `set_default_timeout!`, `set_default_navigation_timeout!` on `BrowserContext`/`Page`, with a documented cascade |
| 4 | `PlaywrightError` is undifferentiated — a genuine JS exception is indistinguishable from "not in the DOM yet" | Error taxonomy: `PlaywrightError` becomes abstract with `TimeoutError`, `TargetClosedError`, `DriverError` under it; `.name` preserved |
| 5 | Launch options aren't engine-partitioned — callers branch on engine to avoid sending `args` to Firefox | Probe the driver, then either document that irrelevant options are ignored, or ship `launch_options(kind; …)` |
| 6 | No engine name off a launched `Browser` — callers carry their own engine symbol | `browser_name` extended to `Browser` and **exported** (it already exists for `BrowserType`, unexported, returning a `String` — `src/objects.jl:10`); return type stays `String` for consistency |
| 7 | `install()` is awkward from a test-only dep | `bin/install.jl` entry point, `PLAYWRIGHT_BROWSERS_PATH` honoured, documented CI recipe |

Plus the two features the milestone is named for:

- **Events & waiting.** A generic, sync, buffer-backed event layer:
  `expect_event(f, target, name)` (subscribe → run body → wait, no race) and
  `wait_for_event(target, name)`. The dispatch layer is generic, but the
  **supported event set is deliberately limited to events whose payload is useful
  with the types this milestone ships** (D6): on `Page` — `:close`, `:crash`,
  `:frameattached`, `:framedetached`; on `BrowserContext` — `:page` (popups),
  `:close`, `:console`, `:pageerror`. Every other event, including the
  request/response family, is rejected outright.
- **Auto-retrying assertions.** Built on the driver's own `frame.expect` command
  (`protocol/spec/frame.yml:749`), so retrying, actionability and the call log
  come from Playwright rather than a Julia poll loop.

**Target snippet.** This must run at the end of the milestone:

```julia
using Playwright

playwright() do pw
    browser = launch(pw.chromium; headless = true)
    @assert browser_name(browser) == "chromium"          # gap 6

    ctx = new_context(browser)
    set_default_timeout!(ctx, 2_000)                     # gap 3
    page = new_page(ctx)
    goto(page, url)

    # gap 1 — real auto-waiting, no hand-rolled polling
    wait_for_selector(page, "#late")
    wait_for_function(page, "() => window.ready === true")

    # retrying assertions, driver-side
    expect(locator(page, "h1"); to_have_text = "Hello")
    expect(locator(page, "input[type=range]"; strict = false); to_have_count = 2)
    expect(locator(page, "#late"); to_be_visible = true)

    # gap 2 — evaluate against a Locator, no private fields
    slider = first(locator(page, "input[type=range]"; strict = false))
    evaluate(slider, "(el, v) => { el.value = v; el.dispatchEvent(new Event('input')) }", 7)

    # events: subscribe, act, wait — race-free
    popup = expect_event(ctx, :page) do
        click(locator(page, "#open-popup"))
    end
    @assert popup isa Page

    # gap 4 — branch precisely on failure kind
    try
        wait_for_selector(page, "#never"; timeout = 200)
    catch e
        e isa TimeoutError || rethrow()
    end

    close(browser)
end
```

## Tech Stack

Unchanged from milestone 1: pure Julia ≥ 1.10, JSON.jl at runtime, YAML.jl in
`gen/` only, HTTP.jl test-only. Playwright driver 1.61.1, assembled from the
`playwright-core` npm tarball plus a nodejs.org binary (upstream no longer
publishes driver zips).

## Commands

```
Instantiate:  julia --project=. -e 'using Pkg; Pkg.instantiate()'
Test:         julia --project=. -e 'using Pkg; Pkg.test()'
Smoke:        PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()'
Codegen:      julia --project=gen gen/generate.jl
Codegen check: julia --project=gen gen/generate.jl --check
Format:       julia --project=. -e 'using JuliaFormatter; format(".")'
Driver setup: julia --project=. -e 'using Playwright; Playwright.install()'
Driver setup (CI, package not in [deps]):
              julia bin/install.jl            # gap 7, new in this milestone
```

## Project Structure

Additions only; everything else is as milestone 2 left it.

```
src/errors.jl           → NEW. Error taxonomy: abstract PlaywrightError,
                          TimeoutError, TargetClosedError, DriverError, and
                          classification from the driver's {message,name,stack}
src/timeouts.jl         → NEW. TimeoutSettings + the cascade resolver
src/api/events.jl       → NEW. Subscription registry, expect_event, wait_for_event
src/api/expect.jl       → NEW. expect(loc; to_have_text=…) over frame.expect
src/api/waiting.jl      → NEW. wait_for_selector, wait_for_function
src/connection.jl       → CHANGED. dispatch routes named events to subscribers
src/api/locators.jl     → CHANGED. Locator accessors, evaluate on Locator
src/api/lifecycle.jl    → CHANGED. browser_name, set_default_timeout!, launch opts
bin/install.jl          → NEW. Standalone browser/driver install entry point
test/test_events.jl     → NEW. Event routing unit tests (canned traces) + smoke
test/test_expect.jl     → NEW. Retrying assertions, pass and fail paths
test/test_errors.jl     → NEW. Taxonomy classification, unit-level
test/fixtures/          → CHANGED. Fixtures for late-appearing elements, popups
```

## Code Style

Unchanged conventions: snake_case surface over camelCase wire names, verbs as
functions, `Base` overloads where the meaning matches, mutating helpers get `!`.
New in this milestone: **do-block-first for anything that must subscribe before
it acts.**

```julia
"""
    expect_event(f, target, event::Symbol; timeout=nothing, predicate=nothing)

Subscribe to `event` on `target`, run `f()`, then block until a matching event
arrives. Subscribing *before* `f` runs is the whole point — an event fired by
`f` cannot be missed. The subscription and its buffer are dropped when the block
exits, however it exits.

```julia
popup = expect_event(ctx, :page) do
    click(locator(page, "#open-popup"))
end
```
"""
function expect_event(f, target::ChannelOwner, event::Symbol;
                      timeout::Union{Real,Nothing} = nothing,
                      predicate = nothing)
    sub = subscribe(target, event)
    try
        f()
        return wait_event(sub, resolve_timeout(target, timeout); predicate)
    finally
        unsubscribe(sub)
    end
end
```

Conventions specific to M3:

- Events are `Symbol`s matching the wire name lowercased (`:pageerror`,
  `:requestfailed`), with the wire spelling accepted too.
- Timeout resolution is one function, `resolve_timeout(target, kwarg)`, called by
  every API entry point. No API function hardcodes `30_000` any more.
- Assertion failures raise `AssertionFailure <: PlaywrightError` carrying the
  driver's `received` payload — not a bare `@assert`.

## Testing Strategy

Framework and gating are unchanged: stdlib `Test`, hermetic unit tests always,
browser smoke tests behind `PLAYWRIGHT_JL_SMOKE=1`.

- **Unit (no browser):** event dispatch routing from canned protocol traces
  (event to the right subscriber, unknown guid does not kill the read loop);
  subscription lifetime — `unsubscribe` detaches *and* empties, `close(owner)`
  closes subscriptions beneath it, dispatch to a closed subscription is a no-op,
  double `close` is fine, and the registry is empty after a `expect_event` block
  that threw; error classification from canned `{message, name, stack}` payloads;
  timeout cascade resolution.
- **Smoke (real browser, Chromium *and* Firefox):** every item in the target
  snippet, plus the failure paths — `expect` that times out raises
  `AssertionFailure` with the received value in the message;
  `wait_for_selector` on a missing selector raises `TimeoutError`; a JS
  exception inside `evaluate` raises `DriverError`, **not** `TimeoutError`
  (gap 4 is only closed if these two are distinguishable).
- **Race regression:** a fixture that fires its event synchronously inside the
  triggering click must still be caught by `expect_event`.
- Coverage expectation, unchanged from M2: every newly exported function is
  exercised by at least one smoke test.

## Boundaries

- **Always:** run the hermetic suite before commits; regenerate with
  `gen/generate.jl --check` green; keep wire-protocol knowledge out of `src/api/`;
  keep timeout defaults in exactly one place.
- **Ask first:** any new runtime dependency; changing `PLAYWRIGHT_VERSION`;
  breaking a milestone-2 exported signature (the `PlaywrightError` change is
  pre-approved by this spec, see D2); registering the package.
- **Never:** run user closures on the transport reader task; commit driver or
  browser binaries; scrape external sites in tests; poll in Julia where the
  driver offers a waiting command.

## Decisions

**D1 — Events are pull-based buffers, not callbacks.** A subscription is an
**unbounded** `Channel` the reader task `put!`s into; user code drains it from its
own task. No `on(page, :console) do … end`. Rationale: sync-only was chosen
deliberately, and it sidesteps the world-age trap by construction. A callback API
can be added later on top of this without changing the wire layer.

**D1a — Subscriptions are scoped handles; the buffer dies with the scope.**
Because buffers are unbounded, a subscription left open on a chatty page grows
without limit — so lifetime is a first-class part of the design, not an
afterthought:

- The **do-block forms are primary.** `expect_event(f, target, event)` and
  `with_events(f, target, event)` unsubscribe and drop the buffer in a `finally`,
  including on exception. Documentation leads with these; a bare `subscribe` is
  documented as the escape hatch that makes you responsible for the drop.
- `subscribe` returns a mutable `Subscription` handle; `unsubscribe`/`close`
  detaches it from the registry **and** empties the channel, so the buffered
  payloads become garbage immediately rather than at some later GC of the handle.
  `close(sub)` is idempotent.
- The registry holds subscriptions **weakly** keyed by owner object, and closing
  a `Page`/`BrowserContext`/`Browser` closes every subscription beneath it: a
  dropped page must not keep its event backlog alive. Dispatch to a
  closed subscription is a no-op, never an error.
- `playwright() do … end` closing tears down the whole registry.
- A `finalizer` on `Subscription` is the last-resort net for handles the user
  leaked, not the mechanism the design relies on.

**D6 — Supported events are gated on payload usefulness.** An event is supported
only if this milestone can hand back a payload the user can actually *use*.
`:download`, `:dialog`, `:filechooser`, `:worker`, `:websocket`, `:route` and
`:bindingcall` need wrapper types that are explicit non-goals here. The network
family (`:request`, `:response`, `:requestfailed`, `:requestfinished`) is excluded
for a subtler reason: `Request`/`Response` *exist* as generated channel-owner
structs, but with no hand-written accessors the payload is an object you cannot
read a URL or a status off without dropping to the generated layer — present in
name only. All of these are **rejected with an `ArgumentError`** naming the event
and saying it is deferred, not silently served as an unusable object. Rationale:
a payload you cannot act on is a false promise, and it would make the deferred
features look half-present.
The registry and dispatch layer stay fully generic, so lifting one of these later
is one payload-mapping entry.

**D2 — `PlaywrightError` becomes abstract.** New shape:

```
PlaywrightError (abstract)
├── DriverError        — everything not otherwise classified; the old behaviour
├── TimeoutError       — driver name == "TimeoutError"
├── TargetClosedError  — page/context/browser closed under the call
└── AssertionFailure   — a retrying assertion never matched
```

All concrete types keep `.message`, `.name`, `.stack`, so `catch e isa
PlaywrightError` and `e.message` keep working. `PlaywrightError("msg")` as a
*constructor* stops working (it is an abstract type) — it is not exported for
construction and grep shows only internal call sites, which move to
`DriverError`.

**D3 — `expect` is driver-side.** Built on `frame.expect`, not a Julia poll loop,
so retries, actionability and the call log match upstream exactly. The keyword
form `expect(loc; to_have_text = "x")` maps keywords onto the protocol's
`expression` strings (`"to.have.text"`, `"to.have.count"`, `"to.be.visible"`, …).
A Julia-side `retry_until(f; timeout, interval)` is provided as the escape hatch
for conditions the driver has no expression for.

**D4 — Timeout cascade.** `call kwarg` → page setting → context setting →
package default (30 s action, 30 s navigation). Settings are stored in a side
table keyed by object, not in the protocol initializer. There is no protocol
command for this (`grep` finds no `setDefaultTimeout` in the 1.61 spec) — upstream
clients resolve it client-side and send an explicit `timeout` on every call, and
so do we.

**D5 — Gap 5 is resolved by probe, not by guess.** Before designing anything,
launch Firefox with `args`/`chromium_sandbox` and Chromium with
`firefox_user_prefs` against the real driver. If they are ignored, the fix is a
docstring sentence and nothing else ships. If they error, `launch_options(kind;
kwargs...)` filters per engine. The probe result is recorded in the plan.

## Success Criteria

1. The target snippet above runs verbatim against `test/fixtures/`, on Chromium
   and on Firefox.
2. `wait_for_selector` and `wait_for_function` are exported and work on `Page`,
   `Frame` and `Locator`; no test in the suite calls `sleep` to wait for the DOM.
3. `set_default_timeout!(ctx, 2_000)` measurably changes behaviour: a missing
   selector fails in ≈2 s, not 30 s (asserted with `@elapsed`).
4. A JS exception raised inside `evaluate` and a selector that never appears
   produce **different** exception types, both `<: PlaywrightError`.
5. `evaluate(loc, expr, arg)` exists and the `fill_range!` example in
   `SPEC-M2.md` is rewritten to use only exported API — no `loc.frame`,
   no `loc.selector`.
6. `expect_event` catches an event fired synchronously by its own do-block body
   (race regression test green), and no event is ever dropped from a live
   subscription — a fixture emitting 5 000 console messages yields 5 000.
7. Subscription lifetime is proven, not assumed: after an `expect_event` block
   returns (normally *or* by throwing), and after `close(page)` with a
   subscription still open on it, the registry holds no entry and the buffer is
   empty — asserted directly against the registry in a unit test.
8. A failing `expect(loc; to_have_text = …)` raises `AssertionFailure` whose
   message contains both the expected and the received value.
9. `browser_name` is exported and returns `"chromium"` / `"firefox"` off a
   launched `Browser`, agreeing with the existing `BrowserType` method; the
   milestone-2 tests asserting the `BrowserType` form still pass unchanged.
10. `julia bin/install.jl` installs driver and browsers from a clean checkout with
    Playwright.jl *not* in `[deps]`, and honours `PLAYWRIGHT_BROWSERS_PATH`; the
    README documents the CI recipe.
11. Gap 5 is closed one way or the other: either a docstring stating irrelevant
    launch options are ignored (with the probe as evidence), or a shipped
    `launch_options` helper.
12. Hermetic `Pkg.test()` still passes with no Node and no browser;
    `gen/generate.jl --check` still green.

## Non-Goals

Deferred again, explicitly not built here: WebKit; network interception and
routing (`route`/`fulfill`/`abort` — the `route` *event* is observable but
nothing acts on it); downloads, file chooser and dialog handling — neither the
wrapper types nor the events, which are rejected outright (D6); PDF; video and
tracing; persistent contexts; Android/Electron; an async API; callback-style
event subscription (D1); codegen of the user-facing API.

## Open Questions

All four are **resolved** (2026-08-03); recorded here for the record.

1. **`expect` spelling.** *Resolved: keyword form* — `expect(loc; to_have_text = "x")`.
2. **Event name type.** *Resolved: `Symbol`* lowercased (`:pageerror`), with the
   wire spelling also accepted.
3. **Unconsumed event buffers.** *Resolved: **unbounded** — an event is never
   dropped.* The cost of that choice is paid by lifetime scoping instead: scoped
   handles must drop the whole buffer as soon as it is definitely not needed
   again, and closing an owner closes its subscriptions. See **D1a**.
4. **Does `expect_event` on `:page` auto-wait for the popup's first navigation?**
   *Resolved: no* — return the `Page` immediately, as upstream does, and document
   it.
