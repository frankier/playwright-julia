# WebSocket routing (SPEC-M8 Part D), against the fake connection.
#
# The lifetime comes before the behaviour, which is the ordering M6's routing
# and M7's dialogs both used and both benefited from: a dispatcher that leaks,
# dies or deadlocks presents to a user as a page that hangs, metres from the
# cause.
#
# This is the *third* use of the registry + dispatcher-task shape. The rule from
# tasks/todo.md: it is a reuse, not an invention — if it starts diverging from
# routing.jl's shape, stop and say why in the spec.
#
# Every wait here is bounded. A socket nobody answers blocks its page, and a
# test that reproduces that by hanging is not a test.

using Playwright:
    WebSocketRoute,
    close_ws!,
    connect!,
    on_close!,
    on_message_from_page!,
    on_message_from_server!,
    route_web_socket!,
    send_to_page!,
    send_to_server!,
    unroute_web_socket!,
    with_web_socket_route
using Base64: base64decode, base64encode

const WS_GUID_SEQ = Ref(0)

"""
Announce a WebSocketRoute on `owner_guid`, as the driver does when an armed
pattern matches.

Returns the route object, so a test can act on the same thing the handler got.
"""
function fire_web_socket_route(f, owner_guid = "context@1"; url = "ws://probe.test/ws")
    guid = "wsroute@$(WS_GUID_SEQ[] += 1)"
    send_create(
        f.fake,
        owner_guid,
        "WebSocketRoute",
        guid,
        Dict{String,Any}("url" => url, "protocols" => Any[]),
    )
    @test timedwait(
        () -> Playwright.lookup_object(f.fake.connection, guid) !== nothing,
        5.0,
    ) === :ok
    send_event(
        f.fake,
        owner_guid,
        "webSocketRoute",
        Dict{String,Any}("webSocketRoute" => Dict("guid" => guid)),
    )
    return Playwright.lookup_object(f.fake.connection, guid)
end

"""
Announce a frame on a live `WebSocketRoute`, as the driver does once the socket
is carrying traffic.

`message` is the wire spelling — a `String` — and `is_base64` says whether the
driver encoded bytes into it.
"""
ws_frame(f, route, event, message; is_base64 = false) = send_event(
    f.fake,
    route.guid,
    event,
    Dict{String,Any}("message" => message, "isBase64" => is_base64),
)

"Announce a close on either side of a live `WebSocketRoute`."
ws_close_frame(f, route, event; code = nothing, reason = nothing) = send_event(
    f.fake,
    route.guid,
    event,
    Dict{String,Any}("code" => code, "reason" => reason, "wasClean" => true),
)

"""
Route `**/ws` on the context, run `setup(wsr)` for the socket it intercepts, and
hand `body` the live route once the handler has finished setting it up.

The wait is the point: a frame announced before the handler has registered its
callbacks reaches a route nobody is subscribed to and is dropped, which would
make the tests below pass or fail for reasons that have nothing to do with what
they assert.
"""
function with_live_socket(body, f; setup = _ -> nothing)
    armed = Ref(false)
    reg = route_web_socket!(f.context, "**/ws") do wsr
        setup(wsr)
        armed[] = true
    end
    route = fire_web_socket_route(f)
    ws_until(() -> armed[])
    try
        return body(route, reg)
    finally
        unroute_web_socket!(f.context, reg)
    end
end

"Every request of `method` the fake driver saw, oldest first."
ws_sent(f, method) = filter(m -> get(m, "method", "") == method, f.requests)

"Wait for `cond`, failing rather than hanging. Never a bare sleep."
function ws_until(cond, seconds = 10.0)
    timedwait(cond, seconds) === :ok || error("condition never held within $(seconds)s")
    return true
end

@testset "WebSocket routing" begin
    @testset "registering arms the driver's patterns" begin
        f = har_fixture()
        reg = route_web_socket!(_ -> nothing, f.context, "**/ws")

        armed = only(
            filter(
                m -> get(m, "method", "") == "setWebSocketInterceptionPatterns",
                f.requests,
            ),
        )
        @test armed["guid"] == "context@1"
        @test [p["glob"] for p in armed["params"]["patterns"]] == ["**/ws"]

        unroute_web_socket!(f.context, reg)
        # Unregistering clears them again, so the driver stops sending what
        # nobody wants — the same shape as route!'s pattern union.
        last = filter(
            m -> get(m, "method", "") == "setWebSocketInterceptionPatterns",
            f.requests,
        )[end]
        @test isempty(last["params"]["patterns"])

        close(f.conn)
    end

    @testset "the dispatcher spawns on the first registration, not before" begin
        f = har_fixture()
        @test Playwright.ws_registry_for(f.context) === nothing

        reg = route_web_socket!(_ -> nothing, f.context, "**/ws")
        registry = Playwright.ws_registry_for(f.context)
        @test registry !== nothing
        @test registry.task isa Task

        unroute_web_socket!(f.context, reg)
        # ...and goes away with the last one, rather than living for the
        # process.
        @test Playwright.ws_registry_for(f.context) === nothing

        close(f.conn)
    end

    @testset "the handler gets the route the driver announced" begin
        f = har_fixture()
        got = Ref{Any}(nothing)
        reg = route_web_socket!(wsr -> (got[] = wsr), f.context, "**/ws")

        route = fire_web_socket_route(f)
        ws_until(() -> got[] !== nothing)
        @test got[] === route
        @test got[] isa WebSocketRoute

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "handlers never run on the transport reader task" begin
        # The world-age trap events.jl's header opens with, asserted rather than
        # trusted — the same assertion test_dialogs.jl makes, by the same means.
        # User code on the reader task cannot call anything defined after the
        # connection started, and would block the connection its own calls need.
        f = har_fixture()
        ran_on = Ref{Any}(nothing)
        reg = route_web_socket!(_ -> (ran_on[] = current_task()), f.context, "**/ws")
        registry = Playwright.ws_registry_for(f.context)

        fire_web_socket_route(f)
        ws_until(() -> ran_on[] !== nothing)

        @test ran_on[] === registry.task
        @test ran_on[] !== f.conn.transport.reader

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "handlers run sequentially, never concurrently" begin
        f = har_fixture()
        overlapping = Ref(false)
        inside = Ref(0)
        done = Ref(0)
        reg = route_web_socket!(f.context, "**/ws") do _
            inside[] += 1
            inside[] > 1 && (overlapping[] = true)
            yield()
            inside[] -= 1
            done[] += 1
        end

        fire_web_socket_route(f)
        fire_web_socket_route(f)
        fire_web_socket_route(f)
        ws_until(() -> done[] == 3)
        @test !overlapping[]

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "the newest matching registration wins" begin
        f = har_fixture()
        winner = Ref("")
        old = route_web_socket!(_ -> (winner[] = "old"), f.context, "**/ws")
        new = route_web_socket!(_ -> (winner[] = "new"), f.context, "**/ws")

        fire_web_socket_route(f)
        ws_until(() -> !isempty(winner[]))
        @test winner[] == "new"

        unroute_web_socket!(f.context, new)
        unroute_web_socket!(f.context, old)
        close(f.conn)
    end

    @testset "a handler that throws is collected and rethrown" begin
        f = har_fixture()
        reg = route_web_socket!(_ -> error("handler boom"), f.context, "**/ws")

        fire_web_socket_route(f)
        ws_until(() -> !isempty(reg.exceptions))

        # Not raised where it happened — there is no user task there — so it is
        # rethrown at unregistration, exactly as route!'s are.
        @test_throws ErrorException unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "a throwing handler does not kill the dispatcher" begin
        f = har_fixture()
        calls = Ref(0)
        reg = route_web_socket!(f.context, "**/ws") do _
            calls[] += 1
            error("boom")
        end

        fire_web_socket_route(f)
        ws_until(() -> calls[] == 1)
        fire_web_socket_route(f)
        # The second one still arrives, which is the whole point of collecting
        # rather than propagating.
        ws_until(() -> calls[] == 2)

        @test_throws Exception unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "several exceptions become a CompositeException" begin
        f = har_fixture()
        calls = Ref(0)
        reg = route_web_socket!(f.context, "**/ws") do _
            calls[] += 1
            error("boom $(calls[])")
        end

        fire_web_socket_route(f)
        fire_web_socket_route(f)
        ws_until(() -> length(reg.exceptions) == 2)

        @test_throws CompositeException unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "unroute_web_socket! is idempotent, and clears all" begin
        f = har_fixture()
        a = route_web_socket!(_ -> nothing, f.context, "**/a")
        route_web_socket!(_ -> nothing, f.context, "**/b")

        unroute_web_socket!(f.context, a)
        unroute_web_socket!(f.context, a)   # again: a no-op, not an error
        @test length(Playwright.ws_registry_for(f.context).registrations) == 1

        unroute_web_socket!(f.context)
        @test Playwright.ws_registry_for(f.context) === nothing
        unroute_web_socket!(f.context)      # nothing registered: still a no-op
        @test Playwright.ws_registry_for(f.context) === nothing

        close(f.conn)
    end

    @testset "with_web_socket_route unregisters even when the body throws" begin
        f = har_fixture()
        @test_throws ErrorException with_web_socket_route(
            f.context,
            "**/ws",
            _ -> nothing,
        ) do
            error("the body failed")
        end
        @test Playwright.ws_registry_for(f.context) === nothing

        # ...and returns the body's value on the way that does not throw.
        @test with_web_socket_route(f.context, "**/ws", _ -> nothing) do
            42
        end == 42
        @test Playwright.ws_registry_for(f.context) === nothing

        close(f.conn)
    end

    @testset "a Page target arms the page's own channel" begin
        # The registry keys on the target the caller named — the probe found
        # delivery is symmetric, so no filtering step is needed (T17, OQ2).
        f = har_fixture()
        reg = route_web_socket!(_ -> nothing, f.page, "**/ws")

        armed = only(
            filter(
                m -> get(m, "method", "") == "setWebSocketInterceptionPatterns",
                f.requests,
            ),
        )
        @test armed["guid"] == "page@1"

        got = Ref{Any}(nothing)
        unroute_web_socket!(f.page, reg)
        reg2 = route_web_socket!(wsr -> (got[] = wsr), f.page, "**/ws")
        fire_web_socket_route(f, "page@1")
        ws_until(() -> got[] !== nothing)
        @test got[] isa WebSocketRoute

        unroute_web_socket!(f.page, reg2)
        close(f.conn)
    end

    @testset "a handler that registers nothing is legal" begin
        # No unsettled-route warning, because a WebSocket route has no settle. A
        # handler that registers nothing is a socket that mocks everything and
        # answers nothing, which is a legitimate thing to want — proving a page
        # survives a dead socket.
        f = har_fixture()
        logger = Test.TestLogger(; min_level = Base.CoreLogging.Warn)
        Base.CoreLogging.with_logger(logger) do
            reg = route_web_socket!(_ -> nothing, f.context, "**/ws")
            fire_web_socket_route(f)
            ws_until(() -> any(m -> get(m, "method", "") == "ensureOpened", f.requests))
            unroute_web_socket!(f.context, reg)
        end
        @test isempty(filter(r -> r.level == Base.CoreLogging.Warn, logger.logs))

        close(f.conn)
    end

    @testset "the socket is opened once the handler has set it up" begin
        # ensureOpened is what lets the page's WebSocket fire `onopen` in mock
        # mode. Without it the handler runs, registers its callbacks, and the
        # page waits forever for a socket that never opens.
        f = har_fixture()
        reg = route_web_socket!(_ -> nothing, f.context, "**/ws")
        route = fire_web_socket_route(f)

        ws_until(() -> any(m -> get(m, "method", "") == "ensureOpened", f.requests))
        opened = only(filter(m -> get(m, "method", "") == "ensureOpened", f.requests))
        @test opened["guid"] == route.guid

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    # --- T19: connect!, the send verbs, binary ---------------------------------

    @testset "connect! switches the route from mock to proxy" begin
        # Whether connect! was called is the entire mode switch. Nothing else
        # distinguishes the two modes, which is why the flag is worth asserting
        # directly and not only through its consequences.
        f = har_fixture()
        reg = route_web_socket!(connect!, f.context, "**/ws")
        route = fire_web_socket_route(f)

        ws_until(() -> !isempty(ws_sent(f, "connect")))
        @test only(ws_sent(f, "connect"))["guid"] == route.guid
        @test Playwright.ws_is_connected(route)

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "a route is in mock mode until connect!" begin
        f = har_fixture()
        reg = route_web_socket!(_ -> nothing, f.context, "**/ws")
        route = fire_web_socket_route(f)

        ws_until(() -> !isempty(ws_sent(f, "ensureOpened")))
        @test !Playwright.ws_is_connected(route)
        @test isempty(ws_sent(f, "connect"))

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "connecting twice raises rather than reconnecting" begin
        f = har_fixture()
        second = Ref{Any}(nothing)
        reg = route_web_socket!(f.context, "**/ws") do wsr
            connect!(wsr)
            second[] = try
                connect!(wsr)
                nothing
            catch e
                e
            end
        end

        fire_web_socket_route(f)
        ws_until(() -> second[] !== nothing)
        @test second[] isa ArgumentError
        # One socket, one connection: the second attempt must not reach the wire.
        @test length(ws_sent(f, "connect")) == 1

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "a connected route is not also ensureOpened" begin
        # ensureOpened is what opens a *mocked* socket. A proxied one is opened
        # by the server it connected to, and asking for both is asking the
        # driver to open the same socket twice.
        f = har_fixture()
        reg = route_web_socket!(connect!, f.context, "**/ws")

        fire_web_socket_route(f)
        ws_until(() -> !isempty(ws_sent(f, "connect")))
        unroute_web_socket!(f.context, reg)   # waits for the handler to finish
        @test isempty(ws_sent(f, "ensureOpened"))

        close(f.conn)
    end

    @testset "send_to_page! sends a String as text" begin
        f = har_fixture()
        reg = route_web_socket!(wsr -> send_to_page!(wsr, "pong"), f.context, "**/ws")
        route = fire_web_socket_route(f)

        ws_until(() -> !isempty(ws_sent(f, "sendToPage")))
        sent = only(ws_sent(f, "sendToPage"))
        @test sent["guid"] == route.guid
        @test sent["params"]["message"] == "pong"
        @test sent["params"]["isBase64"] == false

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "send_to_page! base64-encodes bytes" begin
        f = har_fixture()
        bytes = UInt8[0x00, 0xff, 0x10, 0x80]
        reg = route_web_socket!(wsr -> send_to_page!(wsr, bytes), f.context, "**/ws")
        fire_web_socket_route(f)

        ws_until(() -> !isempty(ws_sent(f, "sendToPage")))
        sent = only(ws_sent(f, "sendToPage"))
        @test sent["params"]["isBase64"] == true
        # The caller never sees the flag: bytes in, bytes out of the encoding.
        @test base64decode(sent["params"]["message"]) == bytes

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "a wire message decodes back to the type it was sent as" begin
        # The other half of the round trip: what the driver hands back. Bytes
        # sent as bytes must arrive as `Vector{UInt8}`, not as a base64 String
        # the caller has to know to decode.
        text = Playwright.ws_message_from_wire("hello", false)
        @test text isa String
        @test text == "hello"

        bytes = UInt8[0xde, 0xad, 0xbe, 0xef]
        back = Playwright.ws_message_from_wire(base64encode(bytes), true)
        @test back isa Vector{UInt8}
        @test back == bytes
    end

    @testset "send_to_server! in mock mode raises before the wire" begin
        f = har_fixture()
        thrown = Ref{Any}(nothing)
        reg = route_web_socket!(f.context, "**/ws") do wsr
            thrown[] = try
                send_to_server!(wsr, "hello")
                nothing
            catch e
                e
            end
        end

        fire_web_socket_route(f)
        ws_until(() -> thrown[] !== nothing)
        @test thrown[] isa ArgumentError
        # "Before the wire" is the claim, so the absence of the message is the
        # test. A driver-side rejection would be a different, later failure.
        @test isempty(ws_sent(f, "sendToServer"))
        @test occursin("connect!", sprint(showerror, thrown[]))

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "send_to_server! sends text and bytes once connected" begin
        f = har_fixture()
        bytes = UInt8[0x01, 0x02, 0xfe]
        reg = route_web_socket!(f.context, "**/ws") do wsr
            connect!(wsr)
            send_to_server!(wsr, "hello")
            send_to_server!(wsr, bytes)
        end

        fire_web_socket_route(f)
        ws_until(() -> length(ws_sent(f, "sendToServer")) == 2)
        text, binary = ws_sent(f, "sendToServer")
        @test text["params"] == Dict("message" => "hello", "isBase64" => false)
        @test binary["params"]["isBase64"] == true
        @test base64decode(binary["params"]["message"]) == bytes

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "close_ws! closes the page's socket with code and reason" begin
        f = har_fixture()
        reg = route_web_socket!(f.context, "**/ws") do wsr
            close_ws!(wsr; code = 4001, reason = "done here")
        end
        route = fire_web_socket_route(f)

        ws_until(() -> !isempty(ws_sent(f, "closePage")))
        closed = only(ws_sent(f, "closePage"))
        @test closed["guid"] == route.guid
        @test closed["params"]["code"] == 4001
        @test closed["params"]["reason"] == "done here"
        # A close the user asked for is a clean one; an unclean close is what
        # the *socket* reports, not something this API can produce.
        @test closed["params"]["wasClean"] == true

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "close_ws! omits a code and reason nobody gave" begin
        f = har_fixture()
        reg = route_web_socket!(close_ws!, f.context, "**/ws")
        fire_web_socket_route(f)

        ws_until(() -> !isempty(ws_sent(f, "closePage")))
        params = only(ws_sent(f, "closePage"))["params"]
        @test !haskey(params, "code")
        @test !haskey(params, "reason")

        unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    # --- T20: callbacks, and the subscriptions that must not leak --------------

    @testset "a page message reaches on_message_from_page!" begin
        f = har_fixture()
        got = Ref{Any}(nothing)
        with_live_socket(
            f;
            setup = wsr -> on_message_from_page!(msg -> (got[] = msg), wsr),
        ) do route, _
            ws_frame(f, route, "messageFromPage", "ping")
            ws_until(() -> got[] !== nothing)
            @test got[] == "ping"
            @test got[] isa String
        end
        close(f.conn)
    end

    @testset "a binary page message arrives as bytes" begin
        # The caller never names base64 — in this direction the decode is the
        # half T19 could only test through its helper.
        f = har_fixture()
        got = Ref{Any}(nothing)
        bytes = UInt8[0x01, 0x02, 0x03, 0x04]
        with_live_socket(
            f;
            setup = wsr -> on_message_from_page!(msg -> (got[] = msg), wsr),
        ) do route, _
            ws_frame(f, route, "messageFromPage", base64encode(bytes); is_base64 = true)
            ws_until(() -> got[] !== nothing)
            @test got[] isa Vector{UInt8}
            @test got[] == bytes
        end
        close(f.conn)
    end

    @testset "a server message reaches on_message_from_server!" begin
        f = har_fixture()
        got = Ref{Any}(nothing)
        with_live_socket(
            f;
            setup = function (wsr)
                connect!(wsr)
                on_message_from_server!(msg -> (got[] = msg), wsr)
            end,
        ) do route, _
            ws_frame(f, route, "messageFromServer", "from-server:ping")
            ws_until(() -> got[] !== nothing)
            @test got[] == "from-server:ping"
        end
        close(f.conn)
    end

    @testset "an unhandled server message is forwarded to the page" begin
        # The default in proxy mode: a socket nobody rewrote behaves like the
        # socket the page asked for.
        f = har_fixture()
        with_live_socket(f; setup = connect!) do route, _
            ws_frame(f, route, "messageFromServer", "hello")
            ws_until(() -> !isempty(ws_sent(f, "sendToPage")))
            sent = only(ws_sent(f, "sendToPage"))
            @test sent["guid"] == route.guid
            @test sent["params"]["message"] == "hello"
            @test sent["params"]["isBase64"] == false
        end
        close(f.conn)
    end

    @testset "a handled server message is swallowed, as intended" begin
        # D12's sharp edge, pinned rather than fixed: a callback *replaces* the
        # forwarding for its direction, so a callback that does not forward
        # silently drops every server message. It is Playwright's semantics; if
        # they ever change upstream, this test is what tells us.
        f = har_fixture()
        seen = Ref(0)
        with_live_socket(
            f;
            setup = function (wsr)
                connect!(wsr)
                on_message_from_server!(_ -> (seen[] += 1), wsr)
            end,
        ) do route, _
            ws_frame(f, route, "messageFromServer", "hello")
            ws_until(() -> seen[] == 1)
            @test isempty(ws_sent(f, "sendToPage"))
        end
        close(f.conn)
    end

    @testset "an unhandled page message is forwarded to the server" begin
        f = har_fixture()
        with_live_socket(f; setup = connect!) do route, _
            ws_frame(f, route, "messageFromPage", "ping")
            ws_until(() -> !isempty(ws_sent(f, "sendToServer")))
            @test only(ws_sent(f, "sendToServer"))["params"]["message"] == "ping"
        end
        close(f.conn)
    end

    @testset "in mock mode an unhandled page message goes nowhere" begin
        # There is no server to forward to, and inventing one by connecting
        # would make mock mode contact the network it exists to avoid.
        f = har_fixture()
        with_live_socket(f) do route, _
            ws_frame(f, route, "messageFromPage", "ping")
            ws_frame(f, route, "messageFromPage", "ping again")
            # Nothing to wait *for*, so wait for something that proves the
            # dispatcher got this far: a later frame it does act on.
            ws_frame(f, route, "messageFromServer", "forwarded")
            ws_until(() -> !isempty(ws_sent(f, "sendToPage")))
            @test isempty(ws_sent(f, "sendToServer"))
        end
        close(f.conn)
    end

    @testset "on_close! sees the code and the reason" begin
        f = har_fixture()
        got = Ref{Any}(nothing)
        with_live_socket(
            f;
            setup = wsr -> on_close!((code, reason) -> (got[] = (code, reason)), wsr),
        ) do route, _
            ws_close_frame(f, route, "closePage"; code = 4002, reason = "page went")
            ws_until(() -> got[] !== nothing)
            @test got[] == (4002, "page went")
        end
        close(f.conn)
    end

    @testset "an unhandled close closes the other side" begin
        f = har_fixture()
        with_live_socket(f; setup = connect!) do route, _
            ws_close_frame(f, route, "closePage"; code = 1000, reason = "bye")
            ws_until(() -> !isempty(ws_sent(f, "closeServer")))
            params = only(ws_sent(f, "closeServer"))["params"]
            @test params["code"] == 1000
            @test params["reason"] == "bye"
        end
        close(f.conn)
    end

    @testset "the route's subscriptions are gone once it closes" begin
        # R3, as a test failure rather than a memory profile. The route object
        # is short-lived and its subscriptions belong to it, so a table that
        # keeps them grows one entry per socket for the life of the process —
        # invisible in a suite, obvious in a long-running scrape.
        f = har_fixture()
        with_live_socket(f; setup = wsr -> on_close!((_, _) -> nothing, wsr)) do route, _
            @test haskey(f.conn.subscriptions, route.guid)
            @test haskey(Playwright.WS_ROUTE_STATE, route.guid)

            ws_close_frame(f, route, "closePage")
            ws_until(() -> !haskey(Playwright.WS_ROUTE_STATE, route.guid))
            @test !haskey(f.conn.subscriptions, route.guid)
        end
        close(f.conn)
    end

    @testset "disposing the route drops its state too" begin
        # The other way a socket ends: the page navigates away and the driver
        # disposes the route without closing it first.
        f = har_fixture()
        setup = wsr -> on_message_from_page!(_ -> nothing, wsr)
        with_live_socket(f; setup = setup) do route, _
            @test haskey(Playwright.WS_ROUTE_STATE, route.guid)
            send_dispose(f.fake, route.guid)
            ws_until(() -> !haskey(Playwright.WS_ROUTE_STATE, route.guid))
            @test !haskey(f.conn.subscriptions, route.guid)
            @test !(route.guid in Playwright.CONNECTED_WS_ROUTES)
        end
        close(f.conn)
    end

    @testset "unrouting drops a live socket's state" begin
        # The third way: the *registration* goes while the socket is still up.
        f = har_fixture()
        armed = Ref(false)
        reg = route_web_socket!(f.context, "**/ws") do wsr
            on_message_from_page!(_ -> nothing, wsr)
            armed[] = true
        end
        route = fire_web_socket_route(f)
        ws_until(() -> armed[])
        @test haskey(Playwright.WS_ROUTE_STATE, route.guid)

        unroute_web_socket!(f.context, reg)
        @test !haskey(Playwright.WS_ROUTE_STATE, route.guid)
        @test !haskey(f.conn.subscriptions, route.guid)

        close(f.conn)
    end

    @testset "a callback that throws is collected and rethrown" begin
        f = har_fixture()
        armed = Ref(false)
        reg = route_web_socket!(f.context, "**/ws") do wsr
            on_message_from_page!(_ -> error("callback boom"), wsr)
            armed[] = true
        end
        route = fire_web_socket_route(f)
        ws_until(() -> armed[])

        ws_frame(f, route, "messageFromPage", "ping")
        ws_until(() -> !isempty(reg.exceptions))
        # Same contract as a handler's: there is no user task to raise into, so
        # it waits for unregistration.
        @test_throws ErrorException unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "callbacks never run on the transport reader task" begin
        f = har_fixture()
        ran_on = Ref{Any}(nothing)
        registry = Ref{Any}(nothing)
        with_live_socket(
            f;
            setup = wsr -> on_message_from_page!(_ -> (ran_on[] = current_task()), wsr),
        ) do route, _
            registry[] = Playwright.ws_registry_for(f.context)
            ws_frame(f, route, "messageFromPage", "ping")
            ws_until(() -> ran_on[] !== nothing)
            # The same task the handler ran on: one dispatcher per owner, not
            # one per socket, and never the reader.
            @test ran_on[] === registry[].task
            @test ran_on[] !== f.conn.transport.reader
        end
        close(f.conn)
    end
end
