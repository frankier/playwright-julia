# Unit tests for the vendored protocol spec (hermetic — no downloads).
#
# The spec under protocol/spec/ is vendored from microsoft/playwright at tag
# v$PLAYWRIGHT_VERSION by gen/fetch_spec.jl. These tests assert the vendored
# copy is present, complete, and pinned to the same version the driver is.

@testset "vendored protocol spec" begin
    specdir = joinpath(@__DIR__, "..", "protocol", "spec")
    stampfile = joinpath(@__DIR__, "..", "protocol", "VERSION")

    @testset "present and pinned" begin
        @test isdir(specdir)
        @test isfile(stampfile)
        # The vendored spec must track the version the driver runs, so the
        # generated channel layer can never drift from the driver's protocol.
        @test strip(read(stampfile, String)) == Playwright.PLAYWRIGHT_VERSION
    end

    @testset "complete" begin
        files = filter(f -> endswith(f, ".yml"), readdir(specdir))
        # The generator resolves $mixin inclusions and SerializedValue across
        # files, so a partial vendoring is worse than none — assert the ones
        # this package actually reads are all here.
        for required in [
            "serialized.yml",
            "frame.yml",
            "page.yml",
            "browserType.yml",
            "browserContext.yml",
            "mixins.yml",
            "handles.yml",
        ]
            @test required in files
        end
        @test length(files) == 19
    end

    @testset "provenance is recorded" begin
        readme = joinpath(@__DIR__, "..", "protocol", "README.md")
        @test isfile(readme)
        @test isfile(joinpath(@__DIR__, "..", "protocol", "LICENSE-PLAYWRIGHT"))
        text = read(readme, String)
        @test occursin("gen/fetch_spec.jl", text)
        @test occursin(Playwright.PLAYWRIGHT_VERSION, text)
    end
end
