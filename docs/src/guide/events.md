# Events

Some things a page does are not requests you make — a popup opening, a console
message, an uncaught error. Those arrive as events.

The one thing to understand about them is a race: **you must be subscribed
before the action that triggers the event**. An event fired synchronously by a
click is gone before a subscription made afterwards exists. That is why the
primary form takes a block.

```julia
popup = expect_event(ctx, :page) do
    click!(locator(page, "#open-popup"))
end
```

[`expect_event`](@ref) subscribes, runs the block, and then waits for the
event. Nothing the block does can be missed.

## What you can subscribe to

| Owner | Event | Payload |
|---|---|---|
| `Page` | `:close`, `:crash` | the [`Page`](@ref) |
| `Page` | `:frameattached`, `:framedetached` | [`Frame`](@ref) |
| `BrowserContext` | `:page` | [`Page`](@ref) — this is how you catch a popup |
| `BrowserContext` | `:close` | the [`BrowserContext`](@ref) |
| `BrowserContext` | `:console` | [`ConsoleMessage`](@ref) |
| `BrowserContext` | `:pageerror` | [`PageError`](@ref) |

Anything else raises `ArgumentError`. Network events (`:request`, `:response`,
…), `:dialog` and `:download` are deferred rather than designed away: their
payload types exist in the generated layer but have no accessors yet, and
handing one back would look like support without being it.

## Filtering

`predicate` picks the event you meant out of several of the same kind. The
first payload it accepts is returned; rejected payloads are consumed, not
requeued.

```julia
msg = expect_event(ctx, :console; predicate = m -> m.text == "ready") do
    click!(locator(page, "#go"))
end
```

## Waiting for something already in flight

When the trigger is not yours — a page closing itself after a countdown that is
already running — there is nothing to put in a block, and
[`wait_for_event`](@ref) is the form to use:

```julia
wait_for_event(page, :close; timeout = 10_000)
```

Use it only in that case. When *you* trigger the event, `expect_event` exists
precisely because subscribing afterwards is a race.

## Collecting several

[`with_events`](@ref) gives the block a live [`EventStream`](@ref) instead of
waiting for one payload:

```julia
errors = with_events(ctx, :pageerror) do stream
    click!(locator(page, "#break-everything"))
    retry_until(() -> length(stream) >= 2; timeout = 5_000)
    pending_events(stream)
end
```

The buffer is **unbounded** and attached before the block runs, so nothing that
happens inside is dropped while you are not looking. It is released when the
block ends, however it ends.

Two ways to read it, and the difference matters:

- [`length`](@ref) **peeks** — it counts without consuming, so it is the thing
  to poll on;
- [`pending_events`](@ref) **drains** — everything buffered right now, and a
  second call returns only what arrived since;
- [`next_event`](@ref) blocks for one at a time, with its own `timeout` and
  `predicate`.

Polling `pending_events` in a loop waiting for a count to be reached does not
work, because each call empties the buffer it is counting. Poll `length`.

## Postmortem, not events

For "what went wrong on this page", you usually do not want events at all.
[`console_messages`](@ref) and [`page_errors`](@ref) read a buffer the driver
keeps per page, with no subscription and no block:

```julia
for err in page_errors(page)
    @warn "page error" err.message err.stack
end
```

These are safe to call from a `finally` while a more important error is in
flight — they return an empty vector rather than raising once the page has
closed. See [Artifacts](@ref).

Use events when you need to *catch the moment*; use these when you need to
*explain a failure afterwards*.
