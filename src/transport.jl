# Length-prefixed JSON pipe transport: each frame on the wire is a 4-byte
# little-endian payload length followed by that many bytes of UTF-8 JSON.
# This layer knows nothing about the protocol — it moves parsed Dicts.

"""
    Transport(input, output; on_message, on_close=() -> nothing)

Frame transport reading protocol messages from `input` and writing them to
`output`. `on_message(msg::AbstractDict)` is called for every received frame
(from the reader task); `on_close()` is called exactly once when the stream
ends — EOF, driver crash, or explicit `close`.

Call [`start_reading!`](@ref) to launch the reader task.
"""
mutable struct Transport
    input::IO
    output::IO
    on_message::Function
    on_close::Function
    reader::Union{Task,Nothing}
    closed::Bool
    close_notified::Bool
    lock::ReentrantLock
end

function Transport(input::IO, output::IO;
                   on_message::Function, on_close::Function = () -> nothing)
    return Transport(input, output, on_message, on_close, nothing, false, false,
                     ReentrantLock())
end

"""
    send(transport, msg::AbstractDict)

Serialize `msg` to JSON and write it as one length-prefixed frame.
"""
function send(transport::Transport, msg::AbstractDict)
    transport.closed && error("transport is closed")
    payload = Vector{UInt8}(codeunits(JSON.json(msg)))
    lock(transport.lock) do
        write(transport.output, htol(UInt32(length(payload))))
        write(transport.output, payload)
        flush(transport.output)
    end
    return nothing
end

"""
    start_reading!(transport) -> Task

Spawn the reader task: loop reading frames and dispatching them to
`on_message` until EOF or close, then fire `on_close`.
"""
function start_reading!(transport::Transport)
    transport.reader = @async begin
        try
            while !transport.closed
                len = ltoh(read(transport.input, UInt32))
                payload = read(transport.input, len)
                length(payload) == len || break   # EOF mid-frame
                transport.on_message(JSON.parse(String(payload)))
            end
        catch err
            # EOFError / stream-closed are the normal shutdown paths; anything
            # else is still terminal for the connection, so treat it the same
            # but keep the error visible for debugging.
            if !(err isa EOFError || err isa Base.IOError || err isa InvalidStateException)
                @debug "transport reader terminated" exception = (err, catch_backtrace())
            end
        finally
            notify_closed!(transport)
        end
    end
    return transport.reader
end

function notify_closed!(transport::Transport)
    do_notify = lock(transport.lock) do
        first = !transport.close_notified
        transport.close_notified = true
        transport.closed = true
        first
    end
    do_notify && transport.on_close()
    return nothing
end

function Base.close(transport::Transport)
    transport.closed = true
    for io in (transport.input, transport.output)
        io === devnull && continue
        try
            close(io)
        catch
        end
    end
    transport.reader === nothing && notify_closed!(transport)
    return nothing
end
