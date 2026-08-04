# Protocol connection: message id assignment, blocking request/reply,
# and the guid → object registry driven by __create__/__dispose__ events.
# Wire-protocol knowledge stops here — api.jl never sees raw messages.

"""
Remote object owned by the protocol connection. Concrete channel-owner types
(`Browser`, `Page`, …) are registered in `CHANNEL_TYPES` (see objects.jl);
protocol types without a registered wrapper become plain `RemoteObject`s.
"""
abstract type ChannelOwner end

# Field layout shared by every channel owner; kept in one macro so concrete
# types stay in sync with what Connection expects.
macro channel_owner_fields()
    esc(quote
        connection::Connection
        type::String
        guid::String
        initializer::Dict{String,Any}
    end)
end

mutable struct Connection
    transport::Transport
    objects::Dict{String,ChannelOwner}
    children::Dict{String,Vector{String}}          # parent guid → child guids
    parents::Dict{String,String}                   # child guid → parent guid
    # Main frame guid → its page's guid. The protocol parents a page's MAIN
    # frame to the browser context, not to the page (only child frames hang off
    # the page), so the __create__ tree alone walks straight past the page when
    # inheriting a setting. This records the hop the protocol leaves out; it is
    # deliberately separate from `parents`, which stays the protocol's own tree
    # so the dispose cascade is unaffected.
    settings_parents::Dict{String,String}
    timeouts::Dict{String,Any}                     # guid → timeout settings (timeouts.jl)
    subscriptions::Dict{String,Vector}              # guid → subscriptions (api/events.jl)
    callbacks::Dict{Int,Channel{Any}}              # message id → reply slot
    last_id::Int
    closed_error::Union{PlaywrightError,Nothing}
    lock::ReentrantLock

    function Connection(transport::Transport)
        conn = new(
            transport,
            Dict{String,ChannelOwner}(),
            Dict{String,Vector{String}}(),
            Dict{String,String}(),
            Dict{String,String}(),
            Dict{String,Any}(),
            Dict{String,Vector}(),
            Dict{Int,Channel{Any}}(),
            0,
            nothing,
            ReentrantLock(),
        )
        transport.on_message = msg -> dispatch(conn, msg)
        transport.on_close = () -> handle_transport_close(conn)
        return conn
    end
end

mutable struct RemoteObject <: ChannelOwner
    @channel_owner_fields
end

# type name (wire) → concrete ChannelOwner constructor; populated by objects.jl.
const CHANNEL_TYPES = Dict{String,Any}()

"Start the transport reader; the connection is usable afterwards."
start!(conn::Connection) = (start_reading!(conn.transport); conn)

lookup_object(conn::Connection, guid::AbstractString) =
    lock(conn.lock) do
        get(conn.objects, guid, nothing)
    end

"""
    from_channel(conn, ref) -> object | nothing

Resolve a protocol `{"guid" => …}` reference to the registered object.
`nothing` passes through, so optional result fields resolve directly.
"""
from_channel(conn::Connection, ::Nothing) = nothing
from_channel(conn::Connection, ref::AbstractDict) = lookup_object(conn, ref["guid"])

"""
    to_wire(x) -> JSON-encodable value

Convert an argument to its protocol representation: channel owners become
`{"guid" => …}` references and byte vectors become base64 strings, recursively
through containers. The generated channel layer runs every outgoing parameter
through this, so wire encoding lives here rather than in generated code.
"""
to_wire(x) = x
to_wire(obj::ChannelOwner) = Dict{String,Any}("guid" => obj.guid)
to_wire(bytes::Vector{UInt8}) = base64encode(bytes)
to_wire(v::AbstractVector) = Any[to_wire(x) for x in v]
to_wire(d::AbstractDict) = Dict{String,Any}(String(k) => to_wire(v) for (k, v) in d)

"""
    send_message(conn, guid, method, params) -> result

Send one protocol request and block until the driver replies. Returns the
`result` payload (an `AbstractDict` or `nothing`); raises `PlaywrightError`
for error replies and when the connection closes mid-call.
"""
function send_message(
    conn::Connection,
    guid::AbstractString,
    method::AbstractString,
    params::AbstractDict,
)
    reply = Channel{Any}(1)
    id = lock(conn.lock) do
        conn.closed_error === nothing || throw(conn.closed_error)
        conn.last_id += 1
        conn.callbacks[conn.last_id] = reply
        conn.last_id
    end
    msg = Dict{String,Any}(
        "id" => id,
        "guid" => guid,
        "method" => method,
        "params" => params,
        "metadata" => Dict{String,Any}(),
    )
    try
        send(conn.transport, msg)
    catch err
        lock(conn.lock) do
            delete!(conn.callbacks, id)
        end
        conn.closed_error === nothing || throw(conn.closed_error)
        rethrow(err)
    end
    value = take!(reply)
    value isa PlaywrightError && throw(value)
    return value
end

send_message(obj::ChannelOwner, method::AbstractString, params::AbstractDict) =
    send_message(obj.connection, obj.guid, method, params)

function dispatch(conn::Connection, msg::AbstractDict)
    if haskey(msg, "id")
        callback = lock(conn.lock) do
            pop!(conn.callbacks, msg["id"], nothing)
        end
        callback === nothing && return   # stray reply; drop it
        if haskey(msg, "error") && !haskey(msg, "result")
            put!(callback, driver_error(msg["error"]["error"], get(msg, "log", nothing)))
        else
            put!(callback, get(msg, "result", nothing))
        end
        return
    end
    method = get(msg, "method", "")
    if method == "__create__"
        create_remote_object(conn, msg["guid"], msg["params"])
    elseif method == "__dispose__"
        dispose_object(conn, msg["guid"])
    elseif method == "navigated"
        frame_navigated(conn, msg["guid"], msg["params"])
    elseif method == "frameDetached"
        frame_detached(conn, msg["params"])
    else
        # Any other server event goes to whoever subscribed. An unknown guid or
        # an event nobody wants must never kill the read loop, so routing is
        # silent about both.
        deliver_event(conn, msg["guid"], method, get(msg, "params", Dict{String,Any}()))
    end
    return
end

"""
A frame's `url` and `name` live in its initializer, which the driver only
sends once. Without folding `navigated` back in, `url(frame)` would report
wherever the frame started — usually `about:blank`.
"""
function frame_navigated(conn::Connection, guid::AbstractString, params::AbstractDict)
    frame = lookup_object(conn, guid)
    frame === nothing && return
    lock(conn.lock) do
        frame.initializer["url"] = get(params, "url", "")
        frame.initializer["name"] = get(params, "name", "")
    end
    return
end

"""
Detached frames are *not* `__dispose__`d by the driver — it reports
`frameDetached` on the page instead — so without this a removed iframe would
linger in `frames(page)` forever.
"""
function frame_detached(conn::Connection, params::AbstractDict)
    ref = get(params, "frame", nothing)
    ref === nothing && return
    dispose_object(conn, ref["guid"])
    return
end

function create_remote_object(
    conn::Connection,
    parent_guid::AbstractString,
    params::AbstractDict,
)
    type = params["type"]
    guid = params["guid"]
    initializer = Dict{String,Any}(pairs(get(params, "initializer", Dict{String,Any}())))
    constructor = get(CHANNEL_TYPES, type, RemoteObject)
    obj = constructor(conn, String(type), String(guid), initializer)
    lock(conn.lock) do
        conn.objects[guid] = obj
        push!(get!(Vector{String}, conn.children, parent_guid), guid)
        conn.parents[guid] = String(parent_guid)
        main = get(initializer, "mainFrame", nothing)
        if type == "Page" && main isa AbstractDict && haskey(main, "guid")
            conn.settings_parents[String(main["guid"])] = String(guid)
        end
    end
    return obj
end

function dispose_object(conn::Connection, guid::AbstractString)
    lock(conn.lock) do
        dispose_locked(conn, String(guid))
    end
end

function dispose_locked(conn::Connection, guid::String)
    for child in pop!(conn.children, guid, String[])
        dispose_locked(conn, child)
    end
    delete!(conn.objects, guid)
    delete!(conn.parents, guid)
    # Both ends of the hop have to go: the frame's own entry, and any entry
    # pointing at this guid when it is the page that just died. A stale entry
    # would send the walk into a disposed page and lose the context's setting.
    delete!(conn.settings_parents, guid)
    filter!(pair -> last(pair) != guid, conn.settings_parents)
    # Side tables keyed by guid have to be pruned here too, or they grow for
    # the life of the connection. Subscriptions matter most: their buffers are
    # unbounded, so a dropped owner must not keep its backlog alive (D1a).
    delete!(conn.timeouts, guid)
    close_subscriptions_locked(conn, guid)
    return
end

function handle_transport_close(conn::Connection)
    # Deliberately a DriverError, not a TargetClosedError: the driver process
    # exiting is not an orderly target close, and a caller catching
    # TargetClosedError to shrug off a closed page should not silently swallow
    # a driver crash.
    err = DriverError("connection closed: the Playwright driver exited")
    pending = lock(conn.lock) do
        conn.closed_error = err
        callbacks = collect(values(conn.callbacks))
        empty!(conn.callbacks)
        callbacks
    end
    for callback in pending
        put!(callback, err)
    end
    # No further events can arrive, so every buffer still attached is dead
    # weight. playwright() teardown lands here.
    close_all_subscriptions(conn)
    return
end

Base.close(conn::Connection) = close(conn.transport)
