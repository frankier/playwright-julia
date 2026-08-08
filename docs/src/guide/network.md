# The network

Two related things live here. You can **watch** what the page asks for, through
the network events. You can also **intercept** it with [`route!`](@ref), which
lets a test answer a request itself instead of letting it reach a server.

Interception is what frees a test from its backend. A test that mocks
`/api/items` needs no fixture database, no seeded rows and no server at all. It
can also produce the 500 that is otherwise very hard to arrange.

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
registration. Treat that as a safety net rather than a licence. An unsettled
request stops dead, and the failure surfaces thirty seconds later as an
unrelated `goto!` timeout, metres from its cause.

The warning names the URL, and it appears once per registration rather than once
per request. A handler that is wrong is usually wrong for every request, so fifty
copies of one warning would bury their own signal.

## Matching

Three kinds of matcher, everywhere a matcher is taken — [`route!`](@ref),
[`expect_request`](@ref), [`expect_response`](@ref):

| Matcher | Meaning |
|---|---|
| `AbstractString` | a glob in Playwright's dialect, matched against the **whole** URL |
| `Regex` | `occursin` against the URL — unanchored, so `r"/api/"` matches mid-URL |
| `Function` | `url -> Bool` |

### The glob dialect

This is a port of `globToRegexPattern` in playwright-core 1.61.1, and it
compiles the same globs to the same regular expressions.

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

The table below comes from `Playwright.GLOB_CASES`, which is also the list
`test/test_globs.jl` checks, so the cases below are the cases the tests cover:

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
each handler client-side. A driver glob cannot express a `Regex` or a predicate,
so either one widens that union to `**/*`. Every request on the owner then makes
the round trip to the client for filtering.

Prefer a glob when one will do. Use a `Regex` when you need one and do not
worry about it in a test suite.

## Fulfilling

```julia
fulfill!(route; json = Dict("items" => [1, 2]))     # content-type set for you
fulfill!(route; status = 404, body = "gone")
fulfill!(route; path = "test/fixtures/items.json")  # content type from the extension
fulfill!(route; body = read("logo.png"))            # bytes go base64
```

`body`, `json`, `path` and `response` are four spellings of the body, and they
are mutually exclusive. Passing two raises at the call site rather than producing
a driver error later. `status`, `headers` and `content_type` can accompany any of
them.

## Intercept, forward, modify

This is the most useful thing here, and the reason `Playwright.fetch` exists.
Make the real request, then hand the page something based on it.

```julia
with_route(ctx, "**/api/items", function (route)
    upstream = Playwright.fetch(route)                     # the real response
    fulfill!(route; response = upstream, status = 500)     # real body, forced status
end) do
    goto!(page, url)
end
```

`Playwright.fetch` is **not exported**, because `Base.fetch` and
`Distributed.fetch` both exist. Always write it qualified. That reads well here:
it marks the one call that reaches the network, beside a `fulfill!` that does
not.

The response it returns holds a driver-side buffer. Inside a handler, the
package releases that buffer when the handler returns, so **read the body
before then**.

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

The protocol puts these events on the context, never on a page, so the page
forms subscribe to the page's context and filter. Two pages in one context each
see their own traffic. A request that belongs to no page — a service worker's —
reaches the context form only.

!!! note "A response's body does not outlive its page"
    `body`, `text` and `json` on a [`Response`](@ref) fetch from the browser,
    and the browser discards a response body on navigation. Read it before
    navigating away, or the driver answers "No resource with given identifier
    found".

## Two things this deliberately does not do

**Handlers do not run concurrently.** One dispatcher task per routed owner runs
handlers sequentially, in arrival order. That makes ordering deterministic, and a
handler touching shared state needs no lock. The cost is that a slow handler
delays later requests on the same owner. `playwright-python`'s sync API pays the
same cost, and it is the right trade in a test.

**A handler has no deadline of its own.** A handler that blocks forever blocks
that owner's requests forever, and the timeout that eventually fires belongs to
the `goto!` or `click!` waiting on the page. So if a handler does I/O that can
hang, give that I/O a timeout of its own.

## Serving the whole network from an archive

[`route_from_har`](@ref) is a route handler like any other. It returns a
[`RouteRegistration`](@ref), and [`unroute!`](@ref) closes the archive. The
difference is that it answers from a recording rather than from a closure, which
is what a test needs when it wants the real API's answers and no API. It has a
guide of its own: [HAR: recording and replaying the network](@ref).

## WebSockets are intercepted, not observed

A socket is a conversation, not a request with a response, so it has no settle
and nothing to fulfill. [`route_web_socket!`](@ref) hands your handler a
[`WebSocketRoute`](@ref). The handler *sets the conversation up*: it registers
callbacks, connects if you want a proxy, then returns. The messages arrive
afterwards.

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
*mock* mode: nothing reaches the real server, and [`send_to_server!`](@ref)
raises. With it the route is a *proxy*: both directions flow, and you can rewrite
what passes through.

```julia
route_web_socket!(ctx, "**/ws") do wsr
    connect!(wsr)
    on_message_from_server!(wsr) do msg
        send_to_page!(wsr, replace(msg, "live" => "mocked"))
    end
end
```

!!! warning "A callback replaces the forwarding it intercepts"
    In proxy mode, register [`on_message_from_server!`](@ref) without calling
    [`send_to_page!`](@ref) and the route **silently swallows every server
    message**. [`on_message_from_page!`](@ref) and [`send_to_server!`](@ref)
    behave the same way. So does [`on_close!`](@ref), which replaces the default
    of closing the other side.

    This is Playwright's behaviour rather than this package's choice, and it is
    the one edge of this API worth reading twice. If a page stops receiving
    anything the moment you add a callback, this is why.

Messages are `String` for text frames and `Vector{UInt8}` for binary ones, in
both directions. The package handles the base64 the protocol uses for binary:
bytes in, bytes out, and you never set the flag yourself.

[`close_ws!`](@ref) closes the page's socket, with an optional `code` and
`reason` for the page's `onclose` to see. The name is not `close!` because the
`close!` family closes *owners* — a page, a context, a browser — and a route is
not an owner.

Registrations behave exactly like [`route!`](@ref)'s. The newest matching handler
wins, handlers run sequentially on one dispatcher task per routed owner, and
[`unroute_web_socket!`](@ref) rethrows whatever a handler or callback threw.

One difference: there is no unsettled warning. A handler that registers nothing
is a socket that mocks everything and answers nothing, which is what you want
when you are testing that a page survives a dead socket.

## What is not covered

Service workers.
