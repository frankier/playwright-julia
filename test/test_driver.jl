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
end
