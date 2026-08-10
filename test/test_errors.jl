# Error taxonomy. Hermetic — classification is driven by canned protocol
# payloads, so no driver and no browser are needed.
#
# The payload shapes below were measured against the live 1.61.1 driver
# (chromium): a locator timeout arrives as name="TimeoutError", a call against a
# closed page/context as name="TargetClosedError", and a JS exception or a
# navigation failure as name="Error".

using Playwright:
    PlaywrightError, DriverError, TimeoutError, TargetClosedError, AssertionFailure

@testset "error taxonomy" begin
    @testset "every concrete type is a PlaywrightError carrying the driver triple" begin
        for T in (DriverError, TimeoutError, TargetClosedError, AssertionFailure)
            e = T("boom"; name = "Error", stack = "at <anonymous>")
            @test e isa PlaywrightError
            @test e isa Exception
            @test e.message == "boom"
            @test e.name == "Error"
            @test e.stack == "at <anonymous>"
        end
    end

    @testset "PlaywrightError is abstract — it no longer constructs" begin
        @test isabstracttype(PlaywrightError)
        @test_throws MethodError PlaywrightError("boom")
    end

    @testset "classification by the driver's name field" begin
        classify(name) =
            Playwright.driver_error(Dict("message" => "m", "name" => name, "stack" => "s"))

        @test classify("TimeoutError") isa TimeoutError
        @test classify("TargetClosedError") isa TargetClosedError
        @test classify("Error") isa DriverError
        # Anything unrecognised falls through to DriverError rather than
        # erroring — the driver is free to add names we have not seen.
        @test classify("SomeFutureError") isa DriverError
    end

    @testset "a real timeout payload classifies as TimeoutError" begin
        e = Playwright.driver_error(
            Dict(
                "message" => "Timeout 300ms exceeded.",
                "name" => "TimeoutError",
                "stack" => "",
            ),
            ["  - waiting for locator(\"#never\")"],
        )
        @test e isa TimeoutError
        @test occursin("Timeout 300ms exceeded.", e.message)
        # The call log is appended the way upstream clients do.
        @test occursin("Call log:", e.message)
        @test occursin("waiting for locator", e.message)
    end

    @testset "a real target-closed payload classifies as TargetClosedError" begin
        e = Playwright.driver_error(
            Dict(
                "message" => "Target page, context or browser has been closed",
                "name" => "TargetClosedError",
                "stack" => "",
            ),
        )
        @test e isa TargetClosedError
        @test e.message == "Target page, context or browser has been closed"
    end

    @testset "a JS exception classifies as DriverError, not TimeoutError" begin
        # a thrown JS error and a never-appearing selector must be
        # distinguishable by type.
        e = Playwright.driver_error(
            Dict("message" => "Error: boom", "name" => "Error", "stack" => "at eval"),
        )
        @test e isa DriverError
        @test !(e isa TimeoutError)
    end

    @testset "missing fields fall back to defaults" begin
        e = Playwright.driver_error(Dict{String,Any}())
        @test e isa DriverError
        @test e.message == "unknown driver error"
        @test e.name == "Error"
        @test e.stack == ""
    end

    @testset "catching the supertype still works across every subtype" begin
        for T in (DriverError, TimeoutError, TargetClosedError, AssertionFailure)
            caught = try
                throw(T("boom"))
            catch e
                e isa PlaywrightError ? e.message : nothing
            end
            @test caught == "boom"
        end
    end

    @testset "showerror names the concrete type" begin
        @test sprint(showerror, TimeoutError("late")) == "TimeoutError: late"
        @test sprint(showerror, DriverError("bad")) == "DriverError: bad"
        @test sprint(showerror, TargetClosedError("gone")) == "TargetClosedError: gone"
        @test sprint(showerror, AssertionFailure("nope")) == "AssertionFailure: nope"
    end

    # --- The two launch failures that need this package's own advice (D3, D3a)
    #
    # Both are injected rather than observed, because neither can be arranged on
    # a machine that has the browsers. The message shapes below are *copied from
    # a real driver*, not invented: the missing-dependency banner came out of
    # the T5 sweep on Fedora, where WebKit could not launch at all.

    @testset "a missing-library launch failure names --with-deps" begin
        # Verbatim from the driver, box drawing and all.
        driver_msg = """

        \u2554\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2557
        \u2551 Host system is missing dependencies to run browsers. \u2551
        \u2551 Please install them with the following command:      \u2551
        \u2551                                                      \u2551
        \u2551     sudo playwright install-deps                     \u2551
        \u255a\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u2550\u255d
        libwoff2dec.so.1.0.2: cannot open shared object file"""

        out = Playwright.launch_failure_help(DriverError(driver_msg), "webkit", nothing)
        @test out isa DriverError
        # The driver's own text survives -- it carries the missing library,
        # which is the actual diagnosis and must not be thrown away.
        @test occursin("libwoff2dec", out.message)
        @test occursin("missing dependencies", out.message)
        # ...and this package's command is named, with the engine in it.
        @test occursin("--with-deps", out.message)
        @test occursin("bin/install.jl", out.message)
        @test occursin("webkit", out.message)
        @test occursin("sudo", out.message)
    end

    @testset "a missing branded browser names bin/install.jl and says system-wide" begin
        driver_msg =
            "Chromium distribution 'msedge' is not found at " *
            "/opt/microsoft/msedge/msedge\nRun \"playwright install msedge\""

        out = Playwright.launch_failure_help(DriverError(driver_msg), "chromium", "msedge")
        @test out isa DriverError
        # The driver said which path it looked in. Keep it.
        @test occursin("/opt/microsoft/msedge/msedge", out.message)
        @test occursin("bin/install.jl msedge", out.message)
        # The thing Playwright's own message does not say:
        @test occursin("system-wide", out.message)
        @test occursin("chromium", out.message)   # names the no-system-change option
    end

    @testset "an unrecognised launch failure is passed through untouched" begin
        # The annotation must not swallow failures it does not understand --
        # every other launch error still surfaces exactly as the driver sent it.
        err = DriverError("Target page, context or browser has been closed")
        @test Playwright.launch_failure_help(err, "firefox", nothing) === err
        @test Playwright.launch_failure_help(err, "chromium", "chrome") === err
        # A branded-shaped message on a bundled engine is not the branded case:
        # there is no channel, so there is no system install to suggest.
        notfound = DriverError("Executable doesn't exist at /home/x/.cache/ms-playwright")
        @test Playwright.launch_failure_help(notfound, "firefox", nothing) === notfound
    end
end
