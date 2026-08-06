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
                goto!(page, "$base_url/target.html")

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
                goto!(page, url)

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

                close!(ctx)
                close!(browser)
            end

            @test true   # every assertion above is an @assert, as in the spec
        end
    end
end

# SPEC-M3.md's target snippet, verbatim apart from `url`, which the spec leaves
# as a placeholder. SC 1: if this stops compiling or passing, milestone 3's
# headline promise has broken.
@testset "SPEC-M3 target snippet" begin
    with_fixture_server() do base_url
        for engine in ("chromium", "firefox")
            @testset "$engine" begin
                url = "$base_url/m3.html"

                playwright() do pw
                    browser = launch(getfield(pw, Symbol(engine)); headless = true)
                    @assert browser_name(browser) == engine          # gap 6

                    ctx = new_context(browser)
                    set_default_timeout!(ctx, 2_000)                     # gap 3
                    page = new_page(ctx)
                    goto!(page, url)

                    # gap 1 — real auto-waiting, no hand-rolled polling
                    wait_for_selector(page, "#late")
                    wait_for_function(page, "() => window.ready === true")

                    # retrying assertions, driver-side
                    expect(locator(page, "h1"); to_have_text = "Hello")
                    expect(
                        locator(page, "input[type=range]"; strict = false);
                        to_have_count = 2,
                    )
                    expect(locator(page, "#late"); to_be_visible = true)

                    # gap 2 — evaluate against a Locator, no private fields
                    slider = first(locator(page, "input[type=range]"; strict = false))
                    evaluate(
                        slider,
                        "(el, v) => { el.value = v; el.dispatchEvent(new Event('input')) }",
                        7,
                    )

                    # events: subscribe, act, wait — race-free
                    popup = expect_event(ctx, :page) do
                        click!(locator(page, "#open-popup"))
                    end
                    @assert popup isa Page

                    # gap 4 — branch precisely on failure kind
                    try
                        wait_for_selector(page, "#never"; timeout = 200)
                    catch e
                        e isa TimeoutError || rethrow()
                    end

                    close!(browser)
                end

                # The snippet's own @asserts carry it; this records that the
                # whole thing ran to completion on this engine.
                @test true
            end
        end
    end
end

# SPEC-M4.md's target snippet (SC 13).
#
# Verbatim apart from three substitutions, each of which the spec leaves as a
# placeholder or which the surrounding harness has to supply — the same licence
# `url` was given for the M3 snippet above:
#
#   * `probe_url` is the spec's own placeholder; the fixture server supplies one.
#   * the `file://` path is resolved through @__DIR__, because Pkg.test runs
#     with `test/` as the working directory and the snippet's relative
#     `abspath("test/fixtures/m4.html")` assumes the repo root.
#   * `page` is declared before the `with_tracing` block. The snippet assigns it
#     inside the do-block and reads it after; a do-block is a closure, so read
#     literally that is an UndefVarError rather than a claim about the library.
#
# **Chromium runs the snippet as written. Firefox cannot** — the snippet calls
# `pdf`, which SC 5 requires to raise on Firefox, so SC 13 and SC 5 contradict
# each other for that one call. Rather than drop the Firefox leg, it runs the
# identical snippet with the two `pdf` lines replaced by the assertion that
# `pdf` refuses. Every other line is shared.
@testset "SPEC-M4 target snippet" begin
    with_fixture_server() do base_url
        for engine in ("chromium", "firefox")
            @testset "$engine" begin
                probe_url = "$base_url/m4.html"
                fixture = joinpath(@__DIR__, "fixtures", "m4.html")
                artifacts = mktempdir()

                playwright() do pw
                    browser = launch(getfield(pw, Symbol(engine)); headless = true)
                    ctx = new_context(
                        browser;
                        record_video = (dir = joinpath(artifacts, "video"),),
                    )

                    local page
                    with_tracing(
                        ctx;
                        path = joinpath(artifacts, "trace.zip"),
                        screenshots = true,
                        snapshots = true,
                    ) do
                        page = new_page(ctx)
                        set_default_timeout!(page, 2_000)
                        goto!(page, "file://" * fixture)

                        # B6: assertions about the document, not just an element
                        expect(page; to_have_title = "M4")
                        expect(page; to_have_url = r"m4\.html$")

                        # B1/B2/B3: reports a Fail, inherits the page's 2 s
                        # timeout, retries through a predicate that throws
                        # while the server warms up
                        @test retry_until(page; on_timeout = :false, on_error = :retry) do
                            HTTP.get(probe_url).status == 200
                        end

                        # A3 — Chromium only, by design (D7)
                        if engine == "chromium"
                            bytes = pdf(
                                page;
                                path = joinpath(artifacts, "page.pdf"),
                                format = "A4",
                            )
                            @test !isempty(bytes)
                        else
                            @test_throws ArgumentError pdf(page)
                        end

                        close!(page)
                        # A2: the video only exists once the page is closed
                        @test isfile(path(video(page)))
                    end

                    # B5: teardown after the context is gone must not throw
                    close!(ctx)
                    @test isempty(page_errors(page))

                    @test isfile(joinpath(artifacts, "trace.zip"))
                    close!(browser)
                end
            end
        end
    end
end
