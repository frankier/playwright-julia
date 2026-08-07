# T11: calls on a closed page must raise TargetClosedError.
#
# Hermetic — a canned __dispose__ trace stands in for the browser. The bug this
# guards against is not "the call fails" but "the call fails with a *Julia*
# error": a TypeError from the `::Frame` assertion in main_frame, which no
# caller can reasonably catch, tells you nothing about what went wrong.

@testset "closed targets" begin
    """
    Close the page the way the driver really does: dispose the page and
    *nothing else*.

    Probed on both engines — a page close leaves its main frame registered,
    because the driver parents a main frame to the browser context rather than
    to the page. A fixture that disposes the context instead would take the
    frame with it and hide the case that matters, since `locator(page, …)` does
    no round-trip and so has only the registry to go on.
    """
    function close_page!(f)
        send_dispose(f.fake, "page@1")
        @test timedwait(
            () -> Playwright.lookup_object(f.fake.connection, "page@1") === nothing,
            5.0,
        ) === :ok
        # The main frame is still there. That is the point.
        @test Playwright.lookup_object(f.fake.connection, "frame@1") !== nothing
        return f
    end

    "Close the whole context, which cascades to the pages beneath it."
    function close_context!(f)
        send_dispose(f.fake, "context@1")
        @test timedwait(
            () -> Playwright.lookup_object(f.fake.connection, "frame@1") === nothing,
            5.0,
        ) === :ok
        return f
    end

    @testset "main_frame on a closed page raises TargetClosedError" begin
        f = close_page!(timeout_fixture())
        err = try
            Playwright.main_frame(f.page)
            nothing
        catch e
            e
        end
        @test err isa Playwright.TargetClosedError
        @test err isa PlaywrightError
        # The regression: it used to be a Julia TypeError from the ::Frame
        # assertion, which is neither catchable as a Playwright error nor
        # informative about the cause.
        @test !(err isa TypeError)
        close(f.fake.connection)
    end

    @testset "every page entry point that hops through main_frame agrees" begin
        # These all funnel through main_frame, so one guard covers the lot —
        # but the point of listing them is that the *user-facing* calls behave,
        # not merely the helper they share.
        for call in (
            page -> title(page),
            page -> goto!(page, "about:blank"),
            page -> evaluate(page, "1 + 1"),
            page -> locator(page, "#x"),
            page -> frames(page),
            page -> frame_locator(page, "iframe"),
            page -> wait_for_selector(page, "#x"),
            page -> wait_for_function(page, "() => true"),
            page -> eval_on_selector(page, "#x", "el => el"),
        )
            f = close_page!(timeout_fixture())
            err = try
                call(f.page)
                nothing
            catch e
                e
            end
            @test err isa Playwright.TargetClosedError
            close(f.fake.connection)
        end
    end

    @testset "the message says the page closed, not that a type was wrong" begin
        f = close_page!(timeout_fixture())
        err = try
            title(f.page)
            nothing
        catch e
            e
        end
        @test occursin("close", lowercase(err.message))
        close(f.fake.connection)
    end

    @testset "a closed context is caught too, and does not become a TypeError" begin
        # Here the frame really is gone, which is what used to trip the
        # `::Frame` assertion.
        f = close_context!(timeout_fixture())
        err = try
            title(f.page)
            nothing
        catch e
            e
        end
        @test err isa Playwright.TargetClosedError
        @test !(err isa TypeError)
        close(f.fake.connection)
    end

    @testset "lazy calls raise as eagerly as round-tripping ones" begin
        # `locator` does no protocol call, so before T11 it happily handed back
        # an object for a page that no longer existed and failed confusingly
        # much later. The registry is the only thing it can consult.
        f = close_page!(timeout_fixture())
        @test_throws Playwright.TargetClosedError locator(f.page, "h1")
        close(f.fake.connection)
    end

    @testset "a live page is unaffected" begin
        f = timeout_fixture()
        @test Playwright.main_frame(f.page) === f.frame
        @test locator(f.page, "h1") isa Playwright.Locator
        close(f.fake.connection)
    end

    @testset "a sibling page is unaffected by the one that closed" begin
        f = close_page!(timeout_fixture())
        # page@2 is a different page in a different context; closing page@1
        # must not make the whole connection look shut.
        @test Playwright.lookup_object(f.fake.connection, "page@2") !== nothing
        close(f.fake.connection)
    end

    # --- T3: the postmortem readers are no-throw (SPEC-M4.md B5, D4) ------
    #
    # These live here rather than in a test_diagnostics.jl of their own
    # because the thing under test *is* the closed-target behaviour, and
    # close_page!/close_context! above are what reproduce it faithfully.
    #
    # B5 is the masked-failure bug: console_messages and page_errors are
    # exactly what a `finally` block calls, and exactly when the page may
    # already be gone. Throwing there replaces the caller's real failure with
    # a less interesting one.

    "A TargetClosedError exactly as the driver sends it."
    target_closed_reply(fake, id) = driver_send(
        fake,
        Dict(
            "id" => id,
            "error" => Dict(
                "error" => Dict(
                    "message" => "Target page, context or browser has been closed",
                    "name" => "TargetClosedError",
                    "stack" => "",
                ),
            ),
        ),
    )

    @testset "console_messages and page_errors are empty, not throwing, on a closed page" begin
        # Note this must not even round-trip: these readers do not hop through
        # main_frame, so on a disposed page there is nobody left to answer and
        # a call that went out anyway would hang rather than throw. The guard
        # is therefore *before* the send, not only a catch after it.
        f = close_page!(timeout_fixture())
        @test console_messages(f.page) == ConsoleMessage[]
        @test page_errors(f.page) == PageError[]
        # Nothing was sent.
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end

    @testset "...and on a closed context" begin
        # SC 10's shape: close the context, then read. The frame is gone here
        # too, which is the harder case.
        f = close_context!(timeout_fixture())
        @test isempty(console_messages(f.page))
        @test isempty(page_errors(f.page))
        close(f.fake.connection)
    end

    @testset "a page that closes mid-call is swallowed too" begin
        # The race the guard alone cannot cover: the page was alive when the
        # message went out and gone by the time the reply came back. This is
        # the shape B5 actually reported from a real suite.
        for reader in (console_messages, page_errors)
            f = timeout_fixture()
            task = @async reader(f.page)
            msg = take!(f.fake.client_messages)
            target_closed_reply(f.fake, msg["id"])
            @test isempty(fetch(task))
            close(f.fake.connection)
        end
    end

    @testset "the silence is bounded to TargetClosedError" begin
        # Deliberate silence is how masked failures start, so the swallow has
        # to be narrow: any *other* driver error still propagates. A live page
        # whose call fails for an unrelated reason must still say so.
        for reader in (console_messages, page_errors)
            f = timeout_fixture()
            task = @async reader(f.page)
            msg = take!(f.fake.client_messages)
            driver_send(
                f.fake,
                Dict(
                    "id" => msg["id"],
                    "error" => Dict(
                        "error" => Dict(
                            "message" => "something else went wrong",
                            "name" => "Error",
                            "stack" => "Error: something else went wrong",
                        ),
                    ),
                ),
            )
            err = try
                fetch(task)
                nothing
            catch e
                e isa TaskFailedException ? e.task.result : e
            end
            @test err isa Playwright.DriverError
            @test !(err isa Playwright.TargetClosedError)
            @test occursin("something else", err.message)
            close(f.fake.connection)
        end
    end

    @testset "a live page still reports what it has" begin
        # The swallow must not have turned the readers into stubs.
        f = timeout_fixture()
        task = @async console_messages(f.page)
        msg = take!(f.fake.client_messages)
        reply_ok(
            f.fake,
            msg["id"],
            Dict{String,Any}(
                "messages" => [
                    Dict(
                        "type" => "log",
                        "text" => "hello",
                        "location" =>
                            Dict("url" => "u", "lineNumber" => 1, "columnNumber" => 2),
                        "timestamp" => 1.0,
                    ),
                ],
            ),
        )
        msgs = fetch(task)
        @test length(msgs) == 1
        @test msgs[1].text == "hello"
        close(f.fake.connection)
    end

    @testset "screenshot still throws on a closed target" begin
        # Resolved open question 2: screenshot returns bytes, so it has no
        # natural empty answer, and it is a real action rather than a buffer
        # read. It keeps throwing; report_diagnostics (T9) catches for it.
        f = timeout_fixture()
        task = @async screenshot_bytes(f.page)
        msg = take!(f.fake.client_messages)
        target_closed_reply(f.fake, msg["id"])
        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.result : e
        end
        @test err isa Playwright.TargetClosedError
        close(f.fake.connection)
    end
end
