# WGLMakie.jl — an interactive plot, screenshotted and traced.
#
#     julia --project=examples examples/wglmakie_jl.jl
#     PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/wglmakie_jl.jl
#
# The hardest of the four examples, and the one that justifies the artifact
# API: a WebGL canvas is exactly the case where "the assertion failed" tells
# you nothing and a screenshot tells you everything.
#
# ## Assertion level: Chromium-only for the rendered pixels
#
# This is **not** a limitation discovered by this script. It was fixed in
# advance by a probe (`tasks/m5-probe.md`, five browser configurations, two
# reproducing runs, with the display unset):
#
#   * **Chromium renders the figure in full, with no launch flags at all.**
#     Playwright's Chromium ships SwiftShader and selects it when there is no
#     GPU, so `--use-gl=swiftshader` and the `--enable-unsafe-swiftshader`
#     incantation that circulates for this problem both produce a
#     byte-identical screenshot to passing nothing.
#   * **Firefox has no WebGL context whatsoever.** Not a slow one, not a broken
#     one — none. Prefs, a Mesa software-GL environment, and both together all
#     changed nothing; the console says "Exhausted GL driver options".
#
# So the pixel assertion runs on Chromium only. Firefox is still run, and still
# asserted on, at the structural level — the canvas is created at the requested
# size and the page raises no errors — because WGLMakie's no-WebGL fallback is
# a designed path rather than a crash, which makes "no page errors" a real
# assertion on both engines rather than a tautology on one.

using Bonito
using WGLMakie
using PNGFiles
using Test
using Playwright

include("common.jl")

WGLMakie.activate!()

const OUTPUT = joinpath(@__DIR__, "output")

# The readiness signal, and the whole reason this example is not three lines
# shorter. There is no DOM event for "WebGL has painted": the canvas element
# exists long before anything is drawn on it, so `wait_for_selector` returns
# far too early. What *is* observable is the screenshot, so the wait is on the
# pixels — count the distinct colours and wait for the plot to appear.
#
# The figure below is deliberately high-variance (three series, in red, blue
# and green) so a blank result cannot be explained away as a flat plot. The
# three states are an order of magnitude apart, measured:
#
#     Bonito still loading    123 distinct colours
#     Firefox's fallback      241
#     fully rendered        ~1690
#
const RENDERED_COLOURS = 500

distinct_colours(png::Vector{UInt8}) = length(Set(vec(PNGFiles.load(IOBuffer(png)))))

function make_app()
    return App() do
        fig = Figure(size = (800, 600), backgroundcolor = :white)
        ax = Axis(fig[1, 1], title = "Playwright.jl · WGLMakie.jl")
        xs = range(0, 4pi, length = 200)
        lines!(ax, xs, sin.(xs), color = :red, linewidth = 4)
        lines!(ax, xs, cos.(xs), color = :blue, linewidth = 4)
        scatter!(ax, xs[1:10:end], sin.(xs[1:10:end]), color = :green, markersize = 20)
        fig
    end
end

mkpath(OUTPUT)
port = free_port()
url = "http://127.0.0.1:$port/"
server = Bonito.Server(make_app(), "127.0.0.1", port)

try
    wait_for_server(url)

    playwright() do pw
        engine_name = get(ENV, "PLAYWRIGHT_JL_ENGINE", "chromium")
        browser = launch(engine(pw); headless = true)
        try
            ctx = new_context(browser)
            try
                # Trace the whole run. On a page whose failure mode is "the
                # canvas stayed blank", the trace's filmstrip is the difference
                # between a bug report and a guess.
                with_tracing(
                    ctx;
                    path = joinpath(OUTPUT, "wglmakie-$engine_name.zip"),
                    screenshots = true,
                ) do
                    page = new_page(ctx)
                    goto(page, url)

                    @testset "WGLMakie.jl example ($engine_name)" begin
                        # Structural, and true on both engines. Bonito injects
                        # the canvas asynchronously, so this is a real wait.
                        wait_for_selector(page, "canvas"; timeout = 60_000)
                        size = evaluate(
                            page,
                            """() => {
                              const c = document.querySelector('canvas');
                              return {w: c.width, h: c.height};
                            }""",
                        )
                        @test size["w"] == 800
                        @test size["h"] == 600

                        if engine_name == "chromium"
                            # The pixel assertion. Budget 90 seconds: the probe
                            # measured 57.9s for a cold first render — Bonito
                            # serving its bundle, the browser compiling the
                            # WGLMakie JS, and SwiftShader compiling shaders on
                            # the CPU, all at once — against 1.8s warm. CI is
                            # the cold case every time. A fixed sleep here is
                            # either a flake or a minute thrown away.
                            colours = 0
                            rendered = retry_until(;
                                timeout = 90_000,
                                interval = 500,
                                on_timeout = :false,
                            ) do
                                colours = distinct_colours(screenshot(page))
                                colours > RENDERED_COLOURS
                            end
                            @test rendered
                            @test colours > RENDERED_COLOURS
                            @info "WGLMakie rendered" colours
                        else
                            # Level 2. Headless Firefox has no WebGL, so the
                            # canvas is there and empty and WGLMakie draws its
                            # own fallback. Assert that, rather than pretending
                            # the plot rendered.
                            has_webgl = evaluate(
                                page,
                                """() => {
                                  const c = document.createElement('canvas');
                                  return !!(c.getContext('webgl2') || c.getContext('webgl'));
                                }""",
                            )
                            @test has_webgl == false
                            @info "no WebGL on $engine_name; structural assertions only"
                        end

                        # True on both engines: the fallback is a designed
                        # path, so a page error here is a real failure.
                        @test isempty(page_errors(page))

                        # The artifact half of the example. The screenshot is
                        # worth keeping either way — on Chromium it is the
                        # plot, and on Firefox it is the evidence for the
                        # paragraph above.
                        screenshot(
                            page;
                            path = joinpath(OUTPUT, "wglmakie-$engine_name.png"),
                        )
                    end
                end
            finally
                close(ctx)
            end
        finally
            close(browser)
        end
    end
finally
    close(server)
end

@info "Artifacts written to $OUTPUT (gitignored)"
