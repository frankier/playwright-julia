# The network

Two related things live here: **watching** what the page asks for, and
**intercepting** it. Watching is the network events; intercepting is
[`route!`](@ref), which lets a test answer a request itself instead of letting
it reach a server.

Interception is what makes a test independent of a backend. A test that mocks
`/api/items` needs no fixture database, no seeded rows, and no server at all —
and it can produce the 500 that is otherwise very hard to arrange.

```julia
with_route(ctx, "**/api/items", route -> fulfill!(route; json = ["a", "b"])) do
    goto!(page, url)
    expect(locator(page, "li"; strict = false); to_have_count = 2)
end
```

## Registering a route

[`route!`](@ref) takes a target, a matcher and a handler, and returns a
registration you hand back to [`unroute!`](@ref):

```julia
reg = route!(ctx, "**/api/items", route -> abort!(route))
unroute!(ctx, reg)
```

[`with_route`](@ref) is the block form and is what you usually want, because it
unregisters even when the body throws:

```julia
with_route(ctx, "**/api/items", route -> fulfill!(route; json = mock)) do
    goto!(page, url)
    click!(locator(page, "#refresh"))
end
```

The handler is an *argument* and the body is the do-block — the opposite way
round from [`with_events`](@ref). There are two functions to pass and only one
can be the block, so the block goes to the one with statements in it.

The target is a [`Page`](@ref) or a [`BrowserContext`](@ref). A page
registration sees only that page's requests; a context registration sees every
page's.

## Settling a route

A handler **must** settle its route, with exactly one of:

| Call | Meaning |
|---|---|
| [`fulfill!`](@ref) | answer it yourself — the request never leaves the browser |
| [`abort!`](@ref) | fail it, as though the network had |
| [`continue!`](@ref) | let it proceed, optionally rewriting it on the way |

`continue!` is not the `continue` keyword. Julia's lexer reads an identifier
greedily, so `continue!` is a name — which is why this package can keep
Playwright's own vocabulary where `playwright-python` has to write `continue_`.

**A route nobody settles is continued for you**, with one warning per
registration. That is a deliberate safety net rather than a licence: an
unsettled request stops dead, and the failure surfaces thirty seconds later as
an unrelated `goto!` timeout metres from its cause. The warning names the URL
and appears once per registration, not once per request, because a handler
that is wrong is usually wrong for every request and fifty copies of the same
warning buries its own signal.

## Matching

Three kinds of matcher, everywhere a matcher is taken — [`route!`](@ref),
[`expect_request`](@ref), [`expect_response`](@ref):

| Matcher | Meaning |
|---|---|
| `AbstractString` | a glob in Playwright's dialect, matched against the **whole** URL |
| `Regex` | `occursin` against the URL — unanchored, so `r"/api/"` matches mid-URL |
| `Function` | `url -> Bool` |

### The glob dialect

Ported from `globToRegexPattern` in playwright-core 1.61.1, and verified
against it: the same 20 globs compile to byte-identical regular expressions.

| Token | Matches |
|---|---|
| `*` | any run of characters **except `/`** |
| `**` | any run of characters, `/` included |
| `{a,b}` | either alternative |
| `\x` | a literal `x` |
| anything else | itself, literally |

!!! warning "`?` is a literal, not a wildcard"
    This dialect has no single-character wildcard. `?` matches a question mark,
    which is what you want in a URL full of query strings. `[` and `]` are
    literals too — there are no character classes. Reach for a `Regex` when you
    need either.

The table below is not written by hand. It is generated from
`Playwright.GLOB_CASES`, the same list `test/test_globs.jl` asserts against, so
a case that is documented but untested cannot exist:

```@example globs
using Playwright, Markdown # hide
head = ["| Glob | URL | Matches | Why |", "|---|---|:-:|---|"] # hide
row(c) = "| `$(c.glob)` | `$(c.url)` | $(c.matches ? "yes" : "no") | $(c.note) |" # hide
Markdown.parse(join(vcat(head, map(row, Playwright.GLOB_CASES)), "\n")) # hide
```

A glob with no scheme resolves against the context's `base_url` when one is
set, so `"/api/*"` means what it looks like on a context pointed at a local
server.

### The cost of a `Regex` or a predicate

`setNetworkInterceptionPatterns` replaces the driver's whole pattern set, so
this package sends the **union** of every live registration's glob and matches
each handler client-side. Neither a `Regex` nor a predicate can be expressed as
a driver glob, so either one widens that union to `**/*` — and every request on
the owner then makes the round trip to the client to be filtered.

Prefer a glob when one will do. Use a `Regex` when you need one and do not
worry about it in a test suite.

## Fulfilling

```julia
fulfill!(route; json = Dict("items" => [1, 2]))     # content-type set for you
fulfill!(route; status = 404, body = "gone")
fulfill!(route; path = "test/fixtures/items.json")  # content type from the extension
fulfill!(route; body = read("logo.png"))            # bytes go base64
```

`body`, `json`, `path` and `response` are four spellings of the body and are
mutually exclusive — passing two raises at the call site rather than producing a
driver error later. `status`, `headers` and `content_type` may accompany any of
them.

## Intercept, forward, modify

The most useful thing here, and the reason `Playwright.fetch` exists: perform
the real request, then hand the page something based on it.

```julia
with_route(ctx, "**/api/items", function (route)
    upstream = Playwright.fetch(route)                     # the real response
    fulfill!(route; response = upstream, status = 500)     # real body, forced status
end) do
    goto!(page, url)
end
```

`Playwright.fetch` is deliberately **not exported** — `Base.fetch` and
`Distributed.fetch` both exist — so it is always written qualified. That reads
well here: it marks the one call that goes over the network, next to a
`fulfill!` that goes over none.

The response it returns holds a driver-side buffer. Inside a handler that is
released for you when the handler returns, so **read the body before then**.

## Watching without intercepting

Four events, on a [`BrowserContext`](@ref) or a [`Page`](@ref):

| Event | Payload |
|---|---|
| `:request` | [`Request`](@ref) |
| `:response` | [`Response`](@ref) |
| `:requestfinished` | [`Request`](@ref) |
| `:requestfailed` | [`RequestFailure`](@ref) |

with sugar for the two common cases:

```julia
request = expect_request(ctx, "**/api/items") do
    click!(locator(page, "#load"))
end
method(request)          # "POST"
json(request)            # the body it sent

response = expect_response(ctx, "**/api/items") do
    click!(locator(page, "#load"))
end
status(response)         # 200
json(response)           # the body it received — costs a round trip
```

The protocol has no request or response events on a page, only on the context,
so the page forms subscribe to the page's context and filter. Two pages in one
context each see their own traffic; a request belonging to no page — a service
worker's — reaches the context form only.

!!! note "A response's body does not outlive its page"
    `body`, `text` and `json` on a [`Response`](@ref) fetch from the browser,
    and the browser discards a response body on navigation. Read it before
    navigating away, or the driver answers "No resource with given identifier
    found".

## Two things this deliberately does not do

**Handlers do not run concurrently.** One dispatcher task per routed owner runs
handlers sequentially in arrival order. That makes ordering deterministic and
means a handler touching shared state needs no lock — at the cost of a slow
handler delaying later requests on the same owner. It is the same cost
`playwright-python`'s sync API pays, and it is the right trade in a test.

**A handler has no deadline of its own.** A handler that blocks forever blocks
that owner's requests forever, and the timeout that eventually fires is the
`goto!` or `click!` waiting on the page. Adding a per-handler deadline was
considered and rejected: it would need a second task per route to enforce, and
the failure it would catch — a handler that never returns — is a bug in the
handler that its own test should catch first. If a handler does I/O that can
hang, give that I/O a timeout.

## Serving the whole network from an archive

[`route_from_har`](@ref) is a route handler like any other — it returns a
[`RouteRegistration`](@ref), and [`unroute!`](@ref) closes the archive — but it
answers from a recording rather than from a closure. It is the tool for "this
test needs the real API's answers and no API", and it has a guide of its own:
[HAR: recording and replaying the network](@ref).

## WebSockets are intercepted, not observed

A socket is a conversation, not a request with a response, so it has no
settle and nothing to fulfill. [`route_web_socket!`](@ref) hands your handler a
[`WebSocketRoute`](@ref); the handler *sets the conversation up* — registers
callbacks, optionally connects — and returns. The messages arrive afterwards.

```julia
# Mock: the real server is never contacted.
with_web_socket_route(ctx, "**/ws", wsr -> on_message_from_page!(wsr) do msg
    msg == "ping" && send_to_page!(wsr, "pong")
end) do
    goto!(page, url)
    click!(locator(page, "#connect"))
end
```

**[`connect!`](@ref) is the entire mode switch.** Without it the route is in
*mock* mode: the server is never contacted, and [`send_to_server!`](@ref)
raises. With it the route is a *proxy*: both directions flow, and you can
rewrite what passes through.

```julia
route_web_socket!(ctx, "**/ws") do wsr
    connect!(wsr)
    on_message_from_server!(wsr) do msg
        send_to_page!(wsr, replace(msg, "live" => "mocked"))
    end
end
```

!!! warning "A callback replaces the forwarding it intercepts"
    In proxy mode, registering [`on_message_from_server!`](@ref) and not
    calling [`send_to_page!`](@ref) **silently swallows every server message**.
    The same is true of [`on_message_from_page!`](@ref) and
    [`send_to_server!`](@ref), and of [`on_close!`](@ref), which replaces the
    default of closing the other side.

    This is Playwright's behaviour rather than this package's choice, and it is
    the one edge of this API worth reading twice. If a page stops receiving
    anything the moment you add a callback, this is why.

Messages are `String` for text frames and `Vector{UInt8}` for binary ones, in
both directions. The base64 the protocol uses for binary is handled for you —
bytes in, bytes out, and the flag is never yours to set.

[`close_ws!`](@ref) closes the page's socket, with an optional `code` and
`reason` the page's `onclose` will see. It is not spelled `close!` because the
`close!` family closes *owners* — a page, a context, a browser — and a route is
not an owner.

Registrations behave exactly like [`route!`](@ref)'s: newest matching handler
wins, handlers run sequentially on one dispatcher task per routed owner, and an
exception a handler or callback throws is collected and rethrown at
[`unroute_web_socket!`](@ref). The one difference is that there is no unsettled
warning — a handler that registers nothing is a socket that mocks everything and
answers nothing, which is a legitimate thing to want if what you are testing is
that a page survives a dead socket.

## What is still not covered

Service workers. See the README's status section for what else is outstanding.
