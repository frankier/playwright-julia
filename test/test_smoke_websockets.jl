# WebSocket routing against real browsers, both engines. Gated behind
# PLAYWRIGHT_JL_SMOKE=1.
#
# The server here is its own, not test_smoke.jl's: proving that mock mode never
# contacts the real server (SC 22) can only be done server-side, by a server
# that counts the connections it accepted. A client-side assertion cannot tell
# "the server was never asked" from "the server answered and we ignored it".
#
# Runs after test_smoke_network.jl, whose within_deadline and with_browser this
# file reuses.

using HTTP
using Sockets

"""
A fixture server that also speaks WebSocket at `/ws`, and counts connections.

`connections` is the only way to assert SC 22 — a mock-mode route must leave it
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

@testset "smoke: WebSocket routing" begin
    with_websocket_server() do base_url, connections
        playwright() do pw
            for engine in ("chromium", "firefox")
                bt = getfield(pw, Symbol(engine))

                @testset "$engine: a context-armed pattern delivers on the context (T17, OQ2)" begin
                    # The half the spec-phase probe left open, and the reason
                    # this is Part D's *first* task: if webSocketRoute came back
                    # page-scoped for a context-armed pattern, D11's registry
                    # would need a filtering step — a design change, to be
                    # caught before the registry was written rather than after.
                    #
                    # Asserted on the wire rather than through the wrapper,
                    # because at T17 there is no wrapper yet. That is the point:
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
                                goto!(page, "$base_url/m8.html")
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
                    # server is never contacted. This is the mechanism SC 22
                    # rests on, observed here before any of Part D exists.
                    @test observed.new_connections == 0
                end
            end
        end
    end
end
