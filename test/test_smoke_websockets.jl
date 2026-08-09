# WebSocket routing against real browsers, both engines. Gated behind
# PLAYWRIGHT_JL_SMOKE=1.
#
# The server here is its own, not test_smoke.jl's: proving that mock mode never
# contacts the real server can only be done server-side, by a server
# that counts the connections it accepted. A client-side assertion cannot tell
# "the server was never asked" from "the server answered and we ignored it".
#
# Runs after test_smoke_network.jl, whose within_deadline and with_browser this
# file reuses.

using HTTP
using Sockets

"""
A fixture server that also speaks WebSocket at `/ws`, and counts connections.

`connections` is the only way to assert that a mock-mode route leaves it
at zero. `echo` makes proxy mode observable: the server prefixes what it is
sent, so a message the page receives unprefixed did not come from the server.
"""
function with_websocket_server(f::Function)
    dir = joinpath(@__DIR__, "fixtures")
    connections = Threads.Atomic{Int}(0)

    server = HTTP.listen!("127.0.0.1", 0; listenany = true) do http
        if HTTP.WebSockets.isupgrade(http.message)
            HTTP.WebSockets.upgrade(http) do ws
                Threads.atomic_add!(connections, 1)
                try
                    for msg in ws
                        HTTP.WebSockets.send(ws, "from-server:" * String(msg))
                    end
                catch
                    # A socket closed under us is the normal end of a test, not
                    # a failure — the assertions are on the page and on the
                    # connection count, both of which survive it.
                end
            end
            return
        end

        target = split(http.message.target, '?')[1]
        path = target == "/" ? "/index.html" : target
        file = normpath(joinpath(dir, lstrip(path, '/')))
        found = startswith(file, dir) && isfile(file)
        HTTP.setstatus(http, found ? 200 : 404)
        HTTP.setheader(http, "Content-Type" => "text/html")
        HTTP.startwrite(http)
        found && write(http, read(file))
    end

    port = HTTP.port(server)
    try
        f("http://127.0.0.1:$port", connections)
    finally
        close(server)
    end
end

"What the page has recorded receiving, in order."
ws_received(page) =
    [text_content(item) for item in locator(page, "#received li"; strict = false)]

"""
Open `websocket.html` with `route` armed on the context, run `body(page)`, and tear the
browser down afterwards.

The route is registered **before** the navigation: a pattern armed after the
page has opened its socket is a pattern that intercepts nothing, and the failure
looks like a routing bug rather than an ordering one.
"""
function with_routed_socket(body, bt, base_url, handler; label = "ws")
    return within_deadline(label, 120.0) do
        with_browser(bt) do browser
            ctx = new_context(browser)
            page = new_page(ctx)
            with_web_socket_route(ctx, "**/ws", handler) do
                goto!(page, "$base_url/websocket.html")
                click!(locator(page, "#open"))
                expect(locator(page, "#status"); to_have_text = "open")
                body(page)
            end
        end
    end
end

@testset "smoke: WebSocket routing" begin
    with_websocket_server() do base_url, connections
        playwright() do pw
            for engine in ("chromium", "firefox")
                bt = getfield(pw, Symbol(engine))

                @testset "$engine: a context-armed pattern delivers on the context" begin
                    # Delivery scope has to be established first: if
                    # webSocketRoute came back page-scoped for a context-armed
                    # pattern, the registry
                    # would need a filtering step — a design change, to be
                    # caught before the registry was written rather than after.
                    #
                    # Asserted on the wire rather than through the wrapper,
                    # rather than through the wrapper. That is the point:
                    # the assertion is about the driver's addressing, not about
                    # our code.
                    observed = within_deadline("$engine ws addressing", 120.0) do
                        with_browser(bt) do browser
                            ctx = new_context(browser)
                            page = new_page(ctx)

                            seen = Vector{Any}()
                            original = pw.connection.transport.on_message
                            pw.connection.transport.on_message =
                                msg -> (push!(seen, msg); original(msg))
                            try
                                Playwright._browser_context_set_web_socket_interception_patterns(
                                    ctx;
                                    patterns = [Dict{String,Any}("glob" => "**/ws")],
                                )
                                before = connections[]
                                goto!(page, "$base_url/websocket.html")
                                click!(locator(page, "#open"))

                                arrived =
                                    timedwait(30.0) do
                                        any(
                                            m ->
                                                get(m, "method", "") == "webSocketRoute",
                                            seen,
                                        )
                                    end === :ok

                                routes = filter(
                                    m -> get(m, "method", "") == "webSocketRoute",
                                    seen,
                                )
                                (
                                    arrived = arrived,
                                    guids = [m["guid"] for m in routes],
                                    context_guid = ctx.guid,
                                    page_guid = page.guid,
                                    new_connections = connections[] - before,
                                )
                            finally
                                pw.connection.transport.on_message = original
                            end
                        end
                    end

                    @test observed.arrived
                    @test length(observed.guids) == 1
                    # The answer: on the context, symmetric with route!.
                    @test observed.guids[1] == observed.context_guid
                    @test observed.guids[1] != observed.page_guid

                    # ...and with a pattern armed and nobody connecting, the real
                    # nothing reaches the real server. This is the mechanism the
                    # mock-mode assertions rest on.
                    @test observed.new_connections == 0
                end

                @testset "$engine: mock mode never contacts the server" begin
                    # Asserted server-side, which is the only place it can be
                    # asserted: a client-side check cannot tell "the server was
                    # never asked" from "it answered and we ignored it".
                    before = connections[]
                    received = with_routed_socket(
                        bt,
                        base_url,
                        wsr -> on_message_from_page!(wsr) do msg
                            msg == "ping" && send_to_page!(wsr, "mocked:pong")
                        end;
                        label = "$engine ws mock",
                    ) do page
                        click!(locator(page, "#send"))
                        expect(locator(page, "#received"); to_contain_text = "mocked:pong")
                        ws_received(page)
                    end

                    @test received == ["mocked:pong"]
                    # The socket opened, the page was answered, and the real
                    # server heard nothing at all.
                    @test connections[] == before
                end

                @testset "$engine: proxy mode rewrites a server message" begin
                    before = connections[]
                    received = with_routed_socket(
                        bt,
                        base_url,
                        function (wsr)
                            connect!(wsr)
                            # No on_message_from_page!, so the page's frame is
                            # forwarded by the default — this test needs the
                            # server to actually answer.
                            on_message_from_server!(wsr) do msg
                                send_to_page!(wsr, replace(msg, "from-server" => "rewritten"))
                            end
                        end;
                        label = "$engine ws proxy",
                    ) do page
                        click!(locator(page, "#send"))
                        expect(
                            locator(page, "#received");
                            to_contain_text = "rewritten:ping",
                        )
                        ws_received(page)
                    end

                    @test received == ["rewritten:ping"]
                    # The rewrite is only a rewrite if the original came from
                    # somewhere: proxy mode did reach the server.
                    @test connections[] == before + 1
                end

                @testset "$engine: a binary frame survives each way" begin
                    seen = Ref{Any}(nothing)
                    bytes = with_routed_socket(
                        bt,
                        base_url,
                        wsr -> on_message_from_page!(wsr) do msg
                            seen[] = msg
                            # Reversed so the assertion cannot pass on a frame
                            # that was echoed by something other than us.
                            msg isa Vector{UInt8} && send_to_page!(wsr, reverse(msg))
                        end;
                        label = "$engine ws binary",
                    ) do page
                        click!(locator(page, "#send-binary"))
                        expect(locator(page, "#binary"); to_have_text = "4,3,2,1")
                        text_content(locator(page, "#binary"))
                    end

                    @test bytes == "4,3,2,1"
                    # The caller named base64 nowhere: bytes in, bytes out.
                    @test seen[] isa Vector{UInt8}
                    @test seen[] == UInt8[1, 2, 3, 4]
                end

                @testset "$engine: close_ws! is what the page's onclose sees" begin
                    closed = with_routed_socket(
                        bt,
                        base_url,
                        wsr -> on_message_from_page!(
                            _ -> close_ws!(wsr; code = 4001, reason = "all done"),
                            wsr,
                        );
                        label = "$engine ws close",
                    ) do page
                        click!(locator(page, "#send"))
                        expect(
                            locator(page, "#closed");
                            to_have_text = "closed:4001:all done",
                        )
                        text_content(locator(page, "#closed"))
                    end

                    @test closed == "closed:4001:all done"
                end

                @testset "$engine: a handled server message is swallowed" begin
                    # the sharp edge, pinned as intended on real browsers as
                    # well as against the fake connection. The callback replaces
                    # the forwarding, so the echo never reaches the page — and
                    # the marker it sends instead is what makes that assertable
                    # rather than a race against a message that may yet arrive.
                    received = with_routed_socket(
                        bt,
                        base_url,
                        function (wsr)
                            connect!(wsr)
                            on_message_from_server!(
                                _ -> send_to_page!(wsr, "swallowed"),
                                wsr,
                            )
                        end;
                        label = "$engine ws swallow",
                    ) do page
                        click!(locator(page, "#send"))
                        expect(locator(page, "#received"); to_contain_text = "swallowed")
                        ws_received(page)
                    end

                    # Exactly one entry: the marker. The server's echo went
                    # nowhere, which is Playwright's behaviour and not a bug —
                    # if it ever changes upstream, this test is what tells us.
                    @test received == ["swallowed"]
                end
            end
        end
    end
end
