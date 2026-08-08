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
    WebSocketRoute, route_web_socket!, unroute_web_socket!, with_web_socket_route

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

"Wait for `cond`, failing rather than hanging. Never a bare sleep."
function ws_until(cond, seconds = 10.0)
    timedwait(cond, seconds) === :ok || error("condition never held within $(seconds)s")
    return true
end

@testset "WebSocket routing (M8 Part D)" begin
    @testset "registering arms the driver's patterns (T18, D11)" begin
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

    @testset "the dispatcher spawns on the first registration, not before (T18)" begin
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

    @testset "the handler gets the route the driver announced (T18)" begin
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

    @testset "handlers never run on the transport reader task (T18, SC 21)" begin
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

    @testset "handlers run sequentially, never concurrently (T18, D11)" begin
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

    @testset "the newest matching registration wins (T18, D11)" begin
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

    @testset "a handler that throws is collected and rethrown (T18, D11)" begin
        f = har_fixture()
        reg = route_web_socket!(_ -> error("handler boom"), f.context, "**/ws")

        fire_web_socket_route(f)
        ws_until(() -> !isempty(reg.exceptions))

        # Not raised where it happened — there is no user task there — so it is
        # rethrown at unregistration, exactly as route!'s are.
        @test_throws ErrorException unroute_web_socket!(f.context, reg)
        close(f.conn)
    end

    @testset "a throwing handler does not kill the dispatcher (T18)" begin
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

    @testset "several exceptions become a CompositeException (T18)" begin
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

    @testset "unroute_web_socket! is idempotent, and clears all (T18)" begin
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

    @testset "with_web_socket_route unregisters even when the body throws (T18)" begin
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

    @testset "a Page target arms the page's own channel (T18, D11)" begin
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

    @testset "a handler that registers nothing is legal (T18, D11)" begin
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

    @testset "the socket is opened once the handler has set it up (T18)" begin
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
end
