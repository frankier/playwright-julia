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
