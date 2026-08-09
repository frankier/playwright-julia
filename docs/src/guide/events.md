# Events

Some things a page does are not requests you make — a popup opening, a console
message, an uncaught error. Those arrive as events.

The one thing to understand about them is a race: **subscribe before the action
that triggers the event**. A click can fire an event synchronously, and that
event is gone before a later subscription exists. So the primary form takes a
block.

```julia
popup = expect_event(ctx, :page) do
    click!(locator(page, "#open-popup"))
end
```

[`expect_event`](@ref) subscribes, runs the block, then waits for the event. It
cannot miss anything the block does.

## What you can subscribe to

| Owner | Event | Payload |
|---|---|---|
| `Page` | `:close`, `:crash` | the [`Page`](@ref) |
| `Page` | `:frameattached`, `:framedetached` | [`Frame`](@ref) |
| `Page` | `:download` | [`Download`](@ref) — see [`expect_download`](@ref) |
| `Page` | `:filechooser` | [`FileChooser`](@ref) — see [`expect_file_chooser`](@ref) |
| `BrowserContext` | `:page` | [`Page`](@ref) — this is how you catch a popup |
| `BrowserContext` | `:close` | the [`BrowserContext`](@ref) |
| `BrowserContext` | `:console` | [`ConsoleMessage`](@ref) |
| `BrowserContext` | `:pageerror` | [`PageError`](@ref) |
| `BrowserContext` or `Page` | `:request` | [`Request`](@ref) |
| `BrowserContext` or `Page` | `:response` | [`Response`](@ref) |
| `BrowserContext` or `Page` | `:requestfinished` | [`Request`](@ref) |
| `BrowserContext` or `Page` | `:requestfailed` | [`RequestFailure`](@ref) |

Anything else raises `ArgumentError`, and the message says which of two things
went wrong. Some events are **deferred**, and they come in two kinds.

The first kind has no readable payload. `:worker` and `:bindingcall` are here.
Their payload types exist in the generated layer but have no accessors, so the
event would hand you back nothing usable.

The second kind has a payload you can read, but no event-shaped API. `:route` is
here: [`Route`](@ref) is wrapped and fully usable, but you intercept with
[`route!`](@ref) or [`with_route`](@ref). An event would hand you a route with
no guarantee that anyone settles it.

`:websocket` sits in both kinds, and it is easy to read the wrong half into it.
Observing a socket yields a `WebSocket` with no accessors, so that event stays
deferred. Sockets themselves work: use [`route_web_socket!`](@ref) instead of an
event. "No accessors yet" describes the observation, not WebSockets.

`:dialog` is `:route`'s case, and permanently so. Answer dialogs through
[`with_dialog`](@ref) and the handler registry. On the wire, subscribing is
*what* disables the driver's auto-dismiss — see
[Files, dialogs and uploads](@ref).

### The network events are the context's, even on a page

The protocol puts no request or response event on a page. They live on the
`BrowserContext`, and each one carries the page it belongs to. So
`expect_event(page, :request)` subscribes to the page's *context* and filters
out the other pages' traffic. Two pages in one context each see their own.

That matters for one practical reason. A request that belongs to no page — a
service worker's — reaches the context form and not the page form.

The two common cases have sugar, because the predicate is the part people get
wrong:

```julia
request = expect_request(ctx, "**/api/todos") do
    click!(locator(page, "#load"))
end

response = expect_response(page, "**/api/todos") do
    click!(locator(page, "#load"))
end
```

Both take the same matcher union as [`route!`](@ref): a glob, a `Regex`, or a
`url -> Bool` predicate.

## Filtering

`predicate` picks the event you meant out of several of the same kind. The first
payload it accepts is the one you get. It consumes the payloads it rejects, and
does not requeue them.

```julia
msg = expect_event(ctx, :console; predicate = m -> m.text == "ready") do
    click!(locator(page, "#go"))
end
```

## Waiting for something already in flight

Sometimes the trigger is not yours: a page closes itself after a countdown that
is already running. There is nothing to put in a block, so use
[`wait_for_event`](@ref):

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

The buffer is **unbounded**, and it attaches before the block runs, so it drops
nothing that happens inside while you are not looking. `with_events` releases it
when the block ends, however it ends.

Three ways to read it, and the difference matters:

- [`length`](@ref) **peeks**. It counts without consuming, so this is the one to
  poll on.
- [`pending_events`](@ref) **drains**. It returns everything buffered right now,
  and a second call returns only what arrived since.
- [`next_event`](@ref) blocks for one payload at a time, with its own `timeout`
  and `predicate`.

Do not poll `pending_events` in a loop waiting for a count. Each call empties
the buffer it is counting. Poll `length` instead.

## Postmortem, not events

For "what went wrong on this page", you usually do not want events at all.
[`console_messages`](@ref) and [`page_errors`](@ref) read a buffer the driver
keeps per page, with no subscription and no block:

```julia
for err in page_errors(page)
    @warn "page error" err.message err.stack
end
```

Call these from a `finally` while a more important error is in flight. Once the
page closes they return an empty vector rather than raising. See
[Artifacts](@ref).

Use events to *catch the moment*. Use these to *explain a failure afterwards*.
