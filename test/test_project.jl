# T0 (M5): release metadata that is checkable. Hermetic — reads Project.toml
# and LICENSE off disk, nothing else.
#
# These are the two claims that only bite at registration time, long after the
# mistake was made: a dependency with no compat bound, and a missing licence.
# SC 15 also wants `[deps]` to stay untouched for the whole milestone, so the
# dependency set is pinned here by name.

using TOML

@testset "project metadata" begin
    root = dirname(@__DIR__)
    project = TOML.parsefile(joinpath(root, "Project.toml"))

    @testset "every dependency carries a compat bound" begin
        compat = get(project, "compat", Dict{String,Any}())
        # Registrator requires a bound on everything nameable, stdlibs included.
        for section in ("deps", "extras")
            for name in keys(get(project, section, Dict{String,Any}()))
                @test haskey(compat, name)
            end
        end
        @test compat["julia"] == "1.10"
    end

    @testset "[deps] is unchanged (SC 15)" begin
        # M5 adds no runtime dependency: examples and docs live in their own
        # projects (D2). If this list needs editing, that is the milestone's
        # boundary being crossed, not a stale test.
        @test sort(collect(keys(project["deps"]))) ==
              ["Base64", "Dates", "Downloads", "JSON", "Scratch", "p7zip_jll"]
    end

    @testset "LICENSE is MIT" begin
        path = joinpath(root, "LICENSE")
        @test isfile(path)
        text = read(path, String)
        @test occursin("MIT License", text)
        @test occursin("Frankie Robertson", text)
        @test occursin(r"Permission is hereby granted, free of charge", text)
    end
end
