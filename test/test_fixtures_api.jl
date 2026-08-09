# with_page and report_diagnostics.
#
# Named test_fixtures_api.jl rather than test_fixtures.jl, which already exists
# and tests the HTML fixtures — a different thing entirely.
#
# The property under test throughout is the teardown rule: these run while a
# more important error is in flight, so they add evidence and never replace the
# failure they were called to explain.

using Playwright: with_page, report_diagnostics

"A TargetClosedError reply, as the real driver sends for a dead target."
closed_reply(fake, id) = driver_send(
    fake,
    Dict(
        "id" => id,
        "error" => Dict(
            "error" => Dict(
                "message" => "Target page, context or browser has been closed",
                "name" => "TargetClosedError",
                "stack" => "",
            ),
        ),
    ),
)

@testset "with_page argument validation" begin
    # All of this happens before a page is opened, so it needs no browser —
    # and a caller who typo'd a keyword finds out immediately rather than
    # after a browser launch.

    @testset "a typo'd artifacts_on is refused, listing the valid values" begin
        f = timeout_fixture()
        err = try
            with_page(identity, f.browser; artifacts = "/tmp/x", artifacts_on = :allways)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("artifacts_on", err.msg)
        @test occursin(":failure", err.msg)
        @test occursin(":always", err.msg)
        # The point of the closed set: `:allways` must not silently mean
        # "never dump anything".
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end

    @testset "artifacts_on without artifacts is refused" begin
        # It can only be a mistake about where the files were meant to go.
        f = timeout_fixture()
        err = try
            with_page(identity, f.browser; artifacts_on = :always)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("artifacts", err.msg)
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end

    @testset "the default artifacts_on needs no artifacts" begin
        # :failure is the default, so leaving both unset must not trip the
        # check above — it would make the plain fixture unusable. Asserted by
        # getting *past* validation: the fixture opens a context, which is the
        # first thing it does once the arguments are accepted.
        f = timeout_fixture()
        task = @async with_page(identity, f.browser)
        @test timedwait(() -> isready(f.fake.client_messages), 10.0) === :ok
        @test take!(f.fake.client_messages)["method"] == "newContext"
        # Unstick the task: there is no real browser to finish the handshake.
        close(f.fake.connection)
        @test try
            fetch(task)
            true
        catch e
            !(e isa ArgumentError) && !(e.task.result isa ArgumentError)
        end
    end
end

@testset "report_diagnostics" begin
    @testset "a dead target yields no files and no exception" begin
        # the shape, one level up: every reader fails, and the dump still
        # returns rather than throwing into a `finally` block.
        f = timeout_fixture()
        dir = mktempdir()

        responder = @async for _ = 1:3   # screenshot, console, page errors
            msg = take!(f.fake.client_messages)
            closed_reply(f.fake, msg["id"])
        end

        logs, files = Test.collect_test_logs() do
            report_diagnostics(f.page, dir)
        end

        @test files == String[]
        # No empty files left behind either.
        @test isempty(readdir(dir))
        # It failed *loudly enough to find*, just not by throwing.
        @test any(l -> l.level == Base.CoreLogging.Warn, logs)
        wait(responder)
        close(f.fake.connection)
    end

    @testset "it writes what it can and returns those paths" begin
        f = timeout_fixture()
        dir = mktempdir()

        responder = @async begin
            shot = take!(f.fake.client_messages)
            reply_ok(
                f.fake,
                shot["id"],
                Dict{String,Any}("binary" => base64encode(Vector{UInt8}("PNGDATA"))),
            )
            console = take!(f.fake.client_messages)
            reply_ok(
                f.fake,
                console["id"],
                Dict{String,Any}(
                    "messages" => [
                        Dict(
                            "type" => "log",
                            "text" => "hello there",
                            "location" => Dict(
                                "url" => "u",
                                "lineNumber" => 1,
                                "columnNumber" => 1,
                            ),
                            "timestamp" => 1.0,
                        ),
                    ],
                ),
            )
            errors = take!(f.fake.client_messages)
            reply_ok(
                f.fake,
                errors["id"],
                Dict{String,Any}(
                    "errors" => [
                        Dict(
                            "error" => Dict(
                                "message" => "boom",
                                "name" => "Error",
                                "stack" => "Error: boom",
                            ),
                        ),
                    ],
                ),
            )
        end

        files = report_diagnostics(f.page, dir)
        wait(responder)

        @test length(files) == 3
        @test all(isfile, files)
        @test read(joinpath(dir, "screenshot.png"), String) == "PNGDATA"
        @test occursin("hello there", read(joinpath(dir, "console.log"), String))
        @test occursin("boom", read(joinpath(dir, "errors.log"), String))
        close(f.fake.connection)
    end

    @testset "a partial dump is still a dump" begin
        # The screenshot fails, the buffers do not. Getting two files out of
        # three is the whole point of returning a list rather than a bool.
        f = timeout_fixture()
        dir = mktempdir()

        responder = @async begin
            shot = take!(f.fake.client_messages)
            closed_reply(f.fake, shot["id"])
            for _ = 1:2
                msg = take!(f.fake.client_messages)
                reply_ok(
                    f.fake,
                    msg["id"],
                    Dict{String,Any}(
                        "messages" => [
                            Dict(
                                "type" => "error",
                                "text" => "still here",
                                "location" => Dict(
                                    "url" => "u",
                                    "lineNumber" => 1,
                                    "columnNumber" => 1,
                                ),
                                "timestamp" => 1.0,
                            ),
                        ],
                        "errors" => [],
                    ),
                )
            end
        end

        logs, files = Test.collect_test_logs() do
            report_diagnostics(f.page, dir)
        end
        wait(responder)

        @test joinpath(dir, "screenshot.png") ∉ files
        @test joinpath(dir, "console.log") in files
        @test any(l -> l.level == Base.CoreLogging.Warn, logs)
        close(f.fake.connection)
    end

    @testset "nothing to report leaves no empty files" begin
        f = timeout_fixture()
        dir = mktempdir()

        responder = @async begin
            shot = take!(f.fake.client_messages)
            reply_ok(
                f.fake,
                shot["id"],
                Dict{String,Any}("binary" => base64encode(Vector{UInt8}("PNG"))),
            )
            for _ = 1:2
                msg = take!(f.fake.client_messages)
                reply_ok(
                    f.fake,
                    msg["id"],
                    Dict{String,Any}("messages" => [], "errors" => []),
                )
            end
        end

        files = report_diagnostics(f.page, dir)
        wait(responder)

        @test files == [joinpath(dir, "screenshot.png")]
        @test !isfile(joinpath(dir, "console.log"))
        @test !isfile(joinpath(dir, "errors.log"))
        close(f.fake.connection)
    end
end

# --- Smoke: real browsers, both engines -----------------------------------

if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
    @testset "with_page, live" begin
        with_fixture_server() do base_url
            playwright() do pw
                for engine in ("chromium", "firefox")
                    bt = getfield(pw, Symbol(engine))

                    @testset "$engine: a throwing body propagates and leaves evidence" begin
                        browser = launch(bt; headless = true)
                        dir = mktempdir()

                        err = try
                            with_page(
                                browser,
                                "$base_url/late-title.html";
                                artifacts = dir,
                            ) do page
                                expect(page; to_have_title = "Dashboard")
                                error("the assertion I actually care about")
                            end
                            nothing
                        catch e
                            e
                        end

                        # The original exception, unchanged in type and message.
                        @test err isa ErrorException
                        @test err.msg == "the assertion I actually care about"

                        # ...and all three files are there to explain it.
                        @test isfile(joinpath(dir, "screenshot.png"))
                        @test isfile(joinpath(dir, "console.log"))
                        @test isfile(joinpath(dir, "errors.log"))
                        @test filesize(joinpath(dir, "screenshot.png")) > 0
                        # The fixture's own console output and uncaught error.
                        @test occursin(
                            "late-title fixture",
                            read(joinpath(dir, "console.log"), String),
                        )
                        @test occursin(
                            "late-title fixture",
                            read(joinpath(dir, "errors.log"), String),
                        )

                        close!(browser)
                    end

                    @testset "$engine: a passing body writes nothing by default" begin
                        # "Wrote nothing" is as much a behaviour as "wrote
                        # something" — a screenshot per passing test is a lot
                        # of bytes for nothing on a large suite.
                        browser = launch(bt; headless = true)
                        dir = mktempdir()

                        result = with_page(
                            browser,
                            "$base_url/late-title.html";
                            artifacts = dir,
                        ) do page
                            expect(page; to_have_title = "Dashboard")
                            return :passed
                        end

                        @test result == :passed
                        @test isempty(readdir(dir))
                        close!(browser)
                    end

                    @testset "$engine: artifacts_on = :always dumps on success too" begin
                        browser = launch(bt; headless = true)
                        dir = mktempdir()

                        result = with_page(
                            browser,
                            "$base_url/late-title.html";
                            artifacts = dir,
                            artifacts_on = :always,
                        ) do page
                            expect(page; to_have_title = "Dashboard")
                            return :passed
                        end

                        @test result == :passed
                        @test isfile(joinpath(dir, "screenshot.png"))
                        @test isfile(joinpath(dir, "console.log"))
                        @test isfile(joinpath(dir, "errors.log"))
                        close!(browser)
                    end

                    @testset "$engine: the page really is closed afterwards" begin
                        browser = launch(bt; headless = true)
                        ctx = new_context(browser)
                        escaped = with_page(ctx, "$base_url/late-title.html") do page
                            return page
                        end
                        # Closed on the way out, however the body ended.
                        @test_throws Playwright.TargetClosedError title(escaped)
                        close!(browser)
                    end

                    @testset "$engine: report_diagnostics after close!(ctx)" begin
                        # The masked-failure regression in full: close the context,
                        # then dump. Nothing throws.
                        browser = launch(bt; headless = true)
                        ctx = new_context(browser)
                        page = new_page(ctx)
                        goto!(page, "$base_url/late-title.html")
                        close!(ctx)

                        dir = mktempdir()
                        files = report_diagnostics(page, dir)
                        @test files isa Vector{String}
                        # The screenshot cannot be taken on a dead page, and
                        # the buffers are empty — so nothing is written, and
                        # above all nothing is raised.
                        @test isempty(files)

                        close!(browser)
                    end
                end
            end
        end
    end
end
