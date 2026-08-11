# Route interception against real browsers. Gated behind PLAYWRIGHT_JL_SMOKE=1
# like the rest of the smoke suite, and run on both engines.
#
# routing failures hang rather than fail. A request nobody settles stops
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
# The server here is not test_smoke.jl's static one. `abort!` needs a route that
# counts hits, and `continue!` needs one that echoes the headers it received,
# and neither can be asserted from the client side alone.

using HTTP
using JSON
using Sockets

# Base.CoreLogging rather than `using Logging`: the stdlib would have to join
# Project.toml's test target, and assumption 9 says no new dependency. These
# are the same objects under a name that is always in scope.
const CoreLogging = Base.CoreLogging

using Playwright:
    APIResponse,
    fetch_uid,
    is_disposed,
    dispose!,
    raw_headers,
    headers_array,
    expect_request,
    expect_response,
    error_text,
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
`abort!` stopped one — and `/echo` reflects the request's headers back,
which is the only way to prove `continue!`'s rewrite reached the server rather
than merely being sent.
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
            for eng in SMOKE_ENGINES
                bt = engine(pw, eng)

                @testset "$eng: with_route fulfils with no server behind it" begin
                    seen = within_deadline("$eng with_route fulfils") do
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
                                goto!(page, "$base_url/network.html")
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

                @testset "$eng: page routes are page-scoped, context routes are not" begin
                    seen = within_deadline("$eng route scope") do
                        with_browser(bt) do browser
                            ctx = new_context(browser)
                            routed = new_page(ctx)
                            other = new_page(ctx)

                            page_scoped = with_route(
                                routed,
                                "**/api/todos",
                                route -> fulfill!(route; json = ["page-scoped"]),
                            ) do
                                goto!(routed, "$base_url/network.html")
                                click!(locator(routed, "#load"))
                                expect(locator(routed, "#status"); to_have_text = "loaded")

                                # The other page in the same context is untouched
                                # by a Page registration — it gets the server's
                                # answer, not the mock.
                                goto!(other, "$base_url/network.html")
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
                                    goto!(page, "$base_url/network.html")
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

                @testset "$eng: unmatched requests are continued, page loads" begin
                    seen = within_deadline("$eng unmatched continue") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))

                            # A *predicate* that never matches, deliberately —
                            # not a glob, which widens the driver's pattern union
                            # to `**/*` for a predicate, so every request on this
                            # page really is delivered to the client and really
                            # does reach the "nothing matched" path: the
                            # document, /missing.css, /missing.png and the API
                            # call alike. With a glob matcher the driver filters
                            # them out first and the auto-continue is never
                            # exercised — which is what proving this test by
                            # breaking the auto-continue revealed.
                            with_route(
                                ctx,
                                _url -> false,
                                route -> fulfill!(route; body = "unreachable"),
                            ) do
                                response = goto!(page, "$base_url/network.html")

                                # And a normal API call still reaches the server
                                # through the un-matching registration.
                                click!(locator(page, "#load"))
                                expect(locator(page, "#status"); to_have_text = "loaded")

                                (
                                    navigated = response !== nothing && ok(response),
                                    heading = text_content(locator(page, "h1")),
                                    todos = todo_texts(page),
                                )
                            end
                        end
                    end

                    @test seen.navigated
                    @test seen.heading == "Network"
                    @test seen.todos == ["from the server"]
                end

                @testset "$eng: a throwing handler surfaces out of with_route" begin
                    seen = within_deadline("$eng throwing handler") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            thrown = nothing
                            try
                                with_route(
                                    ctx,
                                    "**/api/todos",
                                    route -> error("the handler is broken"),
                                ) do
                                    click!(locator(page, "#load"))
                                    # the route is continued despite the
                                    # throw, so the page still gets its answer.
                                    expect(
                                        locator(page, "#status");
                                        to_have_text = "loaded",
                                    )
                                end
                            catch e
                                thrown = e
                            end

                            (
                                thrown = thrown,
                                todos = todo_texts(page),
                                heading = text_content(locator(page, "h1")),
                            )
                        end
                    end

                    # The exception came out of the block that installed the
                    # handler, which is where a Julia user looks for it.
                    @test seen.thrown !== nothing
                    @test occursin("the handler is broken", sprint(showerror, seen.thrown))
                    # ...and the page underneath still completed.
                    @test seen.heading == "Network"
                    @test seen.todos == ["from the server"]
                end

                @testset "$eng: a handler that settles nothing warns once, no hang" begin
                    seen = within_deadline("$eng unsettled warns once") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            logger = Test.TestLogger(; min_level = CoreLogging.Warn)
                            todos = CoreLogging.with_logger(logger) do
                                with_route(ctx, "**/api/todos", route -> nothing) do
                                    # Two matching requests through one
                                    # registration: one warning total,
                                    # not one per request.
                                    click!(locator(page, "#load"))
                                    expect(
                                        locator(page, "#status");
                                        to_have_text = "loaded",
                                    )
                                    first_pass = todo_texts(page)

                                    click!(locator(page, "#load"))
                                    expect(
                                        locator(page, "#status");
                                        to_have_text = "loaded",
                                    )
                                    (first_pass, todo_texts(page))
                                end
                            end

                            unsettled = count(
                                r ->
                                    r.level == CoreLogging.Warn &&
                                        occursin("without settling", r.message),
                                logger.logs,
                            )
                            (todos = todos, warnings = unsettled)
                        end
                    end

                    # It did not hang — the route was continued for the handler
                    # — and the page got the server's real answer both times.
                    @test seen.todos[1] == ["from the server"]
                    @test seen.todos[2] == ["from the server"]
                    # Exactly one warning per registration, not per request.
                    @test seen.warnings == 1
                end

                @testset "$eng: expect_request returns the real request" begin
                    seen = within_deadline("$eng expect_request") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            got = expect_request(ctx, "**/api/todos") do
                                click!(locator(page, "#post"))
                            end

                            (
                                url = url(got),
                                method = method(got),
                                headers = headers(got),
                                body = post_data_string(got),
                                resource = resource_type(got),
                            )
                        end
                    end

                    @test endswith(seen.url, "/api/todos")
                    @test seen.method == "POST"
                    @test occursin(
                        "application/json",
                        get(seen.headers, "content-type", ""),
                    )
                    @test seen.body == "{\"title\":\"written by the page\"}"
                    @test seen.resource in ("fetch", "xhr")
                end

                @testset "$eng: expect_response reads status, headers and body" begin
                    seen = within_deadline("$eng expect_response") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            got = expect_response(ctx, "**/api/todos") do
                                click!(locator(page, "#load"))
                            end

                            # Read the body *before* navigating again. A
                            # response's body lives in the browser and is
                            # discarded on navigation — asking afterwards gets
                            # "No resource with given identifier found", which
                            # is what the first draft of this test did.
                            first_seen = (
                                status = status(got),
                                ok = ok(got),
                                content_type = get(headers(got), "content-type", ""),
                                json = json(got),
                                text = text(got),
                            )

                            # A non-200 as well, so `ok` is proved false
                            # somewhere and not merely true everywhere.
                            missing_one = expect_response(ctx, "**/missing.png") do
                                goto!(page, "$base_url/network.html")
                            end

                            (
                                first_seen...,
                                missing_status = status(missing_one),
                                missing_ok = ok(missing_one),
                            )
                        end
                    end

                    @test seen.status == 200
                    @test seen.ok
                    @test occursin("application/json", seen.content_type)
                    @test seen.json == ["from the server"]
                    @test occursin("from the server", seen.text)
                    @test seen.missing_status == 404
                    @test seen.missing_ok == false
                end

                @testset "$eng: :requestfailed fires with the eng's text" begin
                    seen = within_deadline("$eng requestfailed") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            failure = expect_event(ctx, :requestfailed) do
                                # Abort is a failure from the page's point of
                                # view, which is the point of aborting — and it
                                # is the deterministic way to produce one.
                                with_route(
                                    ctx,
                                    "**/api/hits",
                                    route -> abort!(
                                        route;
                                        error_code = "connectionrefused",
                                    ),
                                ) do
                                    click!(locator(page, "#hit"))
                                    expect(locator(page, "#status"); to_have_text = "error")
                                end
                            end

                            (failed_url = url(request(failure)), text = error_text(failure))
                        end
                    end

                    @test endswith(seen.failed_url, "/api/hits")
                    # Chromium says net::ERR_…, Firefox says NS_ERROR_… — the
                    # engines do not agree on the spelling, so assert only that
                    # there is one.
                    @test !isempty(seen.text)
                end

                @testset "$eng: page-scoped events see only their page" begin
                    seen = within_deadline("$eng page-scoped events") do
                        with_browser(bt) do browser
                            ctx = new_context(browser)
                            watched = new_page(ctx)
                            noisy = new_page(ctx)
                            goto!(watched, "$base_url/network.html")
                            goto!(noisy, "$base_url/network.html")

                            # Both pages call the same URL inside the block. The
                            # page-scoped subscription must return the watched
                            # page's request, never the other one's — the
                            # filter is the whole of this test.
                            got = expect_request(watched, "**/api/todos") do
                                click!(locator(noisy, "#load"))
                                expect(locator(noisy, "#status"); to_have_text = "loaded")
                                click!(locator(watched, "#load"))
                            end

                            # The frame that issued it belongs to the watched
                            # page, which is the check that cannot pass by luck.
                            (
                                same_page = frame(got) === Playwright.main_frame(watched),
                                url = url(got),
                            )
                        end
                    end

                    @test seen.same_page
                    @test endswith(seen.url, "/api/todos")
                end

                @testset "$eng: the four network events are no longer deferred" begin
                    seen = within_deadline("$eng events not deferred") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            # expect_event(ctx, :request) used to raise
                            # ArgumentError("deferred"). It returns a Request now.
                            req = expect_event(ctx, :request) do
                                click!(locator(page, "#load"))
                            end
                            finished = expect_event(ctx, :requestfinished) do
                                click!(locator(page, "#load"))
                            end
                            (req = req, finished = finished)
                        end
                    end

                    @test seen.req isa Playwright.Request
                    @test seen.finished isa Playwright.Request
                end

                @testset "$eng: fulfil from a real upstream response" begin
                    seen = within_deadline("$eng fulfil from upstream") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            upstream_status = Ref(0)
                            upstream_body = Ref("")

                            # Intercept, forward, modify — the whole reason
                            # APIRequestContext ships at all.
                            with_route(
                                ctx,
                                "**/api/todos",
                                function (route)
                                    upstream = Playwright.fetch(route)
                                    upstream_status[] = status(upstream)
                                    upstream_body[] = text(upstream)
                                    fulfill!(route; response = upstream, status = 500)
                                end,
                            ) do
                                click!(locator(page, "#load"))
                                # The page's fetch resolves (500 is a response,
                                # not a failure), and its handler renders the
                                # upstream body.
                                expect(locator(page, "#status"); to_have_text = "loaded")
                            end

                            (
                                upstream_status = upstream_status[],
                                upstream_body = upstream_body[],
                                rendered = todo_texts(page),
                            )
                        end
                    end

                    # The fetch really went to the server and got the real answer...
                    @test seen.upstream_status == 200
                    @test occursin("from the server", seen.upstream_body)
                    # ...and the page received that body, under a forced status.
                    @test seen.rendered == ["from the server"]
                end

                @testset "$eng: an APIResponse is disposed after its handler" begin
                    seen = within_deadline("$eng APIResponse disposal") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            captured = Ref{Any}(nothing)
                            with_route(
                                ctx,
                                "**/api/todos",
                                function (route)
                                    upstream = Playwright.fetch(route)
                                    captured[] = upstream
                                    # Disposed *after* this returns, so reading the
                                    # body here is still fine.
                                    fulfill!(route; response = upstream)
                                end,
                            ) do
                                click!(locator(page, "#load"))
                                expect(locator(page, "#status"); to_have_text = "loaded")
                            end

                            handler_response = captured[]

                            # A response fetched *outside* a handler is not
                            # disposed for you — it is the finalization case, and
                            # dispose! is the explicit one.
                            standalone = Playwright.fetch(ctx, "$base_url/api/todos")
                            standalone_before = is_disposed(standalone)
                            dispose!(standalone)

                            (
                                handler_disposed = is_disposed(handler_response),
                                handler_uid = fetch_uid(handler_response),
                                standalone_before = standalone_before,
                                standalone_after = is_disposed(standalone),
                                # Asserted, not assumed: the driver really was
                                # told, so the body is gone rather than merely
                                # unreferenced.
                                body_after_dispose = try
                                    body(handler_response)
                                    "no error"
                                catch e
                                    "raised"
                                end,
                            )
                        end
                    end

                    @test seen.handler_disposed
                    @test !isempty(seen.handler_uid)
                    @test seen.standalone_before == false
                    @test seen.standalone_after == true
                    @test seen.body_after_dispose == "raised"
                end

                @testset "$eng: raw_headers differs from headers" begin
                    seen = within_deadline("$eng raw_headers") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            got = expect_request(ctx, "**/api/todos") do
                                click!(locator(page, "#load"))
                            end

                            (
                                plain = headers(got),
                                raw = Dict(
                                    lowercase(k) => v for (k, v) in raw_headers(got)
                                ),
                            )
                        end
                    end

                    # raw_headers returns what the browser really sent, which
                    # includes headers the page never set — `user-agent` is the
                    # one both engines add.
                    #
                    # The engines disagree on how much of that the *initializer*
                    # already carries: on Chromium raw is strictly larger than
                    # `headers`, on Firefox the two match. So the assertion is
                    # the one that holds on both — raw contains everything
                    # `headers` does, plus the browser's own — rather than a
                    # strict inequality that would be a Chromium-only fact
                    # dressed up as a general one.
                    @test haskey(seen.raw, "user-agent")
                    @test length(seen.raw) >= length(seen.plain)
                    for (k, v) in seen.plain
                        @test haskey(seen.raw, k)
                    end
                end

                @testset "$eng: overlapping registrations resolve newest-first" begin
                    seen = within_deadline("$eng overlapping registrations") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")

                            older = route!(
                                ctx,
                                "**/api/todos",
                                route -> fulfill!(route; json = ["older"]),
                            )
                            newer = route!(
                                ctx,
                                "**/api/todos",
                                route -> fulfill!(route; json = ["newer"]),
                            )

                            click!(locator(page, "#load"))
                            expect(locator(page, "#status"); to_have_text = "loaded")
                            with_newer = todo_texts(page)

                            # Unrouting the newer one hands the URL back to the
                            # older, in the same test — registrations are a
                            # stack, not a set.
                            unroute!(ctx, newer)
                            click!(locator(page, "#load"))
                            expect(locator(page, "#status"); to_have_text = "loaded")
                            with_older = todo_texts(page)

                            unroute_all!(ctx)
                            click!(locator(page, "#load"))
                            expect(locator(page, "#status"); to_have_text = "loaded")
                            with_none = todo_texts(page)

                            (newer = with_newer, older = with_older, none = with_none)
                        end
                    end

                    @test seen.newer == ["newer"]
                    @test seen.older == ["older"]
                    # ...and with everything unrouted the server answers again.
                    @test seen.none == ["from the server"]
                end

                @testset "$eng: abort! stops the request reaching the server" begin
                    seen = within_deadline("$eng abort!") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")
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

                @testset "$eng: continue! reaches the server modified" begin
                    seen = within_deadline("$eng continue! rewrite") do
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            goto!(page, "$base_url/network.html")
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
