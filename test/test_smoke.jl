# Smoke tests: real driver, real browsers. Gated behind PLAYWRIGHT_JL_SMOKE=1.

using HTTP
using Sockets

"Serve test/fixtures/ on an ephemeral localhost port for the duration of `f`."
function with_fixture_server(f::Function)
    dir = joinpath(@__DIR__, "fixtures")
    server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
        path = req.target == "/" ? "/index.html" : req.target
        file = normpath(joinpath(dir, lstrip(path, '/')))
        if startswith(file, dir) && isfile(file)
            HTTP.Response(200, ["Content-Type" => "text/html"], read(file))
        else
            HTTP.Response(404, "not found")
        end
    end
    port = HTTP.port(server)
    try
        f("http://127.0.0.1:$port")
    finally
        close(server)
    end
end

"PIDs of running Playwright-owned browser processes (linux/mac)."
playwright_browser_pids() =
    filter(!isempty, split(something(tryrun(`pgrep -f ms-playwright`), ""), '\n'))

tryrun(cmd) = try
    read(cmd, String)
catch
    nothing
end

@testset "smoke" begin
    @testset "playwright() bootstraps and shuts down the driver" begin
        pw_ref = Ref{Any}(nothing)
        result = playwright() do pw
            @test pw isa Playwright.PlaywrightAPI
            @test pw.chromium isa Playwright.BrowserType
            @test pw.firefox isa Playwright.BrowserType
            @test Playwright.browser_name(pw.chromium) == "chromium"
            @test Playwright.browser_name(pw.firefox) == "firefox"
            pw_ref[] = pw
            :block_result
        end
        @test result === :block_result
        @test !process_running(pw_ref[].process)
    end

    @testset "playwright() kills the driver even when the block throws" begin
        pw_ref = Ref{Any}(nothing)
        @test_throws ErrorException playwright() do pw
            pw_ref[] = pw
            error("boom")
        end
        @test !process_running(pw_ref[].process)
    end

    if Sys.isunix()
        @testset "no orphan browser processes, even without close(browser)" begin
            before = playwright_browser_pids()
            pw_ref = Ref{Any}(nothing)
            playwright() do pw
                pw_ref[] = pw
                browser = launch(pw.chromium; headless = true)
                page = new_page(browser)
                goto(page, "data:text/html,<h1>leak check</h1>")
                # deliberately no close(browser)
            end
            @test !process_running(pw_ref[].process)
            # The driver tears its browsers down on exit; give it a moment.
            @test timedwait(() -> length(playwright_browser_pids()) <= length(before),
                            10.0) === :ok
        end
    end

    with_fixture_server() do base_url
        playwright() do pw
            for browser_name in ("chromium", "firefox")
                bt = getfield(pw, Symbol(browser_name))

                @testset "$browser_name: launch → new_page → goto → title → close" begin
                    browser = launch(bt; headless = true)
                    @test browser isa Playwright.Browser
                    page = new_page(browser)
                    @test page isa Playwright.Page

                    response = goto(page, "$base_url/")
                    @test response isa Playwright.Response
                    @test title(page) == "Playwright.jl Fixture"

                    goto(page, "$base_url/second.html")
                    @test title(page) == "Second Fixture Page"

                    @test_throws PlaywrightError goto(page,
                        "http://127.0.0.1:1/unreachable"; timeout = 5_000)

                    close(page)
                    close(browser)
                end

                @testset "$browser_name: locators — text_content, click, fill" begin
                    browser = launch(bt; headless = true)
                    page = new_page(browser)
                    goto(page, "$base_url/")

                    heading = locator(page, "h1")
                    @test heading isa Playwright.Locator
                    @test text_content(heading) == "Hello from the fixture"

                    # click has an observable DOM effect
                    status = locator(page, "#status")
                    @test text_content(status) == "untouched"
                    click(locator(page, "#mutate"))
                    @test text_content(status) == "clicked"

                    # fill round-trips through the input's value
                    name = locator(page, "#name")
                    @test input_value(name) == ""
                    fill(name, "Jane Doe")
                    @test input_value(name) == "Jane Doe"

                    # missing selector times out with the driver's explanation
                    err = try
                        click(locator(page, "#does-not-exist"); timeout = 500)
                        nothing
                    catch e
                        e
                    end
                    @test err isa PlaywrightError
                    @test occursin("Timeout 500ms exceeded", err.message)
                    @test occursin("does-not-exist", err.message)   # via the call log

                    close(browser)
                end

                @testset "$browser_name: screenshot writes a non-empty PNG" begin
                    browser = launch(bt; headless = true)
                    page = new_page(browser)
                    goto(page, "$base_url/")

                    path = joinpath(mktempdir(), "example.png")
                    bytes = screenshot(page; path)
                    @test isfile(path)
                    png_magic = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
                    @test read(path, 8) == png_magic
                    @test length(bytes) > 8 && bytes[1:8] == png_magic

                    close(browser)
                end
            end
        end
    end
end
