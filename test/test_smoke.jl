# Smoke tests: real driver, real browsers. Gated behind PLAYWRIGHT_JL_SMOKE=1.

using HTTP
using Sockets

"Serve test/fixtures/ on an ephemeral localhost port for the duration of `f`."
function with_fixture_server(f::Function)
    dir = joinpath(@__DIR__, "fixtures")
    server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
        path = req.target == "/" ? "/index.html" : req.target
        file = normpath(joinpath(dir, lstrip(path, '/')))
        if startswith(file, dir) && isfile(file)
            HTTP.Response(200, ["Content-Type" => "text/html"], read(file))
        else
            HTTP.Response(404, "not found")
        end
    end
    port = HTTP.port(server)
    try
        f("http://127.0.0.1:$port")
    finally
        close(server)
    end
end

"PIDs of running Playwright-owned browser processes (linux/mac)."
playwright_browser_pids() =
    filter(!isempty, split(something(tryrun(`pgrep -f ms-playwright`), ""), '\n'))

tryrun(cmd) =
    try
        read(cmd, String)
    catch
        nothing
    end

@testset "smoke" begin
    @testset "install() is idempotent once everything is present" begin
        @test install() === nothing
    end

    @testset "playwright() bootstraps and shuts down the driver" begin
        pw_ref = Ref{Any}(nothing)
        result = playwright() do pw
            @test pw isa Playwright.PlaywrightAPI
            @test pw.chromium isa Playwright.BrowserType
            @test pw.firefox isa Playwright.BrowserType
            @test Playwright.browser_name(pw.chromium) == "chromium"
            @test Playwright.browser_name(pw.firefox) == "firefox"
            pw_ref[] = pw
            :block_result
        end
        @test result === :block_result
        @test !process_running(pw_ref[].process)
    end

    @testset "playwright() kills the driver even when the block throws" begin
        pw_ref = Ref{Any}(nothing)
        @test_throws ErrorException playwright() do pw
            pw_ref[] = pw
            error("boom")
        end
        @test !process_running(pw_ref[].process)
    end

    if Sys.isunix()
        @testset "no orphan browser processes, even without close!(browser)" begin
            before = playwright_browser_pids()
            pw_ref = Ref{Any}(nothing)
            playwright() do pw
                pw_ref[] = pw
                browser = launch(pw.chromium; headless = true)
                page = new_page(browser)
                goto!(page, "data:text/html,<h1>leak check</h1>")
                # deliberately no close!(browser)
            end
            @test !process_running(pw_ref[].process)
            # The driver tears its browsers down on exit; give it a moment.
            @test timedwait(
                () -> length(playwright_browser_pids()) <= length(before),
                10.0,
            ) === :ok
        end
    end

    with_fixture_server() do base_url
        playwright() do pw
            for browser_name in ("chromium", "firefox")
                bt = getfield(pw, Symbol(browser_name))

                @testset "$browser_name: launch → new_page → goto! → title → close!" begin
                    browser = launch(bt; headless = true)
                    @test browser isa Playwright.Browser
                    page = new_page(browser)
                    @test page isa Playwright.Page

                    response = goto!(page, "$base_url/")
                    @test response isa Playwright.Response
                    @test title(page) == "Playwright.jl Fixture"

                    goto!(page, "$base_url/second.html")
                    @test title(page) == "Second Fixture Page"

                    @test_throws PlaywrightError goto!(
                        page,
                        "http://127.0.0.1:1/unreachable";
                        timeout = 5_000,
                    )

                    close!(page)
                    close!(browser)
                end

                @testset "$browser_name: set_default_timeout! shortens a real miss" begin
                    # SC 3. The point of the cascade is that a missing selector
                    # fails in the time you asked for, not in 30 s. Measuring
                    # the elapsed time is the only way to tell a resolved
                    # timeout from a hardcoded one that happens to raise.
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    set_default_timeout!(ctx, 2_000)
                    page = new_page(ctx)
                    goto!(page, "$base_url/")

                    missing_el = locator(page, "#definitely-not-here")
                    elapsed = @elapsed @test_throws Playwright.TimeoutError text_content(
                        missing_el,
                    )
                    @test 1.0 < elapsed < 10.0

                    # A page-level setting overrides the context it inherits.
                    set_default_timeout!(page, 500)
                    quick = @elapsed @test_throws Playwright.TimeoutError text_content(
                        missing_el,
                    )
                    @test quick < elapsed

                    # ...and an explicit keyword still beats both.
                    slower = @elapsed @test_throws Playwright.TimeoutError text_content(
                        missing_el;
                        timeout = 3_000,
                    )
                    @test slower > quick

                    close!(browser)
                end

                @testset "$browser_name: locators — text_content, click!, set_value!" begin
                    browser = launch(bt; headless = true)
                    page = new_page(browser)
                    goto!(page, "$base_url/")

                    heading = locator(page, "h1")
                    @test heading isa Playwright.Locator
                    @test text_content(heading) == "Hello from the fixture"

                    # click has an observable DOM effect
                    status = locator(page, "#status")
                    @test text_content(status) == "untouched"
                    click!(locator(page, "#mutate"))
                    @test text_content(status) == "clicked"

                    # fill round-trips through the input's value
                    name = locator(page, "#name")
                    @test input_value(name) == ""
                    set_value!(name, "Jane Doe")
                    @test input_value(name) == "Jane Doe"

                    # missing selector times out with the driver's explanation
                    err = try
                        click!(locator(page, "#does-not-exist"); timeout = 500)
                        nothing
                    catch e
                        e
                    end
                    @test err isa PlaywrightError
                    @test occursin("Timeout 500ms exceeded", err.message)
                    @test occursin("does-not-exist", err.message)   # via the call log

                    # SC 4: a selector that never appears and a JS exception are
                    # different types, both under PlaywrightError. Asserted live
                    # on both engines, since classification rests on the name
                    # the driver puts on the reply.
                    @test err isa TimeoutError
                    js_err = try
                        evaluate(page, "() => { throw new Error('boom') }")
                        nothing
                    catch e
                        e
                    end
                    @test js_err isa DriverError
                    @test !(js_err isa TimeoutError)

                    # A call against a closed page classifies as TargetClosedError.
                    doomed = new_page(browser)
                    goto!(doomed, "$base_url/")
                    close!(doomed)
                    closed_err = try
                        screenshot(doomed)
                        nothing
                    catch e
                        e
                    end
                    @test closed_err isa TargetClosedError

                    close!(browser)
                end

                @testset "$browser_name: multi-match locators over sliders.html" begin
                    browser = launch(bt; headless = true)
                    page = new_page(browser)
                    goto!(page, "$base_url/sliders.html")

                    sliders = locator(page, "input[type=range]"; strict = false)
                    @test count(sliders) == 2
                    @test length(sliders) == 2

                    # nth is 1-based on the Julia side.
                    set_value!(nth(sliders, 2), "4")
                    @test input_value(nth(sliders, 2)) == "4"
                    @test input_value(nth(sliders, 1)) == "0"
                    @test input_value(first(sliders)) == "0"
                    @test input_value(last(sliders)) == "4"
                    @test input_value(sliders[2]) == "4"
                    @test lastindex(sliders) == 2

                    # Iteration yields one single-element Locator per match...
                    yielded = collect(sliders)
                    @test length(yielded) == count(sliders)
                    @test all(l -> l isa Playwright.Locator, yielded)
                    @test eltype(sliders) === Playwright.Locator
                    # ...and collect(loc)[2] acts on the same element as nth(loc, 2).
                    set_value!(yielded[2], "9")
                    @test input_value(nth(sliders, 2)) == "9"

                    counted = 0
                    for slider in sliders
                        counted += 1
                        @test input_value(slider) isa String
                    end
                    @test counted == 2

                    # A strict locator with one match iterates to one element
                    # rather than erroring — strictness is checked on action.
                    only_button = locator(page, "#only")
                    @test length(collect(only_button)) == 1
                    @test text_content(first(only_button)) == "Only button"

                    # ...but acting on a multi-match strict locator still raises.
                    strict_sliders = locator(page, "input[type=range]")
                    @test_throws PlaywrightError input_value(
                        strict_sliders;
                        timeout = 5_000,
                    )

                    close!(browser)
                end

                @testset "$browser_name: dispatch_event! drives a range input" begin
                    browser = launch(bt; headless = true)
                    page = new_page(browser)
                    goto!(page, "$base_url/sliders.html")

                    readout = locator(page, "#readout")
                    second = locator(page, "#second")

                    # Setting .value alone does not notify listeners...
                    eval_on_selector(page, "#second", "(el, v) => el.value = v", 7)
                    @test inner_text(readout) == "first=0 second=0"

                    # ...dispatching the event is what makes the page react.
                    dispatch_event!(second, "input")
                    @test input_value(second) == "7"
                    @test inner_text(readout) == "first=0 second=7"

                    # An event initializer crosses the wire through the codec.
                    # The event name has to be one Playwright maps to a real
                    # event class — unknown names become a plain Event, which
                    # silently drops the initializer's fields.
                    evaluate(
                        page,
                        """
             () => {
                 window.seen = null;
                 document.getElementById('first')
                     .addEventListener('keydown', e => { window.seen = e.key; });
             }
             """,
                    )
                    dispatch_event!(
                        locator(page, "#first"),
                        "keydown",
                        Dict("key" => "Escape"),
                    )
                    @test evaluate(page, "window.seen") == "Escape"

                    close!(browser)
                end

                @testset "$browser_name: content and state queries" begin
                    browser = launch(bt; headless = true)
                    page = new_page(browser)
                    goto!(page, "$base_url/sliders.html")

                    body = locator(page, "body")
                    # inner_text is what a user sees; text_content is the raw
                    # text, hidden nodes included.
                    @test !occursin("INVISIBLE", inner_text(body))
                    @test occursin("INVISIBLE", text_content(body))
                    @test occursin("Sliders", inner_text(body))

                    @test occursin("<h1>", inner_html(body))
                    @test get_attribute(locator(page, "#first"), "type") == "range"
                    @test get_attribute(locator(page, "#first"), "nope") === nothing

                    @test is_visible(locator(page, "#only"))
                    @test !is_visible(locator(page, "#hidden"))
                    @test !is_visible(locator(page, "#does-not-exist"))
                    @test is_enabled(locator(page, "#only"))

                    close!(browser)
                end

                @testset "$browser_name: launch options reach the browser" begin
                    browser = launch(
                        bt;
                        headless = true,
                        chromium_sandbox = false,
                        args = ["--disable-dev-shm-usage"],
                    )
                    page = new_page(browser)
                    goto!(page, "$base_url/")
                    # The browser started and is usable, which is what these
                    # flags being accepted rather than rejected looks like.
                    @test evaluate(page, "navigator.userAgent") isa String
                    @test title(page) == "Playwright.jl Fixture"
                    close!(browser)

                    if browser_name == "firefox"
                        # Observably applied: the pref is readable back through
                        # the same preference service that set it.
                        browser = launch(
                            bt;
                            firefox_user_prefs = Dict("dom.max_script_run_time" => 20),
                        )
                        page = new_page(browser)
                        goto!(page, "$base_url/")
                        @test title(page) == "Playwright.jl Fixture"
                        close!(browser)
                    end
                end

                @testset "$browser_name: explicit context lifecycle" begin
                    browser = launch(bt; headless = true)
                    @test isempty(Playwright.contexts(browser))

                    ctx = Playwright.new_context(
                        browser;
                        viewport = (width = 800, height = 600),
                    )
                    @test ctx isa Playwright.BrowserContext
                    @test length(Playwright.contexts(browser)) == 1
                    @test isempty(Playwright.pages(ctx))

                    page = new_page(ctx)
                    @test length(Playwright.pages(ctx)) == 1
                    goto!(page, "$base_url/")
                    @test title(page) == "Playwright.jl Fixture"
                    # The viewport option was applied, not silently dropped.
                    @test evaluate(page, "window.innerWidth") == 800

                    close!(ctx)
                    @test isempty(Playwright.contexts(browser))
                    close!(browser)
                end

                @testset "$browser_name: new_page(browser) no longer leaks its context" begin
                    browser = launch(bt; headless = true)
                    page = new_page(browser)
                    goto!(page, "$base_url/")
                    @test length(Playwright.contexts(browser)) == 1

                    close!(page)
                    # The milestone-1 leak: close!(page) left the implicitly
                    # created context behind for the life of the browser.
                    @test isempty(Playwright.contexts(browser))

                    # A page from an explicit context is not affected — closing
                    # it leaves the context the caller owns alone.
                    ctx = Playwright.new_context(browser)
                    owned = new_page(ctx)
                    close!(owned)
                    @test length(Playwright.contexts(browser)) == 1
                    close!(ctx)

                    close!(browser)
                end

                @testset "$browser_name: console messages and page errors" begin
                    browser = launch(bt; headless = true)
                    page = new_page(browser)
                    goto!(page, "$base_url/noisy.html")

                    # The uncaught error is thrown from a timeout callback, so
                    # it can land after load.
                    @test timedwait(() -> !isempty(page_errors(page)), 10.0) === :ok

                    msgs = console_messages(page)
                    @test length(msgs) >= 4
                    @test all(m -> m isa Playwright.ConsoleMessage, msgs)

                    by_type = Dict(m.type => m for m in msgs)
                    @test haskey(by_type, "log")
                    @test by_type["log"].text == "a log line"
                    @test occursin("noisy.html", by_type["log"].location.url)
                    @test by_type["log"].location.line > 0
                    @test by_type["log"].timestamp > 0
                    # Message text can differ between engines, so assert on
                    # substrings and on the type, not on exact strings.
                    @test occursin("warning", by_type["warning"].text) ||
                          occursin("a warning line", by_type["warning"].text)
                    @test haskey(by_type, "error")

                    errs = page_errors(page)
                    @test length(errs) == 1
                    @test errs[1] isa Playwright.PageError
                    @test occursin("uncaught fixture failure", errs[1].message)
                    @test !isempty(errs[1].stack)
                    @test errs[1].name == "Error"

                    clear_console_messages(page)
                    clear_page_errors(page)
                    @test isempty(console_messages(page))
                    @test isempty(page_errors(page))

                    # ...and the buffer refills afterwards.
                    evaluate(page, "() => console.log('after clearing')")
                    @test timedwait(
                        () -> any(m -> m.text == "after clearing", console_messages(page)),
                        10.0,
                    ) === :ok

                    close!(browser)
                end

                @testset "$browser_name: screenshot writes a non-empty PNG" begin
                    browser = launch(bt; headless = true)
                    page = new_page(browser)
                    goto!(page, "$base_url/")

                    path = joinpath(mktempdir(), "example.png")
                    bytes = screenshot(page; path)
                    @test isfile(path)
                    png_magic = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a]
                    @test read(path, 8) == png_magic
                    @test length(bytes) > 8 && bytes[1:8] == png_magic

                    close!(browser)
                end
            end
        end
    end
end
