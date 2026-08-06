# Waiting

Browsers are asynchronous and pages are slow in ways that vary run to run. The
whole difficulty of browser testing is deciding *when* to look. There are two
answers, and only one of them works.

```julia
sleep(2)                                             # hope
wait_for_selector(page, "#late"; state = :visible)    # know
```

A `sleep` is wrong in both directions at once: too short on a loaded CI runner,
and wasted on every run where the page was fast. The cost compounds — a suite
of two hundred tests with a two-second sleep each spends seven minutes doing
nothing.

## Wait driver-side

Everything in this package waits **in the browser**, not in Julia. The
condition is re-checked by the driver, so an element that arrives late is
picked up the moment it arrives rather than at the next poll.

| Call | Waits for |
|---|---|
| [`expect`](@ref) | an assertion to hold — see [Assertions](@ref) |
| [`wait_for_selector`](@ref) | an element to reach a DOM state |
| [`wait_for_function`](@ref) | a JavaScript predicate to go truthy |
| [`retry_until`](@ref) | anything else, polled from Julia |
| [`click!`](@ref) and the other actions | the element to be actionable |

Actions waiting on their own is the part that is easy to miss: `click!` already
waits for its target to be attached, visible, stable, able to receive events
and not disabled. Most of the time no explicit wait is needed at all.

## `wait_for_selector`

```julia
wait_for_selector(page, "#late"; state = :visible)
wait_for_selector(page, "#spinner"; state = :hidden)
```

`state` is one of `:attached`, `:detached`, `:visible` or `:hidden`. The
default is `:visible`, which is what you want the great majority of the time —
an element present in the DOM but not shown is not something a user can use.

It returns an [`ElementHandle`](@ref) (or `nothing` for `:detached` and
`:hidden`), and raises [`TimeoutError`](@ref) if the state never arrives. It
works on a `Page`, a `Frame` or a `Locator`.

## `wait_for_function`

For a condition that is about the page rather than about one element:

```julia
wait_for_function(page, "() => window.appReady === true")
wait_for_function(page, "n => document.querySelectorAll('li').length >= n", 3)
```

The expression is evaluated in the browser until it returns something truthy.
`polling` chooses between `"raf"` (every animation frame, the default) and a
number of milliseconds.

This is the tool for application-level readiness — a framework that sets a flag
when it has hydrated, say. It sees the page's own state, which no DOM selector
can.

## `retry_until`

The escape hatch, and the only one of these that polls from the Julia side.
Use it when the condition is not about the page at all.

```julia
retry_until(; timeout = 60_000, interval = 200, on_error = :retry) do
    HTTP.get(url).status == 200
end
```

Two keywords carry the weight:

| Keyword | Values | Meaning |
|---|---|---|
| `on_timeout` | `:throw` (default), `:false` | raise [`AssertionFailure`](@ref), or return `false` |
| `on_error` | `:throw` (default), `:retry` | propagate a predicate exception, or treat it as "not yet" |

`on_error = :retry` is the one that makes waiting for a server possible. While
a web framework is starting, a request does not return a bad status — it throws
*connection refused*. Treating that exception as "not yet" is the difference
between a wait that works and a wait that crashes on its first attempt:

```julia
# examples/common.jl, near enough
function wait_for_server(url; timeout = 60_000)
    ok = retry_until(; timeout, interval = 200, on_error = :retry, on_timeout = :false) do
        HTTP.get(url; retry = false, status_exception = true)
        true
    end
    ok || error("server at $url did not come up within $(timeout)ms")
end
```

The [Genie.jl](@ref) example measures what this is worth: 25 seconds between
`up()` returning and the first request being answered, on an idle workstation.
A `sleep` long enough to cover that is a `sleep` paid on every other example
forever. [WGLMakie.jl](@ref) does the same for rendering, where a cold first
paint took 57.9 seconds.

`on_timeout = :false` is what lets a check sit inside `@test` and report a
`Test.Fail` rather than an `Error`, so the testset summary reads correctly:

```julia
@test retry_until(page; on_timeout = :false) do
    length(console_messages(page)) >= 3
end
```

Prefer [`expect`](@ref) whenever it fits. `retry_until` round-trips per attempt
and can miss a state that flickers between polls; `expect` re-checks inside the
browser and cannot.

## Timeouts cascade

Every `timeout` keyword falls back through a chain: the call's own keyword,
then the page's setting, then the context's, then 30 seconds.

```julia
ctx = new_context(browser)
set_default_timeout!(ctx, 2_000)       # a missing element fails in 2 s
page = new_page(ctx)
set_default_timeout!(page, 5_000)      # ...but this page gets 5 s
```

Setting it once on the context is usually right: the default of 30 seconds per
miss is generous for a passing suite and painful for a failing one.

[`set_default_navigation_timeout!`](@ref) does the same for navigations, which
fall back to the action setting when they have none of their own — so setting
only the action default also shortens navigations rather than leaving them at
30 seconds.

`launch`'s own `timeout` is deliberately outside the cascade: it bounds browser
*startup*, where there is no page or context to inherit from.

See [Errors and timeouts](@ref) for what happens when the budget runs out.
