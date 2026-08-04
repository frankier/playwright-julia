# Unit tests for src/driver.jl (hermetic — no downloads).

@testset "driver" begin
    @testset "node platform mapping" begin
        @test Playwright.node_platform(; os = :linux, arch = :x86_64) == "linux-x64"
        @test Playwright.node_platform(; os = :linux, arch = :aarch64) == "linux-arm64"
        @test Playwright.node_platform(; os = :macos, arch = :x86_64) == "darwin-x64"
        @test Playwright.node_platform(; os = :macos, arch = :aarch64) == "darwin-arm64"
        @test Playwright.node_platform(; os = :windows, arch = :x86_64) == "win-x64"
        @test_throws ErrorException Playwright.node_platform(; os = :linux, arch = :i686)
    end

    @testset "download URL construction" begin
        @test Playwright.playwright_core_url() ==
              "https://registry.npmjs.org/playwright-core/-/playwright-core-$(Playwright.PLAYWRIGHT_VERSION).tgz"
        node_url = Playwright.node_url(; os = :linux, arch = :x86_64)
        @test node_url ==
              "https://nodejs.org/dist/v$(Playwright.NODE_VERSION)/node-v$(Playwright.NODE_VERSION)-linux-x64.tar.xz"
        @test endswith(Playwright.node_url(; os = :windows, arch = :x86_64), ".zip")
    end

    @testset "driver command shape" begin
        # Does not require the driver to be installed — just inspects the Cmd.
        cmd = Playwright.driver_cmd("run-driver"; dir = "/fake/driver")
        words = collect(cmd.exec)
        @test words[1] == joinpath("/fake/driver", Sys.iswindows() ? "node.exe" : "node")
        @test words[2] == joinpath("/fake/driver", "package", "cli.js")
        @test words[3] == "run-driver"
    end

    # --- T9: install ergonomics -------------------------------------------

    @testset "browser names default, and typos are caught before downloading" begin
        @test Playwright.browsers_from_args(String[]) == ["chromium", "firefox"]
        @test Playwright.browsers_from_args(["chromium"]) == ["chromium"]
        @test Playwright.browsers_from_args(["Firefox"]) == ["firefox"]
        @test Playwright.browsers_from_args(["chromium", "webkit"]) ==
              ["chromium", "webkit"]
        # A typo must fail here rather than after a few hundred MB of download.
        @test_throws ArgumentError Playwright.browsers_from_args(["chrome"])
        @test_throws ArgumentError Playwright.browsers_from_args(["chromium", "safari"])
        # ...and the default list is not aliased, so a caller mutating the
        # result cannot change what the next caller gets.
        first_call = Playwright.browsers_from_args(String[])
        push!(first_call, "webkit")
        @test Playwright.browsers_from_args(String[]) == ["chromium", "firefox"]
    end

    @testset "browsers_path reports the PLAYWRIGHT_BROWSERS_PATH override" begin
        restore = get(ENV, "PLAYWRIGHT_BROWSERS_PATH", nothing)
        try
            delete!(ENV, "PLAYWRIGHT_BROWSERS_PATH")
            @test Playwright.browsers_path() === nothing
            ENV["PLAYWRIGHT_BROWSERS_PATH"] = "/tmp/somewhere"
            @test Playwright.browsers_path() == "/tmp/somewhere"
        finally
            restore === nothing ? delete!(ENV, "PLAYWRIGHT_BROWSERS_PATH") :
            (ENV["PLAYWRIGHT_BROWSERS_PATH"] = restore)
        end
    end

    @testset "bin/install.jl is present and parses" begin
        script = joinpath(pkgdir(Playwright), "bin", "install.jl")
        @test isfile(script)
        # Parsing it here means a syntax error shows up in the suite rather
        # than the first time someone runs it in CI.
        @test Meta.parseall(read(script, String)) isa Expr
    end
end
