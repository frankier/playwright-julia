# Unit tests for src/driver.jl (hermetic — no downloads).

@testset "driver" begin
    # All six OS/arch pairs the package claims, exhaustively (SC 13). These are
    # pure functions and have always been testable, but M9 makes them
    # load-bearing on two platforms nobody would notice breaking: until now
    # only the linux-x64 row had ever been *executed*, and a wrong infix is a
    # 404 an hour into someone's first run on a new machine.
    node_platforms = [
        (:linux, :x86_64) => "linux-x64",
        (:linux, :aarch64) => "linux-arm64",
        (:macos, :x86_64) => "darwin-x64",
        (:macos, :aarch64) => "darwin-arm64",
        (:windows, :x86_64) => "win-x64",
        (:windows, :aarch64) => "win-arm64",
    ]

    @testset "node platform mapping" begin
        for ((os, arch), infix) in node_platforms
            @test Playwright.node_platform(; os, arch) == infix
        end
    end

    @testset "unsupported platforms name the value that was wrong" begin
        # The message has to carry the offending value: "unsupported
        # architecture" alone leaves the reader guessing which of the two
        # keywords they got wrong.
        err = try
            Playwright.node_platform(; os = :linux, arch = :i686)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("i686", err.msg)

        err = try
            Playwright.node_platform(; os = :plan9, arch = :x86_64)
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("plan9", err.msg)
    end

    @testset "download URL construction" begin
        @test Playwright.playwright_core_url() ==
              "https://registry.npmjs.org/playwright-core/-/playwright-core-$(Playwright.PLAYWRIGHT_VERSION).tgz"
        v = Playwright.NODE_VERSION
        for ((os, arch), infix) in node_platforms
            # Windows ships a .zip and everything else a .tar.xz — the branch
            # that decides which member filter install_driver uses (D9).
            ext = os === :windows ? "zip" : "tar.xz"
            @test Playwright.node_url(; os, arch) ==
                  "https://nodejs.org/dist/v$v/node-v$v-$infix.$ext"
        end
    end

    @testset "driver command shape" begin
        # Does not require the driver to be installed — just inspects the Cmd.
        cmd = Playwright.driver_cmd("run-driver"; dir = "/fake/driver")
        words = collect(cmd.exec)
        @test words[1] == joinpath("/fake/driver", Sys.iswindows() ? "node.exe" : "node")
        @test words[2] == joinpath("/fake/driver", "package", "cli.js")
        @test words[3] == "run-driver"
    end

    # --- Install ergonomics -----------------------------------------------

    @testset "browser names default, and typos are caught before downloading" begin
        @test Playwright.browsers_from_args(String[]) == ["chromium", "firefox"]
        @test Playwright.browsers_from_args(["chromium"]) == ["chromium"]
        @test Playwright.browsers_from_args(["Firefox"]) == ["firefox"]
        @test Playwright.browsers_from_args(["chromium", "webkit"]) ==
              ["chromium", "webkit"]
        # The branded names are installable too -- as system packages, not as
        # Playwright downloads (D3a).
        @test Playwright.browsers_from_args(["chrome"]) == ["chrome"]
        @test Playwright.browsers_from_args(["msedge"]) == ["msedge"]
        # A typo must fail here rather than after a few hundred MB of download.
        @test_throws ArgumentError Playwright.browsers_from_args(["edge"])
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

    @testset "with_deps reaches the driver's command line" begin
        # SC 7. Asserted on the command rather than by running it: the whole
        # point of --with-deps is that it invokes the distribution's package
        # manager, which a test suite must not do.
        @test Playwright.install_args(["webkit"], false) == ["install", "webkit"]
        @test Playwright.install_args(["webkit"], true) ==
              ["install", "--with-deps", "webkit"]
        @test Playwright.install_args(["chromium", "firefox"], false) ==
              ["install", "chromium", "firefox"]
    end

    @testset "with_deps off Linux is refused before anything is downloaded" begin
        # D3: the driver has nothing to do there, so a script that passes it is
        # confused about what it is running on -- and saying so beats a silent
        # no-op that leaves the caller believing dependencies were installed.
        # The OS is a parameter rather than read from Sys, so the two platforms
        # this developer cannot run are asserted on every platform.
        @test_throws ArgumentError Playwright.check_with_deps(true, :windows)
        @test_throws ArgumentError Playwright.check_with_deps(true, :macos)
        @test Playwright.check_with_deps(true, :linux) === nothing
        # false is fine everywhere, including the platform this runs on.
        @test Playwright.check_with_deps(false, :windows) === nothing
        @test Playwright.check_with_deps(false, :macos) === nothing
        @test Playwright.check_with_deps(false, :linux) === nothing

        err = try
            Playwright.check_with_deps(true, :macos)
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("with_deps", err.msg)
        @test occursin("Linux", err.msg)
    end

    @testset "a branded name warns that it is a system-wide install" begin
        # SC 8 / D3a. `playwright install chrome` does not download a browser
        # into PLAYWRIGHT_BROWSERS_PATH -- it installs Google Chrome as a
        # system package, with apt on Linux. An installer that silently invokes
        # sudo apt because someone typed a browser name is not acceptable
        # behaviour; saying so first is.
        #
        # No install is performed here: the warning is its own function
        # precisely so it can be asserted without one.
        for name in ("chrome", "msedge")
            logs = Test.collect_test_logs() do
                Playwright.warn_branded_install([name], :linux)
            end[1]
            @test length(logs) == 1
            @test logs[1].level == Base.CoreLogging.Warn
            msg = string(logs[1].message)
            @test occursin(name, msg)
            @test occursin("system", msg)
            @test occursin("root", msg)          # Linux says it needs root
        end

        # Off Linux it is still system-wide, but root is not the mechanism.
        logs = Test.collect_test_logs() do
            Playwright.warn_branded_install(["chrome"], :macos)
        end[1]
        @test length(logs) == 1
        @test occursin("system", string(logs[1].message))

        # The bundled engines say nothing at all -- a warning on every ordinary
        # install is a warning nobody reads.
        for browsers in (["chromium"], ["chromium", "firefox", "webkit"], String[])
            logs = Test.collect_test_logs() do
                Playwright.warn_branded_install(browsers, :linux)
            end[1]
            @test isempty(logs)
        end
    end

    @testset "bin/install.jl parses --with-deps" begin
        # The flag has to be stripped from the browser names, or it reaches
        # browsers_from_args and is rejected as an unknown browser.
        @test Playwright.install_args_from_cli(["--with-deps", "webkit"]) ==
              (["webkit"], true)
        @test Playwright.install_args_from_cli(["webkit", "--with-deps"]) ==
              (["webkit"], true)
        @test Playwright.install_args_from_cli(["webkit"]) == (["webkit"], false)
        @test Playwright.install_args_from_cli(String[]) == (["chromium", "firefox"], false)
        @test_throws ArgumentError Playwright.install_args_from_cli(["--jazz"])
    end

    @testset "the default install is still exactly two browsers" begin
        # SC 11 / D2. WebKit is opt-in: a first-time user following the README
        # does not pay for a third browser download to run the quick-start
        # example. launch() self-heals for the engine they actually ask for.
        @test Playwright.DEFAULT_BROWSERS == ["chromium", "firefox"]
        @test length(Playwright.DEFAULT_BROWSERS) == 2
    end

    @testset "bin/install.jl is present and parses" begin
        script = joinpath(pkgdir(Playwright), "bin", "install.jl")
        @test isfile(script)
        # Parsing it here means a syntax error shows up in the suite rather
        # than the first time someone runs it in CI.
        @test Meta.parseall(read(script, String)) isa Expr
    end
end
