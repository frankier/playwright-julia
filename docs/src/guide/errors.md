# Errors and timeouts

Every failure surfaced from the driver is a [`PlaywrightError`](@ref), so one
`catch` covers the lot:

```julia
try
    click!(locator(page, "#go"))
catch e
    e isa PlaywrightError || rethrow()
    @warn "click! failed" e.message
end
```

But the useful thing is to branch on **why** it failed, without matching on
message text:

| Type | Raised when |
|---|---|
| [`TimeoutError`](@ref) | an operation exceeded its timeout |
| [`TargetClosedError`](@ref) | the page, context or browser closed under the call |
| [`AssertionFailure`](@ref) | a retrying assertion never matched |
| [`DriverError`](@ref) | anything else, including JS exceptions |

All four carry `.message`, `.name` and `.stack`. The classification comes from
the `name` field the driver puts on its error replies, and an unrecognised name
becomes a `DriverError` — so a future Playwright release cannot produce an
error that escapes the taxonomy.

## The message includes the call log

A timeout does not just say that it timed out. The driver's call log is
appended to the message, the way upstream clients do it, so it names what the
wait was waiting for:

```
TimeoutError: Timeout 5000ms exceeded.
Call log:
  - waiting for locator("#submit")
  - locator resolved to <button disabled>…</button>
  - element is not enabled
```

That last line is the answer: the selector was fine, the button was disabled.

## Which error means what

**`TimeoutError`** — something never happened in time. The page may be slow, or
the selector may be wrong; the call log distinguishes them. Raising the timeout
is occasionally right and usually a way of not reading the log.

**`AssertionFailure`** — a retrying assertion never matched. Distinct from a
bare timeout because it names both the expected and the received value:

```
to_have_text failed on locator("h1")
  expected: "Goodbye"
  received: "Hello"
  (gave up after 5000ms of retrying)
```

**`TargetClosedError`** — a lifecycle error rather than a failure of the call.
The usual cause is a `close` in a `finally` racing work still in flight, or
acting on a page whose context has already gone.

**`DriverError`** — the catch-all, and what a JavaScript exception inside
[`evaluate`](@ref) becomes:

```julia
try
    evaluate(page, "() => { throw new Error('boom') }")
catch e
    e isa DriverError && occursin("boom", e.message)
end
```

## Timeouts cascade

Every `timeout` keyword falls back through a chain: the call's own keyword,
then the page's setting, then the context's, then 30 seconds.

```julia
ctx = new_context(browser)
set_default_timeout!(ctx, 2_000)       # a missing element fails in 2 s
page = new_page(ctx)
set_default_timeout!(page, 5_000)      # ...but this page gets 5 s
```

Setting it once on the context is the usual move. The 30-second default is
generous for a passing suite and painful for a failing one — twenty missing
elements is ten minutes of waiting for an answer you already know.

[`set_default_navigation_timeout!`](@ref) does the same for navigations.
Navigations fall back to the action setting when they have none of their own,
so setting only the action default also shortens navigations rather than
leaving them at 30 seconds.

`launch`'s own `timeout` is deliberately **outside** the cascade: it bounds
browser startup, where there is no page or context to inherit from.

## Postmortem readers do not raise

[`console_messages`](@ref) and [`page_errors`](@ref) return an **empty vector
rather than raising** once the page or context has closed.

They are postmortem readers, usually called from a `finally` while a more
important error is already in flight. Throwing there would mask the failure you
were trying to explain, and "the page is gone" tells a caller who is already
handling an error nothing they can use.

The silence is bounded: that one error type, those readers only, and every
other failure still propagates.

## A note on numbers

JavaScript has one number type, so `evaluate` returns `Float64`:

```julia
evaluate(page, "1 + 1")        # 2.0
evaluate(page, "1 + 1") == 2   # true
```

Not an error, but it is the kind of thing that produces a confusing failure in
a `@test` that compares types rather than values.

## Changed in milestone 3

`PlaywrightError` used to be a concrete struct and is now an abstract
supertype. `catch e isa PlaywrightError` and `e.message` are unaffected; only
`PlaywrightError(msg)` as a *constructor* breaks — use
[`DriverError`](@ref)`(msg)`. Construction was internal to this package.
