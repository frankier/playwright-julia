# Event registry and subscription lifetime.
#
# This is the plumbing beneath expect_event / wait_for_event: it routes named
# driver events to buffers and, above all, makes sure those buffers die when
# they stop being needed. Buffers are unbounded by design (D1) — no event is
# ever dropped — which makes lifetime load-bearing rather than cosmetic: an
# unbounded buffer left attached to a chatty page is an unbounded leak.
#
# Nothing here invokes user code. The transport reader task cannot call closures
# defined after it started (world age), so it only ever `put!`s into a channel;
# the waiting task does the rest.

"""
    Subscription

Internal handle for a live event subscription: an unbounded buffer fed by the
transport reader task. Created by [`subscribe`](@ref), and released by
`close`, which detaches it from the registry *and* empties the buffer.

Users get at this through `expect_event` / `wait_for_event` rather than
directly.
"""
mutable struct Subscription
    connection::Connection
    guid::String        # owner
    event::String       # wire spelling, e.g. "console"
    channel::Channel{Any}
    closed::Bool
    # `owner` is held strongly so a payload mapper has something to resolve
    # against; the subscription dies with the owner anyway, so this adds no
    # lifetime beyond the one the registry already gives it. `payload` maps
    # raw event params to what the caller sees, and runs at delivery time —
    # see the note on EventSpec for why not at take! time.
    owner::ChannelOwner
    payload::Function
    # M6 D11: a filter applied at delivery, before the payload is buffered.
    # The network events live on the BrowserContext and carry an optional
    # `page`, so a Page subscription is really a context subscription that
    # drops other pages' traffic. Filtering here rather than at `take!` keeps
    # another page's requests out of this buffer entirely, which matters
    # because the buffer is unbounded.
    accept::Function

    function Subscription(
        owner::ChannelOwner,
        event::AbstractString,
        payload::Function = (_owner, params) -> params,
        accept::Function = (_owner, _params) -> true,
    )
        # Unbounded: put! from the reader task must never block, or a slow
        # consumer would stall the whole protocol connection.
        sub = new(
            owner.connection,
            owner.guid,
            String(event),
            Channel{Any}(Inf),
            false,
            owner,
            payload,
            accept,
        )
        # Last-resort net for a handle the user leaked, not the mechanism the
        # design relies on: the do-block forms and the owner-close cascade are.
        #
        # Deliberately drains rather than calling close: a subscription still in
        # the registry is strongly held by the connection and so cannot be
        # finalized at all, which means anything reaching here is already
        # detached and has only its buffer left to drop. Taking the connection
        # lock from a finalizer would be a needless deadlock risk during GC.
        finalizer(s -> drain!(s.channel), sub)
        return sub
    end
end

"""
    subscribe(owner, event) -> Subscription

Attach an unbounded buffer to `event` on `owner` (a `Page`, `BrowserContext`,
`Browser`, …). `event` is the wire spelling.

The caller owns the returned handle and **must** `close` it. Prefer the
do-block forms, which close it for you even when the body throws.
"""
function subscribe(
    owner::ChannelOwner,
    event::AbstractString,
    payload::Function = (_owner, params) -> params,
    accept::Function = (_owner, _params) -> true,
)
    sub = Subscription(owner, event, payload, accept)
    conn = owner.connection
    lock(conn.lock) do
        push!(get!(Vector{Subscription}, conn.subscriptions, owner.guid), sub)
    end
    return sub
end

"""
    close(sub::Subscription)
    unsubscribe(sub::Subscription)

Detach `sub` from the registry and empty its buffer, so buffered payloads
become garbage immediately rather than at some later GC of the handle.
Idempotent.
"""
function Base.close(sub::Subscription)
    detach_subscription!(sub)
    drain!(sub.channel)
    return nothing
end

"""
Detach `sub` from the registry **without** draining its buffer. Idempotent.

`close` does both, which is right when the channel belongs to the subscription
alone. It is wrong when the channel is *shared*: a `WebSocketRoute`'s four
subscriptions feed their owner's dispatcher queue rather than one each (D13), so
draining on release would throw away another socket's pending messages — and,
worse, the route arrivals the dispatcher has not handled yet.
"""
function detach_subscription!(sub::Subscription)
    conn = sub.connection
    lock(conn.lock) do
        sub.closed && return nothing
        sub.closed = true
        subs = get(conn.subscriptions, sub.guid, nothing)
        if subs !== nothing
            filter!(s -> s !== sub, subs)
            isempty(subs) && delete!(conn.subscriptions, sub.guid)
        end
        return nothing
    end
    return nothing
end

# A named alias rather than `const unsubscribe = close`, which would alias the
# whole of Base.close and export it under a second name.
unsubscribe(sub::Subscription) = close(sub)

"Discard everything buffered in `ch` without blocking."
function drain!(ch::Channel)
    while isready(ch)
        try
            take!(ch)
        catch
            break
        end
    end
    return nothing
end

"""
Route a driver event to its subscribers. Unknown guids and events nobody
subscribed to are silently ignored — an unrecognised event must never kill the
transport read loop.

Called from `dispatch` on the reader task, so it does no work beyond `put!`.
"""
function deliver_event(
    conn::Connection,
    guid::AbstractString,
    event::AbstractString,
    params,
)
    matching = lock(conn.lock) do
        subs = get(conn.subscriptions, guid, nothing)
        subs === nothing ? Subscription[] :
        Subscription[s for s in subs if s.event == event && !s.closed]
    end
    for sub in matching
        # A close racing us between the snapshot and here leaves the payload in
        # a channel nobody holds — harmless, and cheaper than holding the
        # connection lock across the put!.
        try
            # D11's filter runs before the mapping and before the buffering, so
            # a page-scoped subscription never holds another page's payloads.
            sub.accept(sub.owner, params) || continue
            # Mapping here rather than at take! time is what lets a payload
            # outlive its wire reference: `frameDetached`'s frame is disposed
            # immediately after this event, so a later lookup would find
            # nothing. The mapper only reads the object registry — no user code
            # runs on the reader task (world age).
            put!(sub.channel, sub.payload(sub.owner, params))
        catch
            # Channel closed under us, or a payload that would not map; either
            # way dispatch must not die. Dispatch to a dead subscription is a
            # no-op by contract, never an error.
        end
    end
    return nothing
end

"""
Close every subscription owned by `guid`. Called from `dispose_locked` with the
connection lock already held, so it must not take it again.

`dispose_locked` recurses into children before calling this, so a context close
reaches the subscriptions on its pages.
"""
function close_subscriptions_locked(conn::Connection, guid::AbstractString)
    subs = pop!(conn.subscriptions, guid, nothing)
    subs === nothing && return nothing
    for sub in subs
        sub.closed = true
        # Deliberately detaches WITHOUT draining, unlike `close(sub)`.
        #
        # The driver sends `close` and then immediately `__dispose__` for the
        # same page, so draining here would throw away the very event a
        # `expect_event(page, :close)` block is sitting waiting for — verified
        # against both engines. Leak-safety does not depend on draining: what
        # bounds the buffer is that the connection has just dropped its
        # reference (`pop!` above), so anything still buffered lives only as
        # long as the handle the waiter holds, and the finalizer drains it if
        # that handle is leaked. Explicit `close(sub)`/`unsubscribe` still
        # empties, because there the caller has said they are done reading.
    end
    return nothing
end

"Close every subscription on the connection. Used by playwright() teardown."
function close_all_subscriptions(conn::Connection)
    all_subs = lock(conn.lock) do
        subs = collect(Iterators.flatten(values(conn.subscriptions)))
        empty!(conn.subscriptions)
        subs
    end
    for sub in all_subs
        sub.closed = true
        drain!(sub.channel)
    end
    return nothing
end

# --- The user-facing surface ----------------------------------------------
#
# Everything above is plumbing; this is what callers touch. Two decisions shape
# it:
#
# * The do-block form is primary. Subscribing has to happen *before* the action
#   that triggers the event, or an event fired synchronously inside that action
#   is gone before anyone is listening. Taking the action as a block is the only
#   shape that makes that ordering impossible to get wrong.
# * Only events whose payload is useful with the types this milestone ships are
#   supported. Handing back a bare `RemoteObject` for `:request` would look like
#   support while giving the caller something they cannot read a URL off, so
#   those raise instead — naming the event and saying it is deferred.

"""
Payload mapping for one supported event: its wire spelling and how to turn the
event's params into something worth handing a caller.

Mapping runs on the reader task at delivery time, not when the payload is
taken. That matters for `frameDetached`, whose frame is disposed moments after
the event: resolving it later would find nothing in the registry.
"""
struct EventSpec
    wire::String
    payload::Function   # (owner, params) -> user-facing value
    # Some events are opt-in: the driver stays silent until the client asks for
    # them with `updateSubscription`, so subscribing to the buffer alone gets
    # you a 30 s wait and nothing else. Probed against the 1.61 driver — on a
    # BrowserContext the opt-in set is console/dialog/request/response/
    # requestFinished/requestFailed (`browserContext.yml:264`), of which only
    # `console` is supported here. `page`, `close`, `crash`, `pageError` and
    # the frame events fire unconditionally.
    opt_in::Bool
    # M6 D11: the owner whose channel actually carries this event, and the
    # filter that decides which of its payloads this target wants.
    #
    # This is the first event whose subscription owner differs from the owner
    # the user named, and it is invisible at the call site, so it is said out
    # loud here: `page.yml` has no request/response events at all — only
    # `browserContext.yml` does, each carrying an optional `page`. So
    # `expect_event(page, :request)` subscribes to the page's *context* and
    # drops payloads belonging to other pages.
    subscription_owner::Function      # target -> the owner to subscribe on
    accept::Function                  # (target, params) -> Bool
end

EventSpec(wire, payload) = EventSpec(wire, payload, false)
EventSpec(wire, payload, opt_in) =
    EventSpec(wire, payload, opt_in, identity, (_target, _params) -> true)

# The owner itself, for events whose payload is "this thing, and it happened".
owner_payload(owner, _params) = owner

channel_payload(field, T) =
    (owner, params) -> begin
        ref = get(params, field, nothing)
        obj = ref === nothing ? nothing : from_channel(owner.connection, ref)
        obj isa T || throw(
            DriverError("event payload `$field` did not resolve to a $(nameof(T))"),
        )
        return obj
    end

"Build a `ConsoleMessage` from console event params — same mixin the buffered getter reads."
console_message(params) = ConsoleMessage(
    get(params, "type", ""),
    get(params, "text", ""),
    source_location(get(params, "location", nothing)),
    Float64(get(params, "timestamp", 0)),
)

const PAGE_EVENTS = Dict{Symbol,EventSpec}(
    :close => EventSpec("close", owner_payload),
    :crash => EventSpec("crash", owner_payload),
    :frameattached => EventSpec("frameAttached", channel_payload("frame", Frame)),
    :framedetached => EventSpec("frameDetached", channel_payload("frame", Frame)),
    # M7 D11. NOT opt-in: `download` is absent from page.yml's
    # updateSubscription enum, so the driver sends it unconditionally (probed,
    # tasks/m7-probe.md). Its payload reaches into params for `url` and
    # `suggestedFilename`, which exist nowhere else -- the same shape
    # :requestfailed needed for its failure text.
    # Wrapped in a closure, not passed by name: download_payload lives in
    # downloads.jl, which is included after this file, so the name does not
    # exist yet when this table is built. Same forward reference `:pageerror`
    # makes to page_error in diagnostics.jl, and resolved the same way -- at
    # call time, long after every include has run.
    :download =>
        EventSpec("download", (owner, params) -> download_payload(owner, params)),
    # M7 D13. Opt-in, unlike :download -- `fileChooser` IS in page.yml's
    # updateSubscription enum, so the driver stays silent until asked.
    :filechooser => EventSpec(
        "fileChooser",
        (owner, params) -> file_chooser_payload(owner, params),
        true,
    ),
)

const CONTEXT_EVENTS = Dict{Symbol,EventSpec}(
    :close => EventSpec("close", owner_payload),
    :page => EventSpec("page", channel_payload("page", Page)),
    :console => EventSpec("console", (_owner, params) -> console_message(params), true),
    # The event nests its SerializedError one level deeper than the buffered
    # getter does: params is {error: {error: {message, name, stack}}, page,
    # location}, so `page_error` gets the inner object, not the whole params.
    :pageerror => EventSpec(
        "pageError",
        (_owner, params) -> page_error(get(params, "error", params)),
    ),
    # M6 T12 (D11). All four are opt-in: the driver stays silent until the
    # client asks, and the existing ref-counted enable/disable already handles
    # overlapping blocks.
    :request => EventSpec("request", channel_payload("request", Request), true),
    :response => EventSpec("response", channel_payload("response", Response), true),
    :requestfinished =>
        EventSpec("requestFinished", channel_payload("request", Request), true),
    # The odd one out: its failure text lives in the event params and nowhere
    # else, so a bare Request would silently lose the only interesting thing
    # about it.
    :requestfailed => EventSpec(
        "requestFailed",
        (owner, params) -> RequestFailure(
            from_channel(owner.connection, params["request"])::Request,
            String(something(get(params, "failureText", nothing), "")),
        ),
        true,
    ),
)

# Events the driver really does emit but that `expect_event` does not serve.
# Named separately so the error can say "deferred" rather than "no such event"
# — the difference between a roadmap entry and a typo.
#
# M7 D14 re-read every entry against the source rather than trusting it. The
# table had drifted: `:download` said "Artifact is not wrapped yet" when
# Artifact had been wrapped since M4, so the error told users something false
# about why their event was unsupported. Three entries left in Part C; the
# remaining four are re-checked here, and `deferred_table_is_honest` below is
# the gate that stops the table drifting again.
#
# The messages distinguish "no API for this type" from "there is an API, but
# not an event-shaped one", because those send a reader to different places.
const DEFERRED_EVENTS = Dict(
    # Generated ChannelOwners with no hand-written API: nothing useful could be
    # handed to a caller yet.
    :worker => "Worker has no accessors yet, so the event would yield nothing usable",
    :websocket => "WebSocket has no accessors yet, so the event would yield nothing usable",
    :bindingcall => "BindingCall has no accessors yet, so the event would yield nothing usable",
    # The subtler kind of stale, and the reason this entry is rewritten rather
    # than deleted: `Route` IS wrapped (M6) and fully usable. It is simply not
    # offered as an event, because `route!` is the supported path — an event
    # would hand you a route with no guarantee anyone settles it.
    :route => "Route is wrapped, but interception is `route!`/`with_route`, not an event",
    # The same case as :route, and the one this table exists to catch. T14 took
    # :dialog out on the assumption that it had become reachable; it had not,
    # and for four commits the package answered a question about a wrapped,
    # documented type with "unknown event". It cannot become an event either:
    # subscribing to `dialog` is WHAT disables the driver's auto-dismiss, so the
    # registry owns the subscription and an expect_event form would disarm the
    # safety net by being used (D12).
    :dialog => "Dialog is wrapped, but dialogs are answered with `on_dialog!`/`with_dialog`, not an event",
)

"""
Whether `table` names only events that are genuinely absent from `owner`'s
event table (D14).

Written as a function over its inputs so the gate can be tested *both* ways:
against the real table, which must pass, and against a table with a supported
event added back, which must fail. A gate nobody has watched fail is a gate
nobody knows works.

Returns the offending event names, empty when the table is honest.
"""
deferred_table_is_honest(table, owner) =
    sort([key for key in keys(table) if haskey(events_for(owner), key)])

"""
The four network events as seen from a `Page`: subscribed on the page's
context, filtered down to that page's own traffic (D11).

Built from the context table so the payload mapping cannot drift between the
two spellings of the same event.
"""
const PAGE_NETWORK_EVENTS = Dict{Symbol,EventSpec}(
    key => EventSpec(
        spec.wire,
        spec.payload,
        spec.opt_in,
        owning_context,
        # The driver sends the context every page's traffic; this keeps the
        # page's own. A payload with no `page` at all — a service worker's
        # request — belongs to no page and so is not this one's.
        (target, params) -> begin
            ref = get(params, "page", nothing)
            ref === nothing && return false
            return get(ref, "guid", nothing) == target.guid
        end,
    ) for (key, spec) in CONTEXT_EVENTS if
    key in (:request, :response, :requestfinished, :requestfailed)
)

events_for(page::Page) = merge(PAGE_EVENTS, PAGE_NETWORK_EVENTS)
events_for(::BrowserContext) = CONTEXT_EVENTS
events_for(owner::ChannelOwner) = Dict{Symbol,EventSpec}()

# `:frameAttached`, `:frameattached` and `"frameAttached"` are the same event.
# Case is the only thing that differs between the wire spelling and the natural
# Julia one, so folding it is the whole of the normalisation.
normalize_event(event) = Symbol(lowercase(String(event)))

function event_spec(owner::ChannelOwner, event)
    key = normalize_event(event)
    table = events_for(owner)
    spec = get(table, key, nothing)
    spec === nothing || return spec

    kind = nameof(typeof(owner))
    if haskey(DEFERRED_EVENTS, key)
        # It might be supported on this owner one day, or supported on another
        # owner today; either way, say why rather than listing alternatives.
        throw(
            ArgumentError(
                "event `:$key` is not supported yet — deferred: $(DEFERRED_EVENTS[key]). " *
                "Supported on $kind: $(supported_list(table)).",
            ),
        )
    end
    throw(
        ArgumentError(
            "unknown event `:$key` for $kind. Supported: $(supported_list(table)).",
        ),
    )
end

supported_list(table) = join(sort!([":$k" for k in keys(table)]), ", ")

"""
    EventStream

Live handle to the events of one kind on one owner, handed to a
[`with_events`](@ref) block. Read from it with [`next_event`](@ref) (blocking,
one at a time) or [`pending_events`](@ref) (everything buffered right now).

The buffer is unbounded, so nothing that happens inside the block is dropped
while you are not looking. It is closed when the block ends.

```julia
with_events(ctx, :pageerror) do stream
    click!(locator(page, "#break-everything"))
    next_event(stream; timeout = 5_000).message
end
```

`length(stream)` is the non-consuming count, which is the thing to poll on —
see [`length`](@ref).
"""
struct EventStream
    subscription::Subscription
    event::Symbol
end

"""
    length(stream::EventStream) -> Int

How many events are buffered right now, without consuming any. This is the
one to poll on — `pending_events` drains, so it cannot be used to wait for a
count to be reached.

```julia
timedwait(() -> length(stream) >= 3, 5.0)
```
"""
Base.length(stream::EventStream) = Base.n_avail(stream.subscription.channel)

"""
    pending_events(stream::EventStream) -> Vector

Everything buffered right now, in arrival order. **Drains** the stream: a
second call returns only what arrived since the first, which is what makes it
usable in a loop. Does not block and does not wait for more — to wait for a
particular count, poll [`length`](@ref) first.

```julia
with_events(ctx, :pageerror) do stream
    click!(locator(page, "#break-everything"))
    retry_until(() -> length(stream) >= 2; timeout = 5_000)
    pending_events(stream)         # both of them, and the buffer is now empty
end
```

For one event at a time, blocking, use [`next_event`](@ref); see
[`EventStream`](@ref).
"""
function pending_events(stream::EventStream)
    out = Any[]
    while isready(stream.subscription.channel)
        push!(out, take!(stream.subscription.channel))
    end
    return out
end

"""
    next_event(stream::EventStream; timeout=nothing, predicate=nothing) -> payload

Take the next event off `stream`, waiting up to `timeout` ms for one to arrive.
Raises [`TimeoutError`](@ref) if none does. `timeout` defaults to the
[`set_default_timeout!`](@ref) cascade.

`predicate` skips payloads it returns `false` for; they are consumed, not
requeued — so a rejected payload is gone, not left for the next call.

```julia
with_events(page, :console) do stream
    click!(locator(page, "#log"))
    msg = next_event(stream; predicate = m -> m.type == "error")
    @info "first console error" msg.text
end
```

Blocking and one at a time; [`pending_events`](@ref) is the drain-everything
form, and [`EventStream`](@ref) has the pair side by side.
"""
next_event(stream::EventStream; timeout = nothing, predicate = nothing) =
    take_event!(stream.subscription, stream.event, timeout, predicate)

# The one wait loop behind expect_event / wait_for_event / next_event.
#
# Polls rather than blocking on `take!` because a predicate can reject a
# payload, and because a blocking take cannot be given a deadline. The poll
# interval only bounds how late a *match* is noticed, never whether events are
# kept: the buffer is unbounded and filled by the reader task regardless.
function take_event!(sub::Subscription, event::Symbol, timeout, predicate)
    ms = resolve_event_timeout(sub, timeout)
    deadline = ms == 0 ? nothing : time() + ms / 1_000
    while true
        while isready(sub.channel)
            payload = take!(sub.channel)
            predicate === nothing && return payload
            predicate(payload) && return payload
        end
        # The owner went away with nothing left in the buffer, so no event of
        # this kind can ever arrive. Say that, rather than making the caller
        # sit out a timeout for an answer that is already settled. Checked
        # after the drain above, so a `:close` event that arrived alongside the
        # dispose is still returned.
        if sub.closed
            throw(
                TargetClosedError(
                    "the target closed while waiting for event `:$event`";
                    name = "TargetClosedError",
                ),
            )
        end
        if deadline !== nothing && time() >= deadline
            throw(
                TimeoutError(
                    "timed out after $(ms)ms waiting for event `:$event`";
                    name = "TimeoutError",
                ),
            )
        end
        sleep(0.005)
    end
end

# A Subscription holds a guid, not the owner, so the cascade is resolved through
# whatever object that guid still refers to. A disposed owner leaves nothing to
# inherit from, which correctly falls back to the package default.
function resolve_event_timeout(sub::Subscription, timeout)
    timeout === nothing || return Int(timeout)
    owner = lookup_object(sub.connection, sub.guid)
    return owner === nothing ? DEFAULT_TIMEOUT : resolve_timeout(owner, nothing)
end

"""
    expect_event(f, target, event; timeout=nothing, predicate=nothing) -> payload

Run `f()` and return the first `event` on `target` that it produces.

The subscription is attached **before** `f` runs, so an event the body fires
synchronously is still caught — which is why this takes a block rather than
letting you subscribe and act in two statements:

```julia
popup = expect_event(ctx, :page) do
    click!(locator(page, "#open-popup"))
end
title(popup)
```

`f`'s own return value is discarded; the event payload is what comes back. An
exception from `f` propagates unchanged, and the subscription is released
either way.

`predicate` filters payloads — the first one it accepts is returned. `timeout`
is in milliseconds and defaults to the [`set_default_timeout!`](@ref) cascade;
[`TimeoutError`](@ref) is raised if no matching event arrives.

Supported events, by owner:

| Owner | Event | Payload |
|---|---|---|
| `Page` | `:close`, `:crash` | the `Page` |
| `Page` | `:frameattached`, `:framedetached` | [`Frame`](@ref) |
| `BrowserContext` | `:page` | [`Page`](@ref) — this is how you catch a popup |
| `BrowserContext` | `:close` | the `BrowserContext` |
| `BrowserContext` | `:console` | [`ConsoleMessage`](@ref) |
| `BrowserContext` | `:pageerror` | [`PageError`](@ref) |
| `Page` | `:download` | [`Download`](@ref) — or use [`expect_download`](@ref) |
| `Page` | `:filechooser` | [`FileChooser`](@ref) — or [`expect_file_chooser`](@ref) |

Anything else raises `ArgumentError`. What remains in `DEFERRED_EVENTS` is
deferred rather than designed away — those payload types have no accessors yet.

See also [`wait_for_event`](@ref) and [`with_events`](@ref).
"""
function expect_event(
    f::Function,
    target::ChannelOwner,
    event;
    timeout = nothing,
    predicate = nothing,
)
    spec = event_spec(target, event)
    key = normalize_event(event)
    sub = subscribe_spec(target, spec)
    try
        f()
        return take_event!(sub, key, timeout, predicate)
    finally
        release_spec(target, spec, sub)
    end
end

# Subscribe and, for opt-in events, tell the driver to start sending them.
#
# The enable/disable pair is ref-counted per owner+event: two overlapping
# `expect_event(ctx, :console)` blocks must not have the inner one switch the
# outer one's events off when it finishes.
function subscribe_spec(target::ChannelOwner, spec::EventSpec)
    # D11: for the page-scoped network events this is the page's context, not
    # the page. Everything else subscribes to the owner the user named.
    owner = spec.subscription_owner(target)
    spec.opt_in && update_subscription(owner, spec.wire, true)
    return subscribe(
        owner,
        spec.wire,
        spec.payload,
        (_owner, params) -> spec.accept(target, params),
    )
end

function release_spec(target::ChannelOwner, spec::EventSpec, sub::Subscription)
    owner = spec.subscription_owner(target)
    close(sub)
    spec.opt_in && update_subscription(owner, spec.wire, false)
    return nothing
end

function update_subscription(target::ChannelOwner, event::AbstractString, enabled::Bool)
    conn = target.connection
    key = (target.guid, String(event))
    send = lock(conn.lock) do
        n = get(conn.event_optins, key, 0)
        n = enabled ? n + 1 : max(0, n - 1)
        n == 0 ? delete!(conn.event_optins, key) : (conn.event_optins[key] = n)
        # Only the 0↔1 transitions reach the driver.
        enabled ? n == 1 : n == 0
    end
    send || return nothing
    try
        raw_update_subscription(target, event, enabled)
    catch e
        # Disabling an event on an owner that has already closed is not a
        # failure worth surfacing — the subscription is gone either way.
        enabled && rethrow()
    end
    return nothing
end

raw_update_subscription(ctx::BrowserContext, event, enabled) =
    _browser_context_update_subscription(ctx; event = String(event), enabled)
raw_update_subscription(page::Page, event, enabled) =
    _page_update_subscription(page; event = String(event), enabled)

"""
    wait_for_event(target, event; timeout=nothing, predicate=nothing) -> payload

Wait for the next `event` on `target` without running anything first.

Use this only when whatever triggers the event is already in flight — a page
closing on its own, say. When *you* trigger it, use [`expect_event`](@ref):
subscribing after the trigger is a race this cannot protect you from.

Same events, payloads, `predicate` and `timeout` as [`expect_event`](@ref).

```julia
# The page closes itself after a countdown that is already running.
wait_for_event(page, :close; timeout = 10_000)
```

Raises [`TimeoutError`](@ref) if nothing arrives in time.
"""
wait_for_event(target::ChannelOwner, event; timeout = nothing, predicate = nothing) =
    expect_event(() -> nothing, target, event; timeout, predicate)

"""
    with_events(f, target, event) -> f's return value

Run `f(stream)` with a live [`EventStream`](@ref) of every `event` on `target`,
for collecting several events rather than waiting for one:

```julia
errors = with_events(ctx, :pageerror) do stream
    click!(locator(page, "#break-everything"))
    sleep(0.5)
    pending_events(stream)
end
```

The buffer is unbounded and attached before `f` runs, so nothing that happens
inside the block is missed. It is released when the block ends, however it
ends. Read the stream with [`next_event`](@ref) or [`pending_events`](@ref).
"""
function with_events(f::Function, target::ChannelOwner, event)
    spec = event_spec(target, event)
    sub = subscribe_spec(target, spec)
    stream = EventStream(sub, normalize_event(event))
    try
        return f(stream)
    finally
        release_spec(target, spec, sub)
    end
end
