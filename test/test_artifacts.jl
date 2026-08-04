# Artifact capture: tracing, video and PDF (SPEC-M4.md part A).
#
# Everything that can be asserted without a browser is asserted without one —
# wire params, argument validation, repo hygiene. The browser legs live behind
# PLAYWRIGHT_JL_SMOKE=1 at the bottom of the file.

@testset "artifacts stay out of git (T0)" begin
    # The tests below write real binaries — trace zips, .webm video, PDF — into
    # artifacts/. Ignoring the directory is what stops one of them being
    # committed by a `git add -A` on a bad day, so it is asserted rather than
    # assumed.
    ignore = read(joinpath(@__DIR__, "..", ".gitignore"), String)
    patterns = strip.(split(ignore, '\n'))
    @test "artifacts/" in patterns
end

@testset "the m4 fixture exists (T0)" begin
    fixture = joinpath(@__DIR__, "fixtures", "m4.html")
    @test isfile(fixture)

    html = read(fixture, String)
    # The target snippet asserts `to_have_title = "M4"`, and SC 6 wants that
    # value to arrive *late* — a title that is already correct at parse proves
    # nothing about retrying. So the document starts under a different title
    # and renames itself.
    @test occursin("document.title", html)
    @test !occursin("<title>M4</title>", html)
    # Something for report_diagnostics to find (T9).
    @test occursin("console.log", html)
end
