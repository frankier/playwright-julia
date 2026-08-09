# WGLMakie.jl — an interactive plot, screenshotted and traced.
#
#     julia --project=examples examples/wglmakie_jl.jl
#     PLAYWRIGHT_JL_ENGINE=firefox julia --project=examples examples/wglmakie_jl.jl
#
# The hardest of the four examples, and the one that justifies the artifact
# API: a WebGL canvas is exactly the case where "the assertion failed" tells
# you nothing and a screenshot tells you everything.
#
# ## Assertion level: the rendered pixels, on both engines
#
#   * **Chromium renders the figure in full, with no launch flags at all.**
#     Playwright's Chromium ships SwiftShader and selects it when there is no
#     GPU, so `--use-gl=swiftshader` and the `--enable-unsafe-swiftshader`
#     incantation that circulates for this problem both produce a
#     byte-identical screenshot to passing nothing.
#   * **Firefox renders it too, as of the build this repo pins.**
#
# Firefox is worth measuring rather than assuming: older builds had no WebGL
# context at all here, reporting "Exhausted GL driver options" in the console.
# The pinned build gives `has_webgl == true` and 1625 distinct colours, against
# Chromium's ~1690, so the pixel assertion runs on both engines.

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
#     fully rendered         1625 on Firefox, ~1690 on Chromium
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
                    goto!(page, url)

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

                        # WebGL is now present on both engines, and asserting
                        # it keeps the pixel assertion below honest: a blank
                        # canvas with no context is a different failure from a
                        # blank canvas with one, and only the second is a bug
                        # in this example.
                        has_webgl = evaluate(
                            page,
                            """() => {
                              const c = document.createElement('canvas');
                              return !!(c.getContext('webgl2') || c.getContext('webgl'));
                            }""",
                        )
                        @test has_webgl == true

                        # The pixel assertion. Budget 90 seconds: a cold first
                        # render on Chromium measures 57.9s —
                        # Bonito serving its bundle, the browser compiling the
                        # WGLMakie JS, and SwiftShader compiling shaders on the
                        # CPU, all at once — against 1.8s warm. Firefox warm is
                        # 2.5s. The budget is an upper bound rather than a
                        # sleep, so the generous number costs nothing on the
                        # fast path and is what stops CI's cold case flaking.
                        colours = 0
                        rendered = retry_until(;
                            timeout = 90_000,
                            interval = 500,
                            on_timeout = :false,
                        ) do
                            colours = distinct_colours(screenshot_bytes(page))
                            colours > RENDERED_COLOURS
                        end
                        @test rendered
                        @test colours > RENDERED_COLOURS
                        @info "WGLMakie rendered on $engine_name" colours

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
                close!(ctx)
            end
        finally
            close!(browser)
        end
    end
finally
    close(server)
end

@info "Artifacts written to $OUTPUT (gitignored)"
