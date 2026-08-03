# T1: error taxonomy. Hermetic — classification is driven by canned protocol
# payloads, so no driver and no browser are needed.
#
# The payload shapes below were probed against the live 1.61.1 driver
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
        # SC 4: a thrown JS error and a never-appearing selector must be
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
end
