# Milestone-2 acceptance: the Bonnie-parity shim and SPEC-M2.md's target
# snippet, both run against real browsers so neither can quietly rot.

include("bonnie_shim.jl")

@testset "Bonnie parity" begin
    @testset "the shim is small and uses only public API" begin
        source = read(joinpath(@__DIR__, "bonnie_shim.jl"), String)
        code = [
            line for line in split(source, '\n') if
            !isempty(strip(line)) && !startswith(strip(line), "#")
        ]
        # Docstrings are documentation, not implementation.
        in_docstring = false
        implementation = filter(code) do line
            count("\"\"\"", line) == 1 && (in_docstring = !in_docstring; return false)
            return !in_docstring
        end
        @test length(implementation) < 40

        # Only exported API — no reaching into internals. Checked over the
        # implementation lines, since the prose above is free to name the
        # package.
        code_text = join(implementation, '\n')
        @test !occursin("Playwright.", code_text)
        @test !occursin("_frame_", code_text)
        @test !occursin("send_message", code_text)
    end

    @testset "the shim drives a real page" begin
        with_fixture_server() do base_url
            with_page() do page
                goto(page, "$base_url/target.html")

                # evaluate needs no shim; poll_js is built on it.
                @test evaluate(page, "1 + 1") == 2
                @test poll_js(page, "() => document.readyState === 'complete'")
                @test poll_js(page, "() => window.app.ready")

                # ...and a condition that never comes reports rather than hangs.
                @test_throws ErrorException poll_js(
                    page,
                    "() => window.neverEver";
                    timeout = 1.0,
                )
            end
        end
    end

    # SPEC-M2.md's target snippet, verbatim apart from `url` and the
    # fill_range! helper it names as user-side. If this stops compiling or
    # passing, the milestone's headline promise has broken.
    @testset "SPEC-M2 target snippet" begin
        # SC 5: exported API only. This used to reach into `slider.frame` and
        # `slider.selector`, which is the private-field access T7 removed the
        # need for — `evaluate` now takes the Locator itself.
        fill_range!(slider, value) = begin
            evaluate(slider, "(el, v) => el.value = v", value)
            dispatch_event(slider, "input")
        end

        with_fixture_server() do base_url
            url = "$base_url/target.html"

            playwright() do pw
                browser = launch(
                    pw.chromium;
                    headless = true,
                    chromium_sandbox = false,
                    args = ["--disable-dev-shm-usage"],
                )
                ctx = new_context(browser)
                page = new_page(ctx)
                goto(page, url)

                # 1. evaluate: values in and out
                @assert evaluate(page, "1 + 1") == 2
                @assert evaluate(page, "x => x.a * 2", Dict("a" => 21)) == 42
                @assert occursin("7", inner_text(locator(page, "body")))

                # 2. frames
                inner = frame_locator(page, "iframe")
                @assert evaluate(content_frame(inner), "document.title") isa String

                # 3. non-strict locators — indexable and iterable
                sliders = locator(page, "input[type=range]"; strict = false)
                @assert count(sliders) == 2
                for slider in sliders
                    @assert input_value(slider) isa String
                end

                # 4. dispatch_event to drive a range input precisely
                fill_range!(first(sliders), 7)   # user-side helper built on dispatch_event

                # scoped JSHandle
                evaluate_handle(page, "() => window.app") do app
                    @assert evaluate(app, "a => a.ready") === true
                end

                # diagnostics on failure
                for err in page_errors(page)
                    @warn "page error" err.message
                end

                close(ctx)
                close(browser)
            end

            @test true   # every assertion above is an @assert, as in the spec
        end
    end
end
