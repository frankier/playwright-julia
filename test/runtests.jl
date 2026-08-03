using Test
using Playwright

@testset "Playwright.jl" begin
    @testset "package loads" begin
        @test Playwright isa Module
        @test isdefined(Playwright, :playwright)
    end

    include("test_exports.jl")
    include("test_driver.jl")
    include("test_protocol_spec.jl")
    include("test_codegen.jl")
    include("test_serializers.jl")
    include("test_transport.jl")
    include("test_connection.jl")

    if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
        include("test_smoke.jl")
        include("test_evaluate.jl")
        include("test_frames.jl")
        include("test_parity.jl")
    else
        @info "Skipping smoke tests (set PLAYWRIGHT_JL_SMOKE=1 to enable)"
    end
end
