# Smoke tests: real driver, real browsers. Gated behind PLAYWRIGHT_JL_SMOKE=1.

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
end
