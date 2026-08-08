# WebSocket routing: intercept a socket, mock it entirely, or proxy it and
# rewrite messages in flight.
#
# This is the **third** use of the registry + dispatcher-task shape, after
# routing.jl (M6) and dialogs.jl (M7). It is a reuse rather than an invention,
# and the differences from routing.jl are few enough to list:
#
#   - There is no unsettled-route warning, because a WebSocket route has no
#     settle (D11). A handler that registers nothing is a socket that mocks
#     everything and answers nothing, which is a legitimate thing to want.
#   - The handler *sets up* a conversation and returns; the messages arrive
#     afterwards, on the dispatcher. It is not a loop and it does not block.
#   - The events belong to the route object itself rather than to a Page or a
#     BrowserContext (D13), and the route is short-lived — so its subscriptions
#     must be dropped when it goes, or the table grows for the process lifetime.
#
# It lives apart from routing.jl despite the shared shape because routing.jl is
# already 800 lines.
#
# Why a task at all, as ever: `events.jl` opens with "Nothing here invokes user
# code. The transport reader task cannot call closures defined after it started
# (world age)". A WebSocket handler is user code that also calls back into the
# driver, so running it on the reader task is doubly impossible.

# --- Registration and registry ---------------------------------------------

"""
    WebSocketRouteRegistration

One live [`route_web_socket!`](@ref) call, returned so it can be handed back to
[`unroute_web_socket!`](@ref).

Carries the exceptions its handler threw. They are not raised where they happen
— there is no user task there — so they are collected and rethrown when the
registration is released, exactly as [`RouteRegistration`](@ref)'s are.
"""
mutable struct WebSocketRouteRegistration
    matcher::Any
    handler::Any
    exceptions::Vector{Any}
    active::Bool
end

WebSocketRouteRegistration(matcher, handler) =
    WebSocketRouteRegistration(matcher, handler, Any[], true)

"Per-owner WebSocket routing state: registrations, subscription, dispatcher."
mutable struct WebSocketRouteRegistry
    owner::ChannelOwner
    registrations::Vector{WebSocketRouteRegistration}  # oldest first
    subscription::Union{Subscription,Nothing}
    task::Union{Task,Nothing}
    lock::ReentrantLock
    # Held for the whole of one route's handling, so unroute_web_socket! can
    # wait for an in-flight handler before returning. Re-entrant: a handler
    # that unregisters itself is legal and must not deadlock against itself.
    dispatching::ReentrantLock
end

WebSocketRouteRegistry(owner) = WebSocketRouteRegistry(
    owner,
    WebSocketRouteRegistration[],
    nothing,
    nothing,
    ReentrantLock(),
    ReentrantLock(),
)

const WS_ROUTE_REGISTRIES = Dict{String,WebSocketRouteRegistry}()
const WS_ROUTE_REGISTRIES_LOCK = ReentrantLock()

ws_registry_for(owner::ChannelOwner) =
    lock(WS_ROUTE_REGISTRIES_LOCK) do
        get(WS_ROUTE_REGISTRIES, owner.guid, nothing)
    end

# --- The dispatcher's lifetime ---------------------------------------------

"""
Start the dispatcher for `registry` if it is not already running.

On the *first* registration and not before: a package that spawns a task per
owner whether or not anyone routes is a package that leaks a task per page.
"""
function start_ws_dispatcher!(registry::WebSocketRouteRegistry)
    registry.task === nothing || return registry.task
    # Keyed on the owner the caller named. The probe found delivery is
    # symmetric — a context-armed pattern is delivered on the context, a
    # page-armed one on the page — so no filtering step is needed (T17, OQ2).
    sub = subscribe(
        registry.owner,
        "webSocketRoute",
        channel_payload("webSocketRoute", WebSocketRoute),
    )
    registry.subscription = sub
    registry.task = @async dispatch_web_socket_routes(registry, sub)
    return registry.task
end

"""
Stop the dispatcher and wait for it to finish.

Closing the channel wakes it: `take!` on a closed channel raises, which is the
loop's exit. No sentinel, no polling, and no `sleep`.
"""
function stop_ws_dispatcher!(registry::WebSocketRouteRegistry)
    task = registry.task
    sub = registry.subscription
    registry.task = nothing
    registry.subscription = nothing
    sub === nothing || (close(sub); close(sub.channel))
    # The dispatcher never rethrows a handler's exception, so a failure here
    # would be a bug in the dispatcher itself. Surface it.
    task === nothing || wait(task)
    return nothing
end

"""
The dispatcher loop: one per routed owner, handlers run sequentially in arrival
order.

Sequential for M6's reasons — deterministic ordering, and a user closure
touching shared state needs no lock of its own.
"""
function dispatch_web_socket_routes(registry::WebSocketRouteRegistry, sub::Subscription)
    while true
        route = try
            take!(sub.channel)
        catch
            break            # channel closed: stop_ws_dispatcher! was called
        end
        route isa WebSocketRoute || continue
        try
            lock(registry.dispatching) do
                handle_web_socket_route(registry, route)
            end
        catch e
            # handle_web_socket_route catches everything a handler throws, so
            # reaching here is a bug in the dispatcher. Dying quietly would
            # strand every later socket on this owner.
            @error "WebSocket route dispatcher failed; later sockets on this " *
                   "owner will not be intercepted" exception = (e, catch_backtrace())
        end
    end
    return nothing
end

"""
Run the newest matching handler for `route`, then let the socket open.

`ensureOpened` is what lets the page's `WebSocket` fire `onopen` in mock mode.
Without it the handler runs, registers its callbacks, and the page waits forever
for a socket that never opens — so it happens on **every** path out, including
the one where the handler threw.
"""
function handle_web_socket_route(registry::WebSocketRouteRegistry, route::WebSocketRoute)
    target = url(route)
    live = lock(registry.lock) do
        [reg for reg in registry.registrations if reg.active]
    end

    try
        for reg in Iterators.reverse(live)      # newest registration first
            matched = try
                # invokelatest for the same reason as the handler below: a
                # predicate matcher is user code too.
                Base.invokelatest(ws_matches, reg.matcher, target)
            catch e
                # A predicate that throws is a broken matcher and the handler
                # author's bug — recorded like a handler exception rather than
                # left to decide the socket.
                push!(reg.exceptions, e)
                false
            end
            matched || continue

            try
                # `invokelatest`, and load-bearing rather than defensive. The
                # dispatcher task is spawned at the *first* registration, which
                # fixes its world age; a handler closure defined after that —
                # the second route_web_socket! in any ordinary script — is "too
                # new" for it and raises MethodError instead of running. The
                # symptom is the worst available: the second registration
                # silently never fires. Same constraint api/events.jl's header
                # describes for the transport reader task, and the same fix
                # routing.jl and dialogs.jl already use.
                Base.invokelatest(reg.handler, route)
            catch e
                push!(reg.exceptions, e)
            end
            break
        end
    finally
        # Only a *mocked* socket needs opening: a proxied one is opened by the
        # server `connect!` reached, and asking for both is asking the driver to
        # open the same socket twice. Read here rather than after the loop so a
        # handler that connected and *then* threw is still not opened twice.
        if !ws_is_connected(route)
            try
                _web_socket_route_ensure_opened(route)
            catch
                # The socket or its page went away first. Nothing to open.
            end
        end
    end
    return nothing
end

"Whether `matcher` — a glob, Regex or predicate — accepts this socket's URL."
ws_matches(matcher::AbstractString, target::AbstractString) =
    occursin(glob_to_regex(matcher), target)
ws_matches(matcher::Regex, target::AbstractString) = occursin(matcher, target)
ws_matches(matcher, target::AbstractString) = matcher(target)::Bool

# --- The registration API (D11) --------------------------------------------

"""
    route_web_socket!(handler, target, matcher) -> WebSocketRouteRegistration

Intercept WebSocket connections on `target` — a [`Page`](@ref) or
[`BrowserContext`](@ref) — whose URL matches `matcher`, and run
`handler(route)` for each one.

```julia
# Mock: the real server is never contacted.
route_web_socket!(page, "**/ws") do wsr
    on_message_from_page!(wsr) do msg
        msg == "ping" && send_to_page!(wsr, "pong")
    end
end
```

`matcher` is a glob string (see [`glob_to_regex`](@ref)), a `Regex`, or a
`url -> Bool` predicate.

**The handler sets the conversation up and returns.** It is not a loop and it
must not block: register callbacks, optionally `connect!`, and return.
The messages arrive afterwards, on the dispatcher.

Handlers run on a dispatcher task, one per routed owner, **sequentially** — the
same arrangement [`route!`](@ref) uses and for the same reasons. Exceptions they
throw are collected and rethrown at [`unroute_web_socket!`](@ref).

Unlike [`route!`](@ref) there is **no unsettled warning**, because a WebSocket
route has nothing to settle. A handler that registers nothing is a socket that
mocks everything and answers nothing — which is a legitimate thing to want, if
what you are testing is that a page survives a dead socket.

Prefer [`with_web_socket_route`](@ref), which unregisters even when the body
throws.
"""
function route_web_socket!(handler, target::Union{Page,BrowserContext}, matcher)
    registry = lock(WS_ROUTE_REGISTRIES_LOCK) do
        get!(() -> WebSocketRouteRegistry(target), WS_ROUTE_REGISTRIES, target.guid)
    end
    reg = WebSocketRouteRegistration(matcher, handler)
    lock(registry.lock) do
        push!(registry.registrations, reg)
        start_ws_dispatcher!(registry)
    end
    push_ws_patterns!(registry)
    return reg
end

"""
    unroute_web_socket!(target, reg::WebSocketRouteRegistration)
    unroute_web_socket!(target)

Remove a registration made by [`route_web_socket!`](@ref), or every registration
on `target` when none is named.

**Exceptions thrown by the handler are rethrown here**: one directly, several as
a `CompositeException`. A handler that throws cannot raise where it happens — it
runs on the dispatcher, with no user task to raise into.

Idempotent. When the last registration goes, the dispatcher stops.
"""
function unroute_web_socket!(
    target::Union{Page,BrowserContext},
    reg::WebSocketRouteRegistration,
)
    registry = ws_registry_for(target)
    registry === nothing && return nothing

    empty_now = lock(registry.lock) do
        reg.active = false
        filter!(r -> r !== reg, registry.registrations)
        isempty(registry.registrations)
    end

    push_ws_patterns!(registry)
    empty_now && retire_ws_registry!(registry)
    settle_ws_in_flight!(registry)

    raise_collected([reg])
    return nothing
end

function unroute_web_socket!(target::Union{Page,BrowserContext})
    registry = ws_registry_for(target)
    registry === nothing && return nothing

    removed = lock(registry.lock) do
        gone = copy(registry.registrations)
        for r in gone
            r.active = false
        end
        empty!(registry.registrations)
        gone
    end

    push_ws_patterns!(registry)
    retire_ws_registry!(registry)
    settle_ws_in_flight!(registry)

    raise_collected(removed)
    return nothing
end

"""
    with_web_socket_route(body, target, matcher, handler)

Register `handler` for the duration of `body`, then unregister it — even when
`body` throws.

```julia
with_web_socket_route(page, "**/ws", wsr -> send_to_page!(wsr, "hello")) do
    click!(locator(page, "#connect"))
end
```

The handler is an *argument* and the body is the do-block, the same way round as
[`with_route`](@ref) and for the same reason: there are two functions to pass
and only one can be the block, so the block goes to the one with statements in
it.
"""
function with_web_socket_route(body, target::Union{Page,BrowserContext}, matcher, handler)
    reg = route_web_socket!(handler, target, matcher)
    try
        return body()
    finally
        unroute_web_socket!(target, reg)
    end
end

"Block until any route currently being handled has finished setting up."
function settle_ws_in_flight!(registry::WebSocketRouteRegistry)
    current_task() === registry.task && return nothing   # a handler unrouting itself
    lock(registry.dispatching) do
    end
    return nothing
end

"Stop the dispatcher and drop the registry, once nothing is registered."
function retire_ws_registry!(registry::WebSocketRouteRegistry)
    stop_ws_dispatcher!(registry)
    lock(WS_ROUTE_REGISTRIES_LOCK) do
        if isempty(registry.registrations)
            delete!(WS_ROUTE_REGISTRIES, registry.owner.guid)
        end
    end
    return nothing
end

"""
Re-send the union of every live registration's glob.

`setWebSocketInterceptionPatterns` replaces the whole pattern set, so this goes
again on every registration change — there is no "add one pattern" call.
"""
function push_ws_patterns!(registry::WebSocketRouteRegistry)
    globs = lock(registry.lock) do
        unique(String[driver_pattern(r.matcher) for r in registry.registrations if r.active])
    end
    patterns = [Dict{String,Any}("glob" => g) for g in globs]
    try
        set_ws_interception_patterns(registry.owner, patterns)
    catch
        # Clearing patterns on an owner that has already closed is not a failure
        # worth surfacing — nothing is intercepting anything either way.
        isempty(patterns) || rethrow()
    end
    return nothing
end

set_ws_interception_patterns(owner::Page, patterns) =
    _page_set_web_socket_interception_patterns(owner; patterns)
set_ws_interception_patterns(owner::BrowserContext, patterns) =
    _browser_context_set_web_socket_interception_patterns(owner; patterns)

# --- Reading a route -------------------------------------------------------

"""
    url(route::WebSocketRoute) -> String

The URL the page asked to connect to.
"""
url(route::WebSocketRoute) = route.initializer["url"]::String

# --- Mock or proxy (D12) ---------------------------------------------------
#
# `WebSocketRoute` is a generated struct with a fixed field layout, so "has this
# route connected?" lives beside it rather than on it — the same shape as
# routing.jl's SETTLED_ROUTES and lifecycle.jl's IMPLICIT_CONTEXTS.
#
# Bounded by the sockets currently *open*, not by the sockets ever routed:
# `forget_ws_route!` drops the entry when the route is disposed. Without that
# this is one entry per socket, forever — the leak R3 names, in its smaller
# form.

const CONNECTED_WS_ROUTES = Set{String}()
const CONNECTED_WS_ROUTES_LOCK = ReentrantLock()

"Whether [`connect!`](@ref) has put this route into proxy mode."
ws_is_connected(route::WebSocketRoute) =
    lock(CONNECTED_WS_ROUTES_LOCK) do
        route.guid in CONNECTED_WS_ROUTES
    end

"Mark `route` connected, returning whether this call is the one that connected it."
function mark_ws_connected!(route::WebSocketRoute)
    return lock(CONNECTED_WS_ROUTES_LOCK) do
        route.guid in CONNECTED_WS_ROUTES ? false :
        (push!(CONNECTED_WS_ROUTES, route.guid); true)
    end
end

forget_ws_route!(route::WebSocketRoute) =
    lock(CONNECTED_WS_ROUTES_LOCK) do
        delete!(CONNECTED_WS_ROUTES, route.guid)
    end

"""
    connect!(route::WebSocketRoute)

Connect the route to the real server, switching it from **mock** mode to
**proxy** mode.

```julia
route_web_socket!(page, "**/ws") do wsr
    connect!(wsr)                                  # proxy mode
    on_message_from_server!(wsr) do msg
        send_to_page!(wsr, replace(msg, "live" => "mocked"))
    end
end
```

Whether `connect!` was called is the entire mode switch. Until it is, the real
server is never contacted and [`send_to_server!`](@ref) is an error; after it,
messages flow in both directions.

**In proxy mode a callback you register replaces the default forwarding for that
direction.** Registering [`on_message_from_server!`](@ref) and not calling
[`send_to_page!`](@ref) silently swallows every server message. That is
Playwright's behaviour, not this package's choice, and it is the one edge of
this API worth reading twice.

Connecting a route that is already connected raises: there is one socket and it
is reached once.
"""
function connect!(route::WebSocketRoute)
    mark_ws_connected!(route) || throw(
        ArgumentError(
            "this route is already connected to the server; `connect!` switches " *
            "a route from mock to proxy mode exactly once.",
        ),
    )
    _web_socket_route_connect(route)
    return nothing
end

# --- Messages, in both directions and both shapes --------------------------

"A message as the wire wants it: `(payload, isBase64)`."
ws_wire_message(message::AbstractString) = (String(message), false)
ws_wire_message(message::AbstractVector{UInt8}) = (base64encode(message), true)

"""
A message as the caller wants it: a `String`, or the `Vector{UInt8}` that was
sent as bytes.

The `isBase64` flag is the driver's business. A binary frame sent as bytes
arrives as bytes, and nobody outside this file decodes anything.
"""
ws_message_from_wire(message::AbstractString, is_base64::Bool) =
    is_base64 ? base64decode(message) : String(message)

"""
    send_to_page!(route::WebSocketRoute, message)

Send `message` to the page, as though the server had sent it.

`message` is a `String` (a text frame) or a `Vector{UInt8}` (a binary frame).
The base64 the driver wants for binary is handled here; the caller never sees
the flag.

Works in both modes: in mock mode this is the only thing the page ever hears.
"""
function send_to_page!(
    route::WebSocketRoute,
    message::Union{AbstractString,AbstractVector{UInt8}},
)
    payload, is_base64 = ws_wire_message(message)
    _web_socket_route_send_to_page(route; isBase64 = is_base64, message = payload)
    return nothing
end

"""
    send_to_server!(route::WebSocketRoute, message)

Send `message` to the real server, as though the page had sent it.

`message` is a `String` or a `Vector{UInt8}`, exactly as for
[`send_to_page!`](@ref).

**Proxy mode only.** Calling this before [`connect!`](@ref) raises an
`ArgumentError` — before anything reaches the wire, because in mock mode there
is no server to reach and a driver-side rejection would arrive later and say
less.
"""
function send_to_server!(
    route::WebSocketRoute,
    message::Union{AbstractString,AbstractVector{UInt8}},
)
    ws_is_connected(route) || throw(
        ArgumentError(
            "this route is in mock mode, so there is no server to send to. " *
            "Call `connect!(route)` in the handler to switch it to proxy mode.",
        ),
    )
    payload, is_base64 = ws_wire_message(message)
    _web_socket_route_send_to_server(route; isBase64 = is_base64, message = payload)
    return nothing
end

"""
    close_ws!(route::WebSocketRoute; code = nothing, reason = nothing)

Close the page's socket, optionally with a close `code` and `reason` the page's
`onclose` will see.

Named `close_ws!` rather than `close!` on purpose: the [`close!`](@ref) family
closes *owners* — a page, a context, a browser — and a route is not an owner.

The close is reported to the page as clean; an unclean close is something the
socket reports, not something this API can produce.
"""
function close_ws!(
    route::WebSocketRoute;
    code::Union{Real,Nothing} = nothing,
    reason::Union{AbstractString,Nothing} = nothing,
)
    _web_socket_route_close_page(route; wasClean = true, code, reason)
    return nothing
end
