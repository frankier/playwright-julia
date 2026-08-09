# HAR record → replay against real browsers, both engines. Gated behind
# PLAYWRIGHT_JL_SMOKE=1.
#
# This is the only test that proves both halves of the HAR feature at once, and
# the shape of it matters: **the server is stopped between recording and
# replay**. A replay test against a server that is still running proves nothing
# — every request could be reaching the real backend and the archive could be
# empty. So the server going down is part of the test, and that it is really
# down is asserted rather than assumed.
#
# The division of labour: replay is already known-good against the hand-written
# fixture (test_har.jl), so a failure here is a *recording* failure by
# elimination.
#
# Runs after test_smoke_network.jl, whose with_browser, within_deadline and
# todo_texts helpers this file reuses.

using HTTP
using JSON
using Sockets

using Playwright:
    route_from_har, with_har, start_har_recording!, stop_har_recording!, with_har_recording

"""
A fixture server whose `/api/todos` body can be changed between runs.

`body` is a Ref the test writes to, which is what makes the refresh test possible: `update =
true` is only meaningful against a backend that has moved on since the archive
was recorded.
"""
function with_har_server(f::Function)
    dir = joinpath(@__DIR__, "fixtures")
    body = Ref(["recorded one", "recorded two"])
    hits = Threads.Atomic{Int}(0)

    server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
        Threads.atomic_add!(hits, 1)
        target = split(req.target, '?')[1]
        if target == "/api/todos"
            return HTTP.Response(200, ["Content-Type" => "application/json"], JSON.json(body[]))
        end
        path = target == "/" ? "/index.html" : target
        file = normpath(joinpath(dir, lstrip(path, '/')))
        if startswith(file, dir) && isfile(file)
            return HTTP.Response(200, ["Content-Type" => "text/html"], read(file))
        end
        return HTTP.Response(404, "not found")
    end

    port = HTTP.port(server)
    base_url = "http://127.0.0.1:$port"
    try
        f(base_url, body, hits, () -> close(server))
    finally
        close(server)
    end
end

"Whether anything is still answering at `base_url`. The replay tests need `false`."
function server_is_up(base_url; seconds = 5.0)
    deadline = time() + seconds
    while time() < deadline
        try
            HTTP.get(
                "$base_url/api/todos";
                retry = false,
                readtimeout = 2,
                status_exception = false,
            )
            return true
        catch
            return false
        end
    end
    return false
end

@testset "smoke: HAR round trip" begin
    playwright() do pw
        for engine in SMOKE_ENGINES
            bt = getfield(pw, Symbol(engine))

            @testset "$engine: record, stop the server, replay" begin
                workdir = mktempdir()
                archive = joinpath(workdir, "roundtrip.har")

                # --- Phase 1: record, with the server up ---------------------
                #
                # No url filter: the document itself has to be in the archive or
                # there is nothing to navigate to in phase 2. The filtered case
                # is the `url`-filter test below, and it is separate on purpose.
                recorded, base_url = within_deadline("$engine record") do
                    with_har_server() do url, _body, _hits, stop_server
                        texts = with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            with_har_recording(ctx; path = archive) do
                                goto!(page, "$url/network.html")
                                click!(locator(page, "#load"))
                                expect(locator(page, "#status"); to_have_text = "loaded")
                            end
                            todo_texts(page)
                        end
                        stop_server()
                        (texts, url)
                    end
                end

                @test recorded == ["recorded one", "recorded two"]
                @test isfile(archive)
                @test filesize(archive) > 0

                # --- The server is really gone -------------------------------
                #
                # Asserted, not assumed. If this ever came back true the replay
                # below would be testing the live backend and would pass for the
                # wrong reason.
                @test !server_is_up(base_url)

                # --- Phase 2: replay, with nothing behind it -----------------
                replayed = within_deadline("$engine replay") do
                    with_browser(bt) do browser
                        page = new_page(browser)
                        ctx = first(contexts(browser))
                        with_har(ctx, archive) do
                            goto!(page, "$base_url/network.html")
                            click!(locator(page, "#load"))
                            expect(locator(page, "#status"); to_have_text = "loaded")
                            todo_texts(page)
                        end
                    end
                end

                @test replayed == recorded
            end

            @testset "$engine: a url filter leaves the document out" begin
                # This asserts the *absence* of something from the archive,
                # which cannot be read off the file without parsing HAR — and
                # this package does not parse HAR. So it is asserted the way a
                # user would notice it: replay with :abort, and the document
                # request fails because it was never recorded.
                workdir = mktempdir()
                archive = joinpath(workdir, "api-only.har")

                base_url = within_deadline("$engine record filtered") do
                    with_har_server() do url, _body, _hits, stop_server
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            with_har_recording(ctx; path = archive, url = "**/api/**") do
                                goto!(page, "$url/network.html")
                                click!(locator(page, "#load"))
                                expect(locator(page, "#status"); to_have_text = "loaded")
                            end
                        end
                        stop_server()
                        url
                    end
                end

                @test isfile(archive)
                @test !server_is_up(base_url)

                # The document is not in the archive, so navigating fails under
                # the :abort default.
                navigation_failed = within_deadline("$engine replay filtered") do
                    with_browser(bt) do browser
                        page = new_page(browser)
                        ctx = first(contexts(browser))
                        with_har(ctx, archive; not_found = :abort) do
                            try
                                goto!(page, "$base_url/network.html")
                                false
                            catch
                                true
                            end
                        end
                    end
                end
                @test navigation_failed
            end

            @testset "$engine: update = true refreshes a stale archive" begin
                # The leg that closes the loop. Unlike every other replay test
                # this one needs a backend to record *from*, which is why it
                # does not share a fixture with them.
                #
                # Three phases: record against the server, change the server's
                # answer, refresh the archive with update = true — then stop the
                # server and prove the refreshed archive serves the *new* body.
                workdir = mktempdir()
                archive = joinpath(workdir, "stale.har")

                base_url = within_deadline("$engine update", 180.0) do
                    with_har_server() do url, body, _hits, stop_server
                        # Phase 1: the archive as originally recorded.
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            with_har_recording(ctx; path = archive) do
                                goto!(page, "$url/network.html")
                                click!(locator(page, "#load"))
                                expect(locator(page, "#status"); to_have_text = "loaded")
                            end
                        end

                        # Phase 2: the backend moves on.
                        body[] = ["updated one", "updated two"]

                        # Phase 3: refresh. route_from_har's name says "route"
                        # and its behaviour here is "record".
                        with_browser(bt) do browser
                            page = new_page(browser)
                            ctx = first(contexts(browser))
                            with_har(ctx, archive; update = true) do
                                goto!(page, "$url/network.html")
                                click!(locator(page, "#load"))
                                expect(locator(page, "#status"); to_have_text = "loaded")
                            end
                        end

                        stop_server()
                        url
                    end
                end

                @test !server_is_up(base_url)

                # Phase 4: replay the refreshed archive with nothing behind it.
                # The new body is the assertion — the old one would mean update
                # had quietly done nothing, which is the failure the refusal
                # existed to prevent in the first place.
                replayed = within_deadline("$engine update replay") do
                    with_browser(bt) do browser
                        page = new_page(browser)
                        ctx = first(contexts(browser))
                        with_har(ctx, archive) do
                            goto!(page, "$base_url/network.html")
                            click!(locator(page, "#load"))
                            expect(locator(page, "#status"); to_have_text = "loaded")
                            todo_texts(page)
                        end
                    end
                end

                @test replayed == ["updated one", "updated two"]
            end
        end
    end
end
