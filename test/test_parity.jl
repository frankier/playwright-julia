# The Bonnie-parity shim, plus three end-to-end walkthroughs of the API, all run
# against real browsers so none of them can quietly rot.
#
# Each walkthrough is one script exercising a whole area from a user's side —
# locators and evaluation, waiting and events, artifacts — rather than one call
# at a time. A unit test says a function works. These say the pieces still fit
# together.

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

    # Walkthrough: locators, non-strict matching and evaluation, on one page.
    @testset "the locators and evaluation walkthrough" begin
        # Exported API only — `evaluate` takes the Locator itself, so driving a
        # range input needs no reach into `slider.frame` or `slider.selector`.
        fill_range!(slider, value) = begin
            evaluate(slider, "(el, v) => el.value = v", value)
            dispatch_event!(slider, "input")
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

                # 4. dispatch_event! to drive a range input precisely
                fill_range!(first(sliders), 7)   # user-side helper built on dispatch_event!

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

# Walkthrough: driver-side waiting, retrying assertions and the event surface,
# against a page where everything asserted on is absent at load.
@testset "the waiting and events walkthrough" begin
    with_fixture_server() do base_url
        for engine in ("chromium", "firefox")
            @testset "$engine" begin
                url = "$base_url/waiting.html"

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

# Walkthrough: tracing, video and PDF around a failing block.
#
# Two details are the harness's rather than the API's. The `file://` path is
# resolved through `@__DIR__`, because `Pkg.test` runs with `test/` as the
# working directory. And `page` is declared before the `with_tracing` block,
# because a do-block is a closure, so assigning inside it and reading after
# would be an `UndefVarError` about Julia rather than about this package.
#
# **Firefox runs a variant.** `pdf` is Chromium-only and raises on Firefox, so
# the Firefox leg replaces the two `pdf` lines with the assertion that `pdf`
# refuses. Every other line is shared.
@testset "the artifacts walkthrough" begin
    with_fixture_server() do base_url
        for engine in ("chromium", "firefox")
            @testset "$engine" begin
                probe_url = "$base_url/late-title.html"
                fixture = joinpath(@__DIR__, "fixtures", "late-title.html")
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
                        expect(page; to_have_title = "Dashboard")
                        expect(page; to_have_url = r"m4\.html$")

                        # B1/B2/B3: reports a Fail, inherits the page's 2 s
                        # timeout, retries through a predicate that throws
                        # while the server warms up
                        @test retry_until(page; on_timeout = :false, on_error = :retry) do
                            HTTP.get(probe_url).status == 200
                        end

                        # A3 — Chromium only, by design (D7)
                        if engine == "chromium"
                            dest = joinpath(artifacts, "page.pdf")
                            @test pdf(page; path = dest, format = "A4") == dest
                            @test filesize(dest) > 0
                        else
                            @test_throws ArgumentError pdf_bytes(page)
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
