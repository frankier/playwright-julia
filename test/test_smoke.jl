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

    with_fixture_server() do base_url
        playwright() do pw
            @testset "browser slice: launch → new_page → goto → title → close" begin
                browser = launch(pw.chromium; headless = true)
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
        end
    end
end
