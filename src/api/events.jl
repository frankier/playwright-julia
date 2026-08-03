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

    function Subscription(owner::ChannelOwner, event::AbstractString)
        # Unbounded: put! from the reader task must never block, or a slow
        # consumer would stall the whole protocol connection.
        sub = new(owner.connection, owner.guid, String(event), Channel{Any}(Inf), false)
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
function subscribe(owner::ChannelOwner, event::AbstractString)
    sub = Subscription(owner, event)
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
    drain!(sub.channel)
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
            put!(sub.channel, params)
        catch
            # Channel closed under us; dispatch to a dead subscription is a
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
        drain!(sub.channel)
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
