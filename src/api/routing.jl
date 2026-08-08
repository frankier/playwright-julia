# Route interception: the Route wrapper, the per-owner registry, and the
# dispatcher task that runs user handlers.
#
# This file is written lifetime-first on purpose. Three of its failure
# modes — a dispatcher that leaks, one that dies, one that deadlocks — present
# to a user identically: requests hang and an unrelated `goto!` times out
# thirty seconds later, metres from the cause. So the task's birth and death
# come before anything it does.
#
# Why a task at all: `src/api/events.jl` opens with "Nothing here invokes
# user code. The transport reader task cannot call closures defined after it
# started (world age)". A route handler is user code that must *also* call back
# into the driver — `fulfill!` is a protocol command. Running it on the reader
# task is doubly impossible: world age forbids it, and the handler would block
# the very connection its own call needs.

# --- Settle tracking -------------------------------------------------------
#
# `Route` is a generated struct with a fixed field layout, so "has this been
# settled?" lives beside it rather than on it — the same shape as
# IMPLICIT_CONTEXTS in lifecycle.jl and for the same reason.

# Bounded by the routes currently *in flight*, not by the routes ever seen:
# `handle_route` forgets each guid on its way out. Without that this is a leak
# of one entry per request, which on a page loading fifty assets is fifty per
# navigation, forever.
const SETTLED_ROUTES = Set{String}()
const SETTLED_ROUTES_LOCK = ReentrantLock()

is_settled(route::Route) =
    lock(SETTLED_ROUTES_LOCK) do
        route.guid in SETTLED_ROUTES
    end

"Mark `route` settled, returning whether this call is the one that settled it."
function mark_settled!(route::Route)
    return lock(SETTLED_ROUTES_LOCK) do
        route.guid in SETTLED_ROUTES ? false : (push!(SETTLED_ROUTES, route.guid); true)
    end
end

forget_route!(route::Route) =
    lock(SETTLED_ROUTES_LOCK) do
        delete!(SETTLED_ROUTES, route.guid)
    end

"A route may only be settled once, and the second attempt says so."
function claim_settle!(route::Route, verb::AbstractString)
    mark_settled!(route) || throw(
        ArgumentError(
            "this route has already been settled; `$verb` cannot settle it again. " *
            "abort!, continue! and fulfill! each end the route exactly once.",
        ),
    )
    return nothing
end

# --- Registration and registry ---------------------------------------------

"""
    RouteRegistration

One live `route!` call. Returned so it can be passed back to [`unroute!`](@ref).

It also carries the exceptions its handler threw. They are not raised
where they happen — there is no user task there — so they are collected and
rethrown when the registration is released.

`release` is an optional zero-argument callable run by [`unroute!`](@ref) once
the registration is gone and any in-flight route has settled. It exists so a
registration can *own* a resource for its lifetime — HAR replay owns an open
archive and a temp directory that way — without a second handle type and a
second thing for the caller to remember to close.
"""
mutable struct RouteRegistration
    matcher::Any
    handler::Any
    exceptions::Vector{Any}
    warned::Bool          # one warning per registration, not per request
    active::Bool
    release::Union{Function,Nothing}
    released::Bool        # so a second unroute! does not release twice
    # Whether this registration arms the driver's interception. False for a
    # registration that exists *only* to own a release hook —
    # `route_from_har(…; update = true)` is a recording, not a replay, and must
    # not put a handler in front of the traffic it is recording.
    intercepts::Bool
end

RouteRegistration(
    matcher,
    handler;
    release::Union{Function,Nothing} = nothing,
    intercepts::Bool = true,
) = RouteRegistration(matcher, handler, Any[], false, true, release, false, intercepts)

"Per-owner routing state: the registrations, the buffer, and the dispatcher."
mutable struct RouteRegistry
    owner::ChannelOwner
    registrations::Vector{RouteRegistration}   # oldest first; dispatched newest first
    subscription::Union{Subscription,Nothing}
    task::Union{Task,Nothing}
    lock::ReentrantLock
    # Held by the dispatcher for the whole of one route's handling, so
    # `unroute!` can wait for an in-flight route to settle before it returns
    #. Without it, unregistering while a handler is mid-flight returns to
    # a caller whose next line races a `fulfill!` it thought was finished.
    #
    # Re-entrant on purpose: a handler that calls `unroute!` on its own
    # registration is unusual but legal, and must not deadlock against itself.
    dispatching::ReentrantLock
end

RouteRegistry(owner) = RouteRegistry(
    owner,
    RouteRegistration[],
    nothing,
    nothing,
    ReentrantLock(),
    ReentrantLock(),
)

const ROUTE_REGISTRIES = Dict{String,RouteRegistry}()
const ROUTE_REGISTRIES_LOCK = ReentrantLock()

registry_for(owner::ChannelOwner) =
    lock(ROUTE_REGISTRIES_LOCK) do
        get(ROUTE_REGISTRIES, owner.guid, nothing)
    end

# --- The dispatcher's lifetime ---------------------------------------------

"""
Start the dispatcher for `registry` if it is not already running.

Spawned on the *first* registration and not before: a package that spawns a
task per owner whether or not anyone routes is a package that leaks a task per
page.
"""
function start_dispatcher!(registry::RouteRegistry)
    registry.task === nothing || return registry.task
    sub = subscribe(registry.owner, "route", channel_payload("route", Route))
    registry.subscription = sub
    registry.task = @async dispatch_routes(registry, sub)
    return registry.task
end

"""
Stop the dispatcher and wait for it to finish.

Closing the channel is what wakes it: `take!` on a closed channel raises, which
is the loop's exit. No sentinel value, no polling, and above all no `sleep`: a
lifetime that needs one is the wrong lifetime.

`close(sub)` first, so the reader task stops delivering into a channel that is
about to close; `deliver_event` already treats a put! into a dead subscription
as a no-op rather than an error, so the race is closed on both sides.
"""
function stop_dispatcher!(registry::RouteRegistry)
    task = registry.task
    sub = registry.subscription
    registry.task = nothing
    registry.subscription = nothing
    sub === nothing || (close(sub); close(sub.channel))
    if task !== nothing
        # The dispatcher never rethrows a handler's exception, so a
        # failure here would be a bug in the dispatcher itself. Surface it.
        wait(task)
    end
    return nothing
end

"""
The dispatcher loop: one per routed owner, handlers run sequentially in arrival
order.

Sequential is a decision, not an accident. It makes ordering deterministic,
stops one handler's `fulfill!` interleaving with the next request's handler,
and means a user closure touching shared state needs no lock of its own. The
cost — a slow handler delays later requests on the same owner — is the cost
`playwright-python`'s sync API pays too, and is acceptable in a test.
"""
function dispatch_routes(registry::RouteRegistry, sub::Subscription)
    while true
        route = try
            take!(sub.channel)
        catch
            break            # channel closed: stop_dispatcher! was called
        end
        route isa Route || continue
        try
            lock(registry.dispatching) do
                handle_route(registry, route)
            end
        catch e
            # handle_route already catches everything a handler throws. Reaching
            # here means the dispatcher itself failed, and dying quietly would
            # hang every later request on this owner.
            @error "route dispatcher failed; later requests on this owner will not be intercepted" exception =
                (e, catch_backtrace())
        end
    end
    return nothing
end

# --- Dispatching one route -------------------------------------------------

"""
Run the matching handler for `route`, and guarantee the route is settled
whatever happens.

Every path out of this function settles: no matcher matched, a handler returned
without settling, a handler threw. A route nobody settles is the worst failure
available here — the request stops dead and surfaces as an unrelated timeout.
"""
function handle_route(registry::RouteRegistry, route::Route)
    try
        return handle_route_inner(registry, route)
    finally
        # The route is finished with — the driver disposes it once it is
        # settled — so its settle marker must not outlive the dispatch.
        forget_route!(route)
    end
end

function handle_route_inner(registry::RouteRegistry, route::Route)
    target = url(request(route))
    base = base_url_for(registry.owner)

    # Snapshot under the lock, then run user code with no lock held.
    live = lock(registry.lock) do
        [reg for reg in registry.registrations if reg.active]
    end

    for reg in Iterators.reverse(live)      # newest registration first
        matched = try
            # invokelatest for the same reason as the handler below: a
            # predicate matcher is user code too.
            Base.invokelatest(matches, reg.matcher, target; base_url = base)
        catch e
            # A predicate that throws is a broken matcher, and is the handler's
            # author's bug — record it like a handler exception rather than
            # letting it decide the request.
            record_exception!(reg, e)
            false
        end
        matched || continue

        try
            # Anything the handler fetches with Playwright.fetch is disposed
            # when it returns. The driver buffers an unfetched body until it is
            # told otherwise, so without this every mock-from-upstream leaks one.
            with_fetch_scope() do
                # `invokelatest`, and this is load-bearing rather than defensive.
                # The dispatcher task is spawned at the *first* registration, which
                # fixes its world age; a handler closure defined after that — the
                # second `route!` in any ordinary script — is "too new" for it and
                # raises MethodError instead of running. The symptom is the worst
                # one available here: the second registration silently never fires.
                # This is the same world-age constraint api/events.jl's header
                # describes for the transport reader task.
                Base.invokelatest(reg.handler, route)
            end
        catch e
            record_exception!(reg, e)
            settle_default!(route)          # the page proceeds regardless
            return nothing
        end

        if !is_settled(route)
            warn_unsettled!(reg, target)
            settle_default!(route)
        end
        return nothing
    end

    # Nothing matched. This is the *normal* case, not an error: the driver is
    # sent the union of every registration's glob, and a `**/*` union delivers
    # every request on the owner whether or not any matcher wants it.
    settle_default!(route)
    return nothing
end

function record_exception!(reg::RouteRegistration, e)
    push!(reg.exceptions, e)
    return nothing
end

"""
Warn once per registration, naming the URL — never once per request.

The failure this catches is a handler that is wrong for every request. On a
page loading fifty assets, a per-request warning buries its own signal.
"""
function warn_unsettled!(reg::RouteRegistration, target::AbstractString)
    reg.warned && return nothing
    reg.warned = true
    @warn """
    A route handler returned without settling the route; it has been continued.
    Call abort!, continue! or fulfill! on the route. This is reported once per
    registration, not once per request.""" url = target
    return nothing
end

"Continue a route nobody settled, silently. The route may already be gone."
function settle_default!(route::Route)
    is_settled(route) && return nothing
    try
        continue!(route)
    catch
        # The owner closed mid-route, or the driver already tore the route
        # down. Either way the request is no longer waiting on us, and raising
        # here would kill a dispatcher that has later requests to serve.
    end
    return nothing
end

"The base URL a scheme-less glob resolves against, or `nothing`."
base_url_for(owner::ChannelOwner) = nothing

# --- Registration API -------------------------------------------------

"""
    route!(target, matcher, handler) -> RouteRegistration

Intercept requests on `target` — a [`Page`](@ref) or a
[`BrowserContext`](@ref) — that match `matcher`, and run `handler(route)` for
each one.

`matcher` is a glob string (see [`glob_to_regex`](@ref)), a `Regex`, or a
`url -> Bool` predicate. `handler` must settle the route with
[`abort!`](@ref), [`continue!`](@ref) or [`fulfill!`](@ref); one that returns
without settling gets a warning and the route is continued for it.

```julia
reg = route!(ctx, "**/api/items", route -> fulfill!(route; json = ["a", "b"]))
goto!(page, url)
unroute!(ctx, reg)
```

Handlers run on a dispatcher task, one per routed owner, **sequentially** — so
two requests are never in your handler at once and shared state needs no lock,
at the cost of a slow handler delaying later requests on that owner. The newest
registration matching a request wins.

Prefer [`with_route`](@ref), which unregisters even when the body throws.

!!! note "A `Regex` or predicate matcher intercepts everything"
    The driver is told the union of the live registrations' globs, and neither
    a `Regex` nor a predicate can be expressed as one — so either widens the
    union to `**/*` and every request on the owner makes the round trip to be
    filtered here. Use a glob when one will do.

Exceptions thrown by `handler` are collected and rethrown when the registration
is released, by [`unroute!`](@ref) or at the end of [`with_route`](@ref) — see
[`unroute!`](@ref).

`release` is an optional zero-argument callable run once when the registration
goes away, for a handler that owns a resource for the registration's lifetime.
[`route_from_har`](@ref) uses it to close the archive; most callers do not need
it.
"""
function route!(
    target::Union{Page,BrowserContext},
    matcher,
    handler;
    release::Union{Function,Nothing} = nothing,
    intercepts::Bool = true,
)
    registry = lock(ROUTE_REGISTRIES_LOCK) do
        get!(() -> RouteRegistry(target), ROUTE_REGISTRIES, target.guid)
    end
    reg = RouteRegistration(matcher, handler; release, intercepts)
    lock(registry.lock) do
        push!(registry.registrations, reg)
        # A registration that intercepts nothing needs no dispatcher: starting
        # one would subscribe to a `route` event the driver will never send.
        intercepts && start_dispatcher!(registry)
    end
    push_patterns!(registry)
    return reg
end

"""
    unroute!(target, reg::RouteRegistration)
    unroute!(target)

Remove a registration made by [`route!`](@ref), or every registration on
`target` when none is named.

**Exceptions thrown by the handler are rethrown here**: one directly,
several as a `CompositeException`. A handler that throws cannot raise where it
happens — it runs on the dispatcher task, with no user task to raise into — so
a silently broken mock would otherwise surface as a puzzling failure somewhere
unrelated.

Idempotent: unrouting an already-removed registration does nothing. When the
last registration goes, the dispatcher task stops.
"""
function unroute!(target::Union{Page,BrowserContext}, reg::RouteRegistration)
    registry = registry_for(target)
    registry === nothing && return nothing

    empty_now = lock(registry.lock) do
        reg.active = false
        filter!(r -> r !== reg, registry.registrations)
        isempty(registry.registrations)
    end

    # Patterns before teardown: the driver should stop sending what nobody
    # wants before the task that drains it goes away.
    push_patterns!(registry)
    empty_now && retire!(registry)

    # A route already in the handler settles before this returns. The
    # registration is deactivated above, so this waits for at most the one
    # dispatch that was already under way.
    settle_in_flight!(registry)

    # After the last dispatch, never before: the hook frees what the handler was
    # using, so releasing early would pull an open archive out from under a
    # route still being served. Before raise_collected, so a handler that
    # threw does not also leak the resource.
    run_release!(registry, reg)

    raise_collected([reg])
    return nothing
end

function unroute!(target::Union{Page,BrowserContext})
    registry = registry_for(target)
    registry === nothing && return nothing

    removed = lock(registry.lock) do
        gone = copy(registry.registrations)
        for r in gone
            r.active = false
        end
        empty!(registry.registrations)
        gone
    end

    push_patterns!(registry)
    retire!(registry)
    settle_in_flight!(registry)

    for reg in removed
        run_release!(registry, reg)
    end

    raise_collected(removed)
    return nothing
end

"""
Run a registration's release hook, at most once.

The flag flips under the registry's lock so two concurrent `unroute!` calls
cannot both release, while the hook itself runs outside it — releasing talks to
the driver (`harClose`) and holding the registry's lock across a round trip
would put every other registration behind the transport.
"""
function run_release!(registry::RouteRegistry, reg::RouteRegistration)
    hook = reg.release
    hook === nothing && return nothing
    mine = lock(registry.lock) do
        reg.released ? false : (reg.released = true)
    end
    mine && hook()
    return nothing
end

"""
    unroute_all!(target)

Remove every route registration on `target`. The same as the one-argument
[`unroute!`](@ref), spelled the way Playwright spells it.
"""
unroute_all!(target::Union{Page,BrowserContext}) = unroute!(target)

"""
Block until any route currently being handled has settled.

Cheap when nothing is in flight — the lock is uncontended — and bounded by one
handler, because the registration was deactivated before this was called.
Called from the *user's* task, never the dispatcher's.
"""
function settle_in_flight!(registry::RouteRegistry)
    current_task() === registry.task && return nothing   # a handler unrouting itself
    lock(registry.dispatching) do
    end
    return nothing
end

"Stop the dispatcher and drop the registry, once nothing is registered."
function retire!(registry::RouteRegistry)
    stop_dispatcher!(registry)
    lock(ROUTE_REGISTRIES_LOCK) do
        if isempty(registry.registrations)
            delete!(ROUTE_REGISTRIES, registry.owner.guid)
        end
    end
    return nothing
end

"Rethrow what the handlers threw: one directly, several as a CompositeException."
function raise_collected(regs)
    errors = Any[]
    for reg in regs
        append!(errors, reg.exceptions)
        empty!(reg.exceptions)
    end
    isempty(errors) && return nothing
    length(errors) == 1 && throw(only(errors))
    throw(CompositeException(errors))
end

"""
    with_route(body, target, matcher, handler)

Register `handler` for the duration of `body`, then unregister it — even when
`body` throws.

The handler is an *argument* and the body is the do-block, which is the
opposite way round from [`with_events`](@ref) and deliberate: there are two
functions to pass and only one can be the block, so the block goes to the one
with statements in it.

```julia
with_route(ctx, "**/api/**", route -> fulfill!(route; json = mock)) do
    goto!(page, url)
    click!(locator(page, "#refresh"))
end
```

Anything the handler threw is rethrown here, after the body has finished and
the registration is gone — see [`unroute!`](@ref).
"""
function with_route(
    body,
    target::Union{Page,BrowserContext},
    matcher,
    handler;
    release::Union{Function,Nothing} = nothing,
)
    reg = route!(target, matcher, handler; release)
    try
        return body()
    finally
        unroute!(target, reg)
    end
end

# --- The driver pattern union -----------------------------------------

"""
Re-send the union of every live registration's glob.

`setNetworkInterceptionPatterns` replaces the *whole* pattern set, so this is
sent again on every registration change rather than incrementally — there is no
"add one pattern" call to reach for.
"""
function push_patterns!(registry::RouteRegistry)
    globs = lock(registry.lock) do
        # `intercepts` as well as `active`: an update-mode HAR registration owns
        # a release hook and nothing else, and must not arm the driver against
        # the traffic it is there to record.
        unique(
            String[
                driver_pattern(r.matcher) for
                r in registry.registrations if r.active && r.intercepts
            ],
        )
    end
    patterns = [Dict{String,Any}("glob" => g) for g in globs]
    try
        set_interception_patterns(registry.owner, patterns)
    catch e
        # Clearing patterns on an owner that has already closed is not a
        # failure worth surfacing — nothing is intercepting anything either way.
        isempty(patterns) || rethrow()
    end
    return nothing
end

set_interception_patterns(page::Page, patterns) =
    _page_set_network_interception_patterns(page; patterns)
set_interception_patterns(ctx::BrowserContext, patterns) =
    _browser_context_set_network_interception_patterns(ctx; patterns)

# --- Route, and the three settle verbs -------------------------------------

"""
    request(route::Route) -> Request

The intercepted request. Everything about it is free to read — see
[`Request`](@ref).
"""
request(route::Route) =
    from_channel(route.connection, route.initializer["request"])::Request

"""
    url(route::Route) -> String

The intercepted request's URL, shorthand for `url(request(route))`.
"""
url(route::Route) = url(request(route))

# Playwright's own set. A typo'd code should be an ArgumentError here rather
# than mysterious browser-side behaviour later.
const ABORT_ERROR_CODES = (
    "aborted",
    "accessdenied",
    "addressunreachable",
    "blockedbyclient",
    "blockedbyresponse",
    "connectionaborted",
    "connectionclosed",
    "connectionfailed",
    "connectionrefused",
    "connectionreset",
    "internetdisconnected",
    "namenotresolved",
    "timedout",
    "failed",
)

"""
    abort!(route::Route; error_code = "failed")

Fail the request, as though the network had. The page sees a failed request —
which is the point: this is how a test drives its own error path.

`error_code` is validated against Playwright's set before it is sent, so a
typo raises here rather than becoming inexplicable browser behaviour:

$(join(["`\"" * c * "\"`" for c in ABORT_ERROR_CODES], ", ")).

```julia
route!(ctx, "**/*.png", route -> abort!(route))    # no images in this test
```

A route can be settled exactly once; a second settle raises.
"""
function abort!(route::Route; error_code::AbstractString = "failed")
    code = String(error_code)
    code in ABORT_ERROR_CODES || throw(
        ArgumentError(
            "unknown abort error_code $(repr(code)). Playwright accepts: " *
            join(ABORT_ERROR_CODES, ", "),
        ),
    )
    claim_settle!(route, "abort!")
    _route_abort(route; errorCode = code)
    return nothing
end

"""
    continue!(route::Route; url=nothing, method=nothing, headers=nothing, post_data=nothing)

Let the request proceed, optionally rewriting it on the way through.

This is Playwright's `route.continue()`; `playwright-python` spells it
`continue_` because Python has no escape from the keyword. Julia does: the
lexer reads an identifier greedily, so `continue!` is a name and never the
`continue` keyword followed by `!`.

```julia
# Add a header to every API call, and otherwise leave it alone.
route!(ctx, "**/api/**", route -> continue!(route;
    headers = merge(headers(request(route)), Dict("x-test" => "1"))))
```

`headers` replaces the whole set rather than merging, which is why the example
merges explicitly. `post_data` takes a `String` or a `Vector{UInt8}`.

A route that no handler settles is continued for you — this is the call
that does it.
"""
function continue!(
    route::Route;
    url::Union{AbstractString,Nothing} = nothing,
    method::Union{AbstractString,Nothing} = nothing,
    headers::Union{AbstractDict,Nothing} = nothing,
    post_data::Union{AbstractString,AbstractVector{UInt8},Nothing} = nothing,
)
    claim_settle!(route, "continue!")
    _route_continue(
        route;
        isFallback = false,
        url,
        method,
        headers = headers === nothing ? nothing : name_value_array(headers),
        postData = post_data === nothing ? nothing : as_bytes(post_data),
    )
    return nothing
end

as_bytes(s::AbstractString) = Vector{UInt8}(codeunits(String(s)))
as_bytes(v::AbstractVector{UInt8}) = Vector{UInt8}(v)

"""
    fulfill!(route::Route; status=200, headers=nothing, body=nothing, json=nothing,
             content_type=nothing, path=nothing, response=nothing)

Answer the request yourself, without it ever reaching the network.

Exactly one body source may be given — `body`, `json`, `path` or `response` —
and passing two is an `ArgumentError` here rather than a driver error later.
`status`, `headers` and `content_type` may accompany any of them, including
`response`, which is what makes "the real response with one thing changed"
work.

| Argument | Effect |
|---|---|
| `body` | a `String` sent as-is, or a `Vector{UInt8}` sent base64-encoded |
| `json` | `JSON.json(x)`, with `content-type: application/json` |
| `path` | the file's bytes, content type inferred from its extension |
| `response` | an `APIResponse` — fulfil from a real upstream response |
| `content_type` | sets `content-type`, overriding the inferred one |
| `headers` | merged *over* the inferred content type |

```julia
route!(ctx, "**/api/items", route -> fulfill!(route; json = Dict("items" => [1, 2])))
```
"""
function fulfill!(
    route::Route;
    status::Union{Integer,Nothing} = nothing,
    headers::Union{AbstractDict,Nothing} = nothing,
    body = nothing,
    json = nothing,
    content_type::Union{AbstractString,Nothing} = nothing,
    path::Union{AbstractString,Nothing} = nothing,
    response = nothing,
)
    sources = [
        name for (name, value) in
        ("body" => body, "json" => json, "path" => path, "response" => response) if
        value !== nothing
    ]
    length(sources) <= 1 || throw(
        ArgumentError(
            "fulfill! takes at most one body source, got " *
            join(sources, " and ") *
            ". `status`, `headers` and `content_type` may accompany any of them.",
        ),
    )

    payload, is_base64, inferred_type = fulfill_body(body, json, path)
    fetch_uid = response === nothing ? nothing : fetch_response_uid(response)

    merged = Dict{String,String}()
    inferred_type === nothing || (merged["content-type"] = inferred_type)
    content_type === nothing || (merged["content-type"] = String(content_type))
    if headers !== nothing
        for (k, v) in headers
            merged[lowercase(String(k))] = string(v)
        end
    end

    claim_settle!(route, "fulfill!")
    _route_fulfill(
        route;
        status = status === nothing ? nothing : Int(status),
        headers = isempty(merged) ? nothing : name_value_array(merged),
        body = payload,
        isBase64 = payload === nothing ? nothing : is_base64,
        fetchResponseUid = fetch_uid,
    )
    return nothing
end

"Resolve the body source into (payload, isBase64, inferred content type)."
function fulfill_body(body, json, path)
    if json !== nothing
        return JSON.json(json), false, "application/json"
    elseif path !== nothing
        bytes = read(String(path))
        return base64encode(bytes), true, content_type_for(String(path))
    elseif body isa AbstractString
        return String(body), false, nothing
    elseif body isa AbstractVector{UInt8}
        return base64encode(body), true, nothing
    elseif body === nothing
        return nothing, false, nothing
    end
    throw(
        ArgumentError(
            "fulfill!'s `body` must be a String or a Vector{UInt8}, got $(typeof(body)). " *
            "For a Julia value serialized as JSON use `json =`.",
        ),
    )
end

"""
Extended in `apirequest.jl` for `APIResponse`. Anything else is a
mistake worth naming at the call site.
"""
fetch_response_uid(x) = throw(
    ArgumentError(
        "fulfill!'s `response` must be an APIResponse from Playwright.fetch, " *
        "got $(typeof(x)).",
    ),
)

"Content type for a path's extension. Deliberately short: the common cases."
function content_type_for(path::AbstractString)
    ext = lowercase(splitext(path)[2])
    return get(
        Dict(
            ".html" => "text/html",
            ".htm" => "text/html",
            ".css" => "text/css",
            ".js" => "text/javascript",
            ".mjs" => "text/javascript",
            ".json" => "application/json",
            ".txt" => "text/plain",
            ".svg" => "image/svg+xml",
            ".png" => "image/png",
            ".jpg" => "image/jpeg",
            ".jpeg" => "image/jpeg",
            ".gif" => "image/gif",
            ".webp" => "image/webp",
            ".ico" => "image/x-icon",
            ".woff" => "font/woff",
            ".woff2" => "font/woff2",
            ".wasm" => "application/wasm",
            ".pdf" => "application/pdf",
        ),
        ext,
        "application/octet-stream",
    )
end
