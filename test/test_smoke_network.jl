# Route interception against real browsers. Gated behind PLAYWRIGHT_JL_SMOKE=1
# like the rest of the smoke suite, and run on both engines.
#
# R3: routing failures hang rather than fail. A request nobody settles stops
# dead and surfaces as an unrelated 30-second timeout, which in CI costs ten
# minutes and produces no diagnostic. **Every browser interaction here runs
# under an explicit deadline**, so a hang becomes a named failure inside a
# minute.
#
# The shape to notice: `within_deadline` runs the browser work and *returns
# what it observed*; the `@test`s run outside it, on the test's own task. That
# is not a style choice. `@testset` state is task-local, so a `@test` inside a
# spawned task is not recorded by the enclosing testset — it neither counts nor
# reports, and a whole file of them can pass silently while proving nothing.
# This file did exactly that before it was restructured.
#
# The server here is not test_smoke.jl's static one: SC 7 needs a route that
# counts hits and SC 8 needs one that echoes the headers it really received,
# and neither can be asserted from the client side alone.

using HTTP
using JSON
using Sockets

using Playwright:
    route!,
    unroute!,
    unroute_all!,
    with_route,
    abort!,
    continue!,
    fulfill!,
    request,
    resource_type,
    headers,
    post_data_string,
    status,
    ok,
    method

"""
Run `body` under a deadline and return its value, failing with a message
instead of hanging (R3).

A routing bug's natural symptom is silence, and silence is indistinguishable
from slowness until something says otherwise. This is the something.

Assertions belong *outside* this call — see the note at the top of the file.
"""
function within_deadline(body, label, seconds = 90.0)
    outcome = Ref{Any}(nothing)
    failure = Ref{Any}(nothing)
    task = @async try
        outcome[] = body()
    catch e
        failure[] = e
    end
    if timedwait(() -> istaskdone(task), seconds) !== :ok
        error(
            "$label did not finish within $(seconds)s — a route was probably never settled",
        )
    end
    failure[] === nothing || throw(failure[])
    return outcome[]
end

"""
A fixture server with behaviour, not just files.

`hits` counts requests that actually reached it — the only way to prove
`abort!` stopped one (SC 7) — and `/echo` reflects the request's headers back,
which is the only way to prove `continue!`'s rewrite reached the server rather
than merely being sent (SC 8).
"""
function with_network_server(f::Function)
    dir = joinpath(@__DIR__, "fixtures")
    hits = Threads.Atomic{Int}(0)
    seen_headers = Ref{Dict{String,String}}(Dict{String,String}())

    server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
        target = split(req.target, '?')[1]
        if target == "/api/todos"
            Threads.atomic_add!(hits, 1)
            if req.method == "POST"
                return HTTP.Response(
                    201,
                    ["Content-Type" => "application/json"],
                    JSON.json(Dict("created" => true)),
                )
            end
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                JSON.json(["from the server"]),
            )
        elseif target == "/api/hits"
            Threads.atomic_add!(hits, 1)
            return HTTP.Response(200, ["Content-Type" => "text/plain"], string(hits[]))
        elseif target == "/echo"
            Threads.atomic_add!(hits, 1)
            seen_headers[] = Dict(lowercase(k) => v for (k, v) in req.headers)
            return HTTP.Response(
                200,
                ["Content-Type" => "application/json"],
                JSON.json(seen_headers[]),
            )
        end

        path = target == "/" ? "/index.html" : target
        file = normpath(joinpath(dir, lstrip(path, '/')))
        if startswith(file, dir) && isfile(file)
            return HTTP.Response(200, ["Content-Type" => "text/html"], read(file))
        end
        return HTTP.Response(404, "not found")
    end

    port = HTTP.port(server)
    try
        f("http://127.0.0.1:$port", hits, seen_headers)
    finally
        close(server)
    end
end

"Launch, run `body(browser)`, and always close the browser."
function with_browser(body, bt)
    browser = launch(bt; headless = true)
    try
        return body(browser)
    finally
        close!(browser)
    end
end

"The rendered todo list, as strings."
todo_texts(page) =
    [text_content(item) for item in locator(page, "#todos li"; strict = false)]

@testset "smoke: network" begin
    with_network_server() do base_url, hits, seen_headers
        playwright() do pw
            for engine in ("chromium", "firefox")
                bt = getfield(pw, Symbol(engine))

                @testset "$engine: with_route fulfils with no server behind it (SC 1)" begin
                    seen = within_deadline("$engine SC 1") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            before = hits[]

                            with_route(
                                ctx,
                                "**/api/todos",
                                route -> fulfill!(
                                    route;
                                    json = ["mocked one", "mocked two"],
                                ),
                            ) do
                                goto!(page, "$base_url/m6.html")
                                click!(locator(page, "#load"))
                                expect(locator(page, "#status"); to_have_text = "loaded")
                            end

                            return (
                                todos = todo_texts(page),
                                before = before,
                                after = hits[],
                            )
                        end
                    end

                    # The page rendered data no server ever served...
                    @test seen.todos == ["mocked one", "mocked two"]
                    # ...and the server confirms it never saw the request.
                    @test seen.after == seen.before
                end

                @testset "$engine: page routes are page-scoped, context routes are not (SC 2)" begin
                    seen = within_deadline("$engine SC 2") do
                        with_browser(bt) do browser
                            ctx = new_context(browser)
                            routed = new_page(ctx)
                            other = new_page(ctx)

                            page_scoped = with_route(
                                routed,
                                "**/api/todos",
                                route -> fulfill!(route; json = ["page-scoped"]),
                            ) do
                                goto!(routed, "$base_url/m6.html")
                                click!(locator(routed, "#load"))
                                expect(locator(routed, "#status"); to_have_text = "loaded")

                                # The other page in the same context is untouched
                                # by a Page registration — it gets the server's
                                # answer, not the mock.
                                goto!(other, "$base_url/m6.html")
                                click!(locator(other, "#load"))
                                expect(locator(other, "#status"); to_have_text = "loaded")

                                (routed = todo_texts(routed), other = todo_texts(other))
                            end

                            # ...and a context registration reaches both pages.
                            both = with_route(
                                ctx,
                                "**/api/todos",
                                route -> fulfill!(route; json = ["context-scoped"]),
                            ) do
                                out = String[]
                                for page in (routed, other)
                                    goto!(page, "$base_url/m6.html")
                                    click!(locator(page, "#load"))
                                    expect(
                                        locator(page, "#status");
                                        to_have_text = "loaded",
                                    )
                                    append!(out, todo_texts(page))
                                end
                                out
                            end

                            return (page_scoped = page_scoped, both = both)
                        end
                    end

                    @test seen.page_scoped.routed == ["page-scoped"]
                    @test seen.page_scoped.other == ["from the server"]
                    @test seen.both == ["context-scoped", "context-scoped"]
                end

                @testset "$engine: abort! stops the request reaching the server (SC 7)" begin
                    seen = within_deadline("$engine SC 7") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/m6.html")
                            before = hits[]

                            with_route(ctx, "**/api/hits", route -> abort!(route)) do
                                click!(locator(page, "#hit"))
                                # The page's own error handler firing is what an
                                # abort looks like from inside the page.
                                expect(locator(page, "#status"); to_have_text = "error")
                            end

                            return (
                                failure = something(
                                    text_content(locator(page, "#failure")),
                                    "",
                                ),
                                before = before,
                                after = hits[],
                            )
                        end
                    end

                    @test occursin("failed", seen.failure)
                    # Counted server-side: zero hits, not merely "no error".
                    @test seen.after == seen.before
                end

                @testset "$engine: continue! reaches the server modified (SC 8)" begin
                    seen = within_deadline("$engine SC 8") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/m6.html")
                            seen_headers[] = Dict{String,String}()

                            with_route(
                                ctx,
                                "**/echo",
                                route -> continue!(
                                    route;
                                    headers = merge(
                                        headers(request(route)),
                                        Dict("x-m6-added" => "by the route"),
                                    ),
                                ),
                            ) do
                                click!(locator(page, "#echo"))
                                expect(locator(page, "#status"); to_have_text = r"^echo ")
                            end

                            return copy(seen_headers[])
                        end
                    end

                    # The *server* saw the added header. Asserting on the client's
                    # own rewrite would prove only that we sent what we sent.
                    @test get(seen, "x-m6-added", nothing) == "by the route"
                end
            end
        end
    end
end
