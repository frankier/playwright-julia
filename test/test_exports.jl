# The package's public surface, pinned.
#
# This exists to fence refactors: splitting src/api.jl into src/api/* (T4) must
# not move, drop or accidentally add a single exported name. When the API grows
# deliberately, add the name here in the same commit — the diff is then a
# visible record of a public-surface change rather than a silent one.

@testset "exports" begin
    expected = [
        :Playwright,        # the module itself
        :PlaywrightError,
        :click,
        :goto,
        :input_value,
        :install,
        :launch,
        :locator,
        :new_page,
        :playwright,
        :screenshot,
        :text_content,
        :title,
    ]
    @test sort(names(Playwright)) == sort(expected)

    # Every exported name must actually resolve — an export with no definition
    # behind it only fails at the call site.
    for name in expected
        @test isdefined(Playwright, name)
    end
end
