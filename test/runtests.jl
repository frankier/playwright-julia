using Test
using Playwright

@testset "Playwright.jl" begin
    @testset "package loads" begin
        @test Playwright isa Module
        @test isdefined(Playwright, :playwright)
    end

    include("test_project.jl")
    include("test_exports.jl")
    include("test_errors.jl")
    include("test_driver.jl")
    include("test_protocol_spec.jl")
    include("test_codegen.jl")
    include("test_serializers.jl")
    include("test_transport.jl")
    include("test_connection.jl")
    include("test_timeouts.jl")
    include("test_globs.jl")
    include("test_network.jl")
    include("test_events.jl")
    include("test_routing.jl")
    # After test_routing.jl: HAR replay is a route! handler (D2), so its tests
    # reuse send_route and last_patterns from there.
    include("test_har.jl")
    # After test_har.jl: reuses its har_fixture, which is the only fake-driver
    # fixture that registers a LocalUtils and a Tracing channel.
    include("test_websockets.jl")
    include("test_waiting.jl")
    # After test_waiting.jl: these use its waiting_request helper, as well as
    # timeout_fixture (test_timeouts.jl) and send_event (test_events.jl).
    include("test_downloads.jl")
    include("test_dialogs.jl")
    include("test_uploads.jl")
    include("test_locator_eval.jl")
    include("test_closed.jl")
    include("test_expect.jl")
    include("test_metadata.jl")

    if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
        include("test_smoke.jl")
        include("test_fixtures.jl")
        include("test_evaluate.jl")
        include("test_frames.jl")
        include("test_parity.jl")
        include("test_smoke_network.jl")
        # After test_smoke_network.jl: reuses its with_browser, within_deadline
        # and todo_texts helpers, and its network.html fixture page.
        include("test_smoke_har.jl")
        # After test_smoke.jl and test_smoke_network.jl: uses the former's
        # fixture server and playwright_browser_pids, the latter's
        # within_deadline.
        include("test_smoke_persistent.jl")
        # After test_smoke_network.jl: reuses within_deadline and with_browser.
        # Its server is its own — proving mock mode never contacts the real one
        # needs a server that counts connections.
        include("test_smoke_websockets.jl")
        include("test_smoke_files.jl")
    else
        @info "Skipping smoke tests (set PLAYWRIGHT_JL_SMOKE=1 to enable)"
    end

    # Milestone 4's artifact tests are mostly hermetic, so this always runs —
    # but the few legs that need a real browser are gated inside the file and
    # use test_smoke.jl's fixture server, which is why it comes last.
    include("test_artifacts.jl")
    include("test_fixtures_api.jl")
end
