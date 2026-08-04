# T0 fixtures: pages exercising waiting, events and assertions.
#
# These assert the *fixtures* behave as the milestone-3 tasks assume — before the
# APIs that consume them exist. Waiting here is done driver-side with a JS promise
# rather than `sleep`, so the tests stay honest about SC 2 (no sleeping for the
# DOM) even though `wait_for_selector` is not written yet.

"Resolve once `predicate` (a JS expression string) is truthy, driver-side."
function js_wait(page, predicate; timeout_ms = 5_000)
    return evaluate(
        page,
        """
        ([pred, budget]) => new Promise((resolve, reject) => {
          const fn = new Function("return (" + pred + ")");
          const started = Date.now();
          const tick = () => {
            let ok = false;
            try { ok = fn(); } catch (e) { return reject(e); }
            if (ok) return resolve(true);
            if (Date.now() - started > budget) return reject(new Error("js_wait timed out: " + pred));
            setTimeout(tick, 20);
          };
          tick();
        })
        """,
        [predicate, timeout_ms],
    )
end

# --- T7: Locator ergonomics against real browsers -------------------------

@testset "locator ergonomics (T7)" begin
    with_fixture_server() do base_url
        playwright() do pw
            for engine in ("chromium", "firefox")
                bt = getfield(pw, Symbol(engine))

                @testset "$engine: evaluate on a Locator drives a range input" begin
                    # SC 5. A range input cannot be clicked to an exact value,
                    # so this is the case that forced private-field access
                    # before T7.
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    slider = locator(page, "#first")
                    evaluate(slider, "(el, v) => el.value = v", 7)
                    dispatch_event(slider, "input")

                    @test input_value(slider) == "7"
                    # The readout only updates if a real `input` event fired,
                    # so this proves listeners ran rather than just that the
                    # value was assigned.
                    @test text_content(locator(page, "#readout")) == "first=7 second=0"

                    close(browser)
                end

                @testset "$engine: evaluate on a Locator returns converted values" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    @test evaluate(locator(page, "h1"), "el => el.textContent") == "Hello"
                    @test evaluate(locator(page, "#first"), "el => el.max") == "10"

                    close(browser)
                end

                @testset "$engine: a strict Locator still raises on several matches" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    strict_multi = locator(page, "input[type=range]")
                    @test_throws PlaywrightError evaluate(strict_multi, "el => el.value")

                    close(browser)
                end

                @testset "$engine: evaluate_all sees every match and ignores strictness" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    sliders = locator(page, "input[type=range]"; strict = false)
                    @test evaluate_all(sliders, "els => els.length") == 2
                    @test evaluate_all(sliders, "els => els.map(e => e.id)") ==
                          ["first", "second"]

                    # ...and a locator that matches nothing gets an empty array
                    # rather than an error.
                    @test evaluate_all(
                        locator(page, ".nope"; strict = false),
                        "els => els.length",
                    ) == 0

                    close(browser)
                end

                @testset "$engine: element_handle resolves, and misses give nothing" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    handle = element_handle(locator(page, "h1"))
                    @test handle isa Playwright.ElementHandle
                    @test evaluate(handle, "el => el.textContent") == "Hello"
                    dispose(handle)

                    @test element_handle(locator(page, "#not-there")) === nothing

                    close(browser)
                end

                @testset "$engine: the public accessors describe a real locator" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    loc = locator(page, "#first")
                    @test frame(loc) === Playwright.main_frame(page)
                    @test selector(loc) == "#first"
                    @test is_strict(loc)

                    # nth folds into the selector, and the result is strict
                    second = nth(locator(page, "input[type=range]"; strict = false), 2)
                    @test occursin("nth=1", selector(second))
                    @test is_strict(second)
                    @test evaluate(second, "el => el.id") == "second"

                    close(browser)
                end
            end
        end
    end
end

# --- T5: driver-side waiting against real browsers ------------------------

@testset "waiting (T5)" begin
    with_fixture_server() do base_url
        playwright() do pw
            for engine in ("chromium", "firefox")
                bt = getfield(pw, Symbol(engine))

                @testset "$engine: wait_for_selector waits for a late element" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    # #late is appended 300ms after parse. No sleep here: the
                    # driver holds the call open until it lands (SC 2).
                    el = wait_for_selector(page, "#late")
                    @test el isa Playwright.ElementHandle
                    @test text_content(locator(page, "#late")) == "late arrival"

                    # ...and it really was late: the fixture timestamps itself,
                    # so this is deterministic rather than a race.
                    @test evaluate(page, "() => window.__lateAt > window.__parsedAt")

                    close(browser)
                end

                @testset "$engine: wait_for_selector honours state" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    @test wait_for_selector(page, "#late"; state = :visible) isa
                          Playwright.ElementHandle
                    # :hidden and :detached have no element to hand back
                    @test wait_for_selector(page, "#nope"; state = :detached) === nothing
                    @test wait_for_selector(page, "#nope"; state = :hidden) === nothing

                    close(browser)
                end

                @testset "$engine: wait_for_selector works on a Locator" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    el = wait_for_selector(locator(page, "#late"); state = :visible)
                    @test el isa Playwright.ElementHandle

                    close(browser)
                end

                @testset "$engine: a missing selector raises TimeoutError, not DriverError" begin
                    # SC 4. Branching on "is my element late?" versus "did the
                    # page break?" is the whole point of the taxonomy.
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    err = try
                        wait_for_selector(page, "#never-arrives"; timeout = 1_000)
                        nothing
                    catch e
                        e
                    end
                    @test err isa Playwright.TimeoutError
                    @test !(err isa Playwright.DriverError)

                    close(browser)
                end

                @testset "$engine: wait_for_function waits for window.ready" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    handle = wait_for_function(page, "() => window.ready === true")
                    @test handle !== nothing
                    @test evaluate(page, "() => window.__readyAt > window.__parsedAt")

                    close(browser)
                end

                @testset "$engine: wait_for_function takes an argument and a polling interval" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    wait_for_function(
                        page,
                        "since => window.__readyAt > since",
                        0;
                        polling = 25,
                    )
                    @test evaluate(page, "() => window.ready") === true

                    close(browser)
                end

                @testset "$engine: a throwing predicate raises DriverError, not TimeoutError" begin
                    # The other half of SC 4: a predicate that can never
                    # succeed must not masquerade as one that is merely late.
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    err = try
                        wait_for_function(
                            page,
                            "() => { throw new Error('predicate blew up') }";
                            timeout = 5_000,
                        )
                        nothing
                    catch e
                        e
                    end
                    @test err isa Playwright.DriverError
                    @test !(err isa Playwright.TimeoutError)
                    @test occursin("predicate blew up", err.message)

                    close(browser)
                end

                @testset "$engine: waiting timeouts come from the cascade" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    set_default_timeout!(ctx, 1_000)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    elapsed =
                        @elapsed @test_throws Playwright.TimeoutError wait_for_selector(
                            page,
                            "#never-arrives",
                        )
                    @test elapsed < 10.0

                    close(browser)
                end
            end
        end
    end
end

# --- T4: the event surface against real browsers --------------------------

@testset "events (T4)" begin
    with_fixture_server() do base_url
        playwright() do pw
            for engine in ("chromium", "firefox")
                bt = getfield(pw, Symbol(engine))

                @testset "$engine: a popup arrives as a Page" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    popup = expect_event(ctx, :page) do
                        click(locator(page, "#open-popup"))
                    end
                    @test popup isa Playwright.Page
                    @test popup !== page
                    # The popup comes back without waiting for its first
                    # navigation (OQ 4), so its content may still be loading —
                    # what must be true immediately is that it is a usable Page.
                    @test text_content(locator(popup, "#popup-heading")) == "Popup"

                    close(browser)
                end

                @testset "$engine: a synchronously-fired console event is caught" begin
                    # SC 6, the regression this fixture exists for: #shout logs
                    # inside its click handler, so the message is emitted before
                    # `click` returns. Subscribing after the click would miss it.
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3-events.html")

                    msg =
                        expect_event(ctx, :console; predicate = m -> m.text == "shouted") do
                            click(locator(page, "#shout"))
                        end
                    @test msg isa Playwright.ConsoleMessage
                    @test msg.text == "shouted"
                    @test msg.type == "log"

                    close(browser)
                end

                @testset "$engine: with_events collects a 5 000-message flood" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3-events.html")

                    floods = with_events(ctx, :console) do stream
                        click(locator(page, "#flood"))
                        js_wait(page, "window.__floodDone === true"; timeout_ms = 30_000)
                        timedwait(() -> length(stream) >= 5000, 60.0)
                        pending_events(stream)
                    end
                    texts = [m.text for m in floods if startswith(m.text, "flood ")]
                    @test length(texts) == 5000
                    @test texts[1] == "flood 0"
                    @test texts[end] == "flood 4999"

                    close(browser)
                end

                @testset "$engine: :close hands back the page that closed" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    closed = expect_event(page, :close) do
                        close(page)
                    end
                    @test closed === page

                    close(browser)
                end

                @testset "$engine: a page error arrives as a PageError" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    err = expect_event(ctx, :pageerror) do
                        # setTimeout so the throw escapes evaluate's own reply
                        # and becomes an uncaught page error.
                        evaluate(
                            page,
                            "() => setTimeout(() => { throw new Error('kaboom') }, 0)",
                        )
                    end
                    @test err isa Playwright.PageError
                    @test occursin("kaboom", err.message)

                    close(browser)
                end

                @testset "$engine: a wait that never fires raises TimeoutError" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    elapsed = @elapsed @test_throws Playwright.TimeoutError expect_event(
                        ctx,
                        :console;
                        timeout = 1_000,
                    ) do
                    end
                    @test elapsed < 10.0

                    # ...and the cascade supplies the timeout when none is given
                    set_default_timeout!(ctx, 1_000)
                    @test_throws Playwright.TimeoutError expect_event(ctx, :console) do
                    end

                    close(browser)
                end

                @testset "$engine: an unsupported event is refused, not faked" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    @test_throws ArgumentError expect_event(ctx, :request) do
                    end
                    @test_throws ArgumentError expect_event(ctx, :download) do
                    end
                    close(browser)
                end

                @testset "$engine: the registry is empty after every block" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3-events.html")
                    conn = page.connection

                    expect_event(ctx, :console) do
                        click(locator(page, "#shout"))
                    end
                    @test sum(length, values(conn.subscriptions); init = 0) == 0

                    try
                        expect_event(ctx, :console; timeout = 500) do
                        end
                    catch
                    end
                    @test sum(length, values(conn.subscriptions); init = 0) == 0

                    close(browser)
                end
            end
        end
    end
end

@testset "m3 fixtures" begin
    with_fixture_server() do base_url
        playwright() do pw
            for engine in ("chromium", "firefox")
                bt = getfield(pw, Symbol(engine))

                @testset "$engine: target.html — late element and window.ready" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3.html")

                    # The h1 the target snippet asserts on is there immediately.
                    @test text_content(locator(page, "h1")) == "Hello"

                    # #late and window.ready arrive on their own, without the
                    # test sleeping.
                    @test js_wait(page, "document.querySelector('#late') !== null")
                    @test is_visible(locator(page, "#late"))
                    @test js_wait(page, "window.ready === true")

                    # Both arrived strictly after parse — asserted from the
                    # page's own clock rather than by racing goto to observe the
                    # absence, which Firefox is slow enough to lose.
                    @test evaluate(page, "() => window.__lateAt > window.__parsedAt")
                    @test evaluate(page, "() => window.__readyAt > window.__lateAt")

                    # Two range inputs, for the evaluate-on-Locator slice.
                    @test length(locator(page, "input[type=range]"; strict = false)) == 2

                    # The popup opener the event slice drives.
                    @test is_visible(locator(page, "#open-popup"))

                    close(browser)
                end

                @testset "$engine: m3-events.html — sync and flooded console" begin
                    browser = launch(bt; headless = true)
                    ctx = new_context(browser)
                    page = new_page(ctx)
                    goto(page, "$base_url/m3-events.html")

                    # #shout logs synchronously inside its own click handler: the
                    # message must already exist by the time the handler returns.
                    @test evaluate(
                        page,
                        """
                        () => {
                          window.__shouted = false;
                          const seen = [];
                          const orig = console.log;
                          console.log = (...a) => { seen.push(a[0]); orig(...a); };
                          document.getElementById("shout").click();
                          console.log = orig;
                          return seen.includes("shouted");
                        }
                        """,
                    )

                    # The flood button emits exactly 5 000 messages on demand.
                    clear_console_messages(page)
                    evaluate(page, "() => document.getElementById('flood').click()")
                    @test js_wait(page, "window.__floodDone === true"; timeout_ms = 30_000)
                    @test evaluate(page, "() => window.__floodCount") == 5_000

                    close(browser)
                end
            end
        end
    end
end
