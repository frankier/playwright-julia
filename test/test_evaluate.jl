# Smoke tests for the evaluate slice: running JavaScript in a real browser and
# getting real values back. Runs on Chromium and Firefox.
#
# The codec itself is tested hermetically in test_serializers.jl; what is being
# proved here is the wiring — that a Julia value survives the trip out to the
# page and back, and that handles are held and released correctly.

@testset "evaluate ($(name))" for name in SMOKE_ENGINES
    with_fixture_server() do base_url
        playwright() do pw
            browser = launch(engine(pw, name))
            page = new_page(browser)
            goto!(page, "$base_url/evaluate.html")

            @testset "values out" begin
                @test evaluate(page, "1 + 1") == 2
                @test evaluate(page, "document.title") == "Evaluate fixture"
                @test evaluate(page, "document.title") isa String
                @test evaluate(page, "window.app.ready") === true
                @test evaluate(page, "window.app.name") == "fixture"
                @test evaluate(page, "undefined") === missing
                @test evaluate(page, "null") === nothing
                # Structures come back as plain Julia containers.
                @test evaluate(page, "window.app.nested") == Dict("deep" => [1.0, 2.0, 3.0])
            end

            @testset "arguments in" begin
                @test evaluate(page, "x => x.a * 2", (a = 21,)) == 42
                @test evaluate(page, "x => x.a * 2", Dict("a" => 21)) == 42
                @test evaluate(page, "xs => xs.length", [1, 2, 3]) == 3
                @test evaluate(page, "s => s.toUpperCase()", "hi") == "HI"
                # A function body is detected as such without being told.
                @test evaluate(page, "() => 7") == 7
                # ...and the detection can be overridden both ways.
                @test evaluate(page, "1 + 1"; is_function = false) == 2
            end

            @testset "throwing JS surfaces a PlaywrightError" begin
                err = try
                    evaluate(page, "() => window.boom()")
                    nothing
                catch e
                    e
                end
                @test err isa PlaywrightError
                @test occursin("fixture exploded on purpose", err.message)
            end

            @testset "handles" begin
                handle = evaluate_handle(page, "() => window.app")
                @test handle isa Playwright.JSHandle
                # A handle can be evaluated against directly...
                @test evaluate(handle, "a => a.count") == 3
                # ...and passed back into another evaluate as an argument.
                @test evaluate(page, "a => a.name", handle) == "fixture"
                dispose!(handle)
                # Once disposed it is no longer usable.
                @test_throws PlaywrightError evaluate(handle, "a => a.count")
            end

            @testset "scoped handles dispose on the way out" begin
                escaped = Ref{Any}(nothing)
                result = evaluate_handle(page, "() => window.app") do app
                    escaped[] = app
                    @test evaluate(app, "a => a.ready") === true
                    :block_result
                end
                @test result === :block_result
                @test_throws PlaywrightError evaluate(escaped[], "a => a.ready")
            end

            @testset "scoped handles dispose even when the body throws" begin
                escaped = Ref{Any}(nothing)
                @test_throws ErrorException evaluate_handle(page, "() => window.app") do app
                    escaped[] = app
                    error("body blew up")
                end
                # The handle was released despite the throw — this is the case a
                # naive implementation leaks.
                @test_throws PlaywrightError evaluate(escaped[], "a => a.ready")
            end

            @testset "eval_on_selector / eval_on_selector_all" begin
                @test eval_on_selector(page, "#one", "el => el.value") == "alpha"
                @test eval_on_selector_all(page, "input", "els => els.length") == 3
                @test eval_on_selector_all(page, "input", "els => els.map(e => e.value)") ==
                      ["alpha", "beta", "gamma"]
                # Arguments reach eval_on_selector too.
                @test eval_on_selector(
                    page,
                    "#two",
                    "(el, suffix) => el.value + suffix",
                    "!",
                ) == "beta!"
            end

            close!(browser)
        end
    end
end
