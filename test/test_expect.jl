# T6: retrying assertions over frame.expect.
#
# Hermetic half. What the driver *does* with each expression is the smoke
# suite's business; what matters here is that the right protocol frame goes out
# and that a failure reply is turned into an AssertionFailure carrying both the
# expected and the received value (SC 7).
#
# The expression strings and the error shape below are not guesses — they were
# probed against the live 1.61.1 driver before this was written, and the
# findings are recorded under T6 in tasks/plan.md.

using Playwright: Not, retry_until

"An `expect` failure exactly as the driver sends it, received value included."
expect_failure_reply(fake, id; received = Dict("s" => "Hello"), extra...) = driver_send(
    fake,
    Dict(
        "id" => id,
        "error" => Dict(
            "error" => Dict(
                "message" => "Expect failed",
                "name" => "ExpectError",
                "stack" => "ExpectError: Expect failed",
            ),
        ),
        "log" => ["  - Expect \"to.have.text\" with timeout 1000ms"],
        "errorDetails" => merge(
            Dict{String,Any}("received" => Dict("value" => received), "timedOut" => true),
            Dict{String,Any}(String(k) => v for (k, v) in extra),
        ),
    ),
)

@testset "expect" begin
    @testset "to_have_text sends the probed expression and payload" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        loc = Playwright.locator(f.frame, "#title")

        sent = waiting_request(f.fake, () -> expect(loc; to_have_text = "Hello"))
        @test sent["guid"] == "frame@1"
        @test sent["method"] == "expect"
        @test sent["params"]["expression"] == "to.have.text"
        @test sent["params"]["selector"] == "#title"
        @test sent["params"]["expectedText"] == [Dict("string" => "Hello")]
        @test sent["params"]["isNot"] == false
        @test sent["params"]["timeout"] == 2_000
        close(f.fake.connection)
    end

    @testset "each matcher maps to its probed expression" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#el")
        cases = [
            ((; to_have_text = "x"), "to.have.text"),
            ((; to_have_count = 3), "to.have.count"),
            ((; to_be_visible = true), "to.be.visible"),
            ((; to_be_hidden = true), "to.be.hidden"),
            ((; to_have_value = "v"), "to.have.value"),
            ((; to_have_attribute = "href" => "/x"), "to.have.attribute.value"),
        ]
        for (kwargs, expression) in cases
            sent = waiting_request(f.fake, () -> expect(loc; kwargs...))
            @test sent["params"]["expression"] == expression
        end
        close(f.fake.connection)
    end

    @testset "count goes out as a number, not as text" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "li")
        sent = waiting_request(f.fake, () -> expect(loc; to_have_count = 3))
        @test sent["params"]["expectedNumber"] == 3
        @test !haskey(sent["params"], "expectedText")
        close(f.fake.connection)
    end

    @testset "an attribute assertion carries its name in expressionArg" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#link")
        sent = waiting_request(
            f.fake,
            () -> expect(loc; to_have_attribute = "href" => "/somewhere"),
        )
        @test sent["params"]["expressionArg"] == "href"
        @test sent["params"]["expectedText"] == [Dict("string" => "/somewhere")]
        close(f.fake.connection)
    end

    @testset "a Regex expectation goes out as a regex, not as a literal string" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#title")
        sent = waiting_request(f.fake, () -> expect(loc; to_have_text = r"Hel+o"i))
        expected = sent["params"]["expectedText"][1]
        @test expected["regexSource"] == "Hel+o"
        @test occursin("i", expected["regexFlags"])
        @test !haskey(expected, "string")
        close(f.fake.connection)
    end

    @testset "Not(...) sets isNot on that matcher" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#title")
        sent = waiting_request(f.fake, () -> expect(loc; to_have_text = Not("Goodbye")))
        @test sent["params"]["isNot"] == true
        @test sent["params"]["expectedText"] == [Dict("string" => "Goodbye")]
        close(f.fake.connection)
    end

    @testset "Not applies per matcher, not to the whole call" begin
        # This is why negation is a wrapper rather than a `negate` keyword:
        # each matcher is its own protocol call and can differ.
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#title")
        sent = Vector{Any}()
        task = @async expect(loc; to_have_count = 1, to_have_text = Not("old"))
        for _ = 1:2
            @test timedwait(() -> isready(f.fake.client_messages), 10.0) === :ok
            msg = take!(f.fake.client_messages)
            push!(sent, msg)
            reply_ok(f.fake, msg["id"], Dict{String,Any}())
        end
        fetch(task)
        by_expr = Dict(m["params"]["expression"] => m["params"]["isNot"] for m in sent)
        @test by_expr["to.have.count"] == false
        @test by_expr["to.have.text"] == true
        close(f.fake.connection)
    end

    @testset "to_be_visible = false is the same as to_be_hidden" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#el")
        sent = waiting_request(f.fake, () -> expect(loc; to_be_visible = false))
        @test sent["params"]["expression"] == "to.be.visible"
        @test sent["params"]["isNot"] == true
        close(f.fake.connection)
    end

    @testset "a passing assertion returns the locator, so calls chain" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#title")
        task = @async expect(loc; to_have_text = "Hello")
        msg = take!(f.fake.client_messages)
        reply_ok(f.fake, msg["id"], Dict{String,Any}())
        @test fetch(task) === loc
        close(f.fake.connection)
    end

    @testset "a failure raises AssertionFailure carrying expected AND received" begin
        # SC 7. The received value comes from the errorDetails the driver sends
        # alongside the error, decoded through the ordinary value codec.
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#title")
        task = @async expect(loc; to_have_text = "Goodbye")
        msg = take!(f.fake.client_messages)
        expect_failure_reply(f.fake, msg["id"]; received = Dict("s" => "Hello"))

        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.result : e
        end
        @test err isa Playwright.AssertionFailure
        @test err isa PlaywrightError
        @test occursin("Goodbye", err.message)   # expected
        @test occursin("Hello", err.message)     # received
        @test occursin("#title", err.message)    # and which locator
        close(f.fake.connection)
    end

    @testset "a numeric received value is decoded as a number" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "li")
        task = @async expect(loc; to_have_count = 99)
        msg = take!(f.fake.client_messages)
        expect_failure_reply(f.fake, msg["id"]; received = Dict("n" => 2))
        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.result : e
        end
        @test err isa Playwright.AssertionFailure
        @test occursin("99", err.message)
        @test occursin("2", err.message)
        close(f.fake.connection)
    end

    @testset "a missing element says so rather than reporting `undefined`" begin
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#nope")
        task = @async expect(loc; to_be_visible = true)
        msg = take!(f.fake.client_messages)
        expect_failure_reply(
            f.fake,
            msg["id"];
            received = Dict("v" => "undefined"),
            customErrorMessage = "element(s) not found",
        )
        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.result : e
        end
        @test err isa Playwright.AssertionFailure
        @test occursin("element(s) not found", err.message)
        close(f.fake.connection)
    end

    @testset "expect rejects a matcher it does not know" begin
        # A bogus expression fails identically to a real mismatch on the wire
        # (probed), so a typo has to be caught here or not at all.
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#title")
        @test_throws ArgumentError expect(loc; to_have_texture = "Hello")
        # ...and asking for nothing at all is a mistake worth naming too.
        @test_throws ArgumentError expect(loc)
        close(f.fake.connection)
    end

    @testset "an explicit timeout beats the cascade" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        loc = Playwright.locator(f.frame, "#title")
        sent = waiting_request(
            f.fake,
            () -> expect(loc; to_have_text = "Hello", timeout = 250),
        )
        @test sent["params"]["timeout"] == 250
        close(f.fake.connection)
    end

    @testset "errorDetails does not disturb ordinary errors" begin
        # Threading errorDetails through must leave every other error alone —
        # a reply without it still classifies exactly as before.
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "#title")
        task = @async text_content(loc)
        msg = take!(f.fake.client_messages)
        reply_error(f.fake, msg["id"], "something else went wrong")
        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.result : e
        end
        @test err isa Playwright.DriverError
        @test !(err isa Playwright.AssertionFailure)
        close(f.fake.connection)
    end

    @testset "retry_until returns once the condition holds" begin
        n = Ref(0)
        @test retry_until(() -> (n[] += 1) >= 3; timeout = 2_000, interval = 10) === true
        @test n[] >= 3
    end

    @testset "retry_until raises AssertionFailure when it never holds" begin
        err = try
            retry_until(() -> false; timeout = 200, interval = 10)
            nothing
        catch e
            e
        end
        @test err isa Playwright.AssertionFailure
        @test occursin("200", err.message)
    end

    @testset "retry_until propagates an exception from the condition" begin
        # A predicate that throws is a broken test, not a condition that has
        # not happened yet — retrying it would hide the bug for the timeout.
        @test_throws ErrorException retry_until(() -> error("broken"); timeout = 1_000)
    end
end

# --- T8: document-level assertions (SPEC-M4.md B6, D2) --------------------
#
# The selector and expression strings are not guesses. Probed against the live
# 1.61.1 driver on both engines (T1, tasks/m4-probe.md): the selector for a
# document-level assertion is the **empty string**, and ":root" or "html" fail
# with the same generic ExpectFailure a real mismatch produces.

@testset "expect on a document" begin
    @testset "to_have_title goes out with the probed selector and expression" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)

        sent = waiting_request(f.fake, () -> expect(f.page; to_have_title = "Dashboard"))
        # It runs against the page's main frame...
        @test sent["guid"] == "frame@1"
        @test sent["method"] == "expect"
        @test sent["params"]["expression"] == "to.have.title"
        # ...with the empty selector. This is the probed value, and the one
        # thing here that cannot be guessed from the yml.
        @test sent["params"]["selector"] == ""
        @test sent["params"]["expectedText"] == [Dict("string" => "Dashboard")]
        @test sent["params"]["isNot"] == false
        @test sent["params"]["timeout"] == 2_000
        close(f.fake.connection)
    end

    @testset "to_have_url does the same with its own expression" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> expect(f.page; to_have_url = "https://example.com/x"),
        )
        @test sent["params"]["expression"] == "to.have.url"
        @test sent["params"]["selector"] == ""
        @test sent["params"]["expectedText"] == [Dict("string" => "https://example.com/x")]
        close(f.fake.connection)
    end

    @testset "a Regex expectation works, as it does for locators" begin
        f = timeout_fixture()
        sent = waiting_request(f.fake, () -> expect(f.page; to_have_url = r"m4\.html$"))
        expected = sent["params"]["expectedText"][1]
        @test expected["regexSource"] == "m4\\.html\$"
        @test !haskey(expected, "string")
        close(f.fake.connection)
    end

    @testset "expect(::Frame) works directly, and on a child frame" begin
        f = timeout_fixture()
        sent = waiting_request(f.fake, () -> expect(f.childframe; to_have_title = "child"))
        @test sent["guid"] == "childframe@1"
        @test sent["params"]["selector"] == ""
        close(f.fake.connection)
    end

    @testset "a passing assertion returns its target, so calls chain" begin
        f = timeout_fixture()
        task = @async expect(f.page; to_have_title = "Dashboard")
        msg = take!(f.fake.client_messages)
        reply_ok(f.fake, msg["id"], Dict{String,Any}())
        @test fetch(task) === f.page
        close(f.fake.connection)
    end

    @testset "several matchers in one call are each checked" begin
        f = timeout_fixture()
        sent = Vector{Any}()
        task = @async expect(f.page; to_have_title = "Dashboard", to_have_url = r"dash")
        for _ = 1:2
            @test timedwait(() -> isready(f.fake.client_messages), 10.0) === :ok
            msg = take!(f.fake.client_messages)
            push!(sent, msg)
            reply_ok(f.fake, msg["id"], Dict{String,Any}())
        end
        fetch(task)
        @test Set(m["params"]["expression"] for m in sent) ==
              Set(["to.have.title", "to.have.url"])
        close(f.fake.connection)
    end

    @testset "a failure carries the received value and names the target" begin
        f = timeout_fixture()
        task = @async expect(f.page; to_have_title = "Wrong")
        msg = take!(f.fake.client_messages)
        expect_failure_reply(f.fake, msg["id"]; received = Dict("s" => "Dashboard"))
        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.result : e
        end
        @test err isa Playwright.AssertionFailure
        @test occursin("Wrong", err.message)          # expected
        @test occursin("Dashboard", err.message)             # received
        @test occursin("to_have_title", err.message)  # which matcher
        # ...and it says *page*, not locator("") — an empty selector in an
        # error message reads like a bug in the package.
        @test occursin("page", lowercase(err.message))
        @test !occursin("locator(\"\")", err.message)
        close(f.fake.connection)
    end

    @testset "matchers stay type-partitioned, both ways" begin
        # SC 6. A document matcher on a Locator, or an element matcher on a
        # Page, is a mistake worth catching here — sent to the driver it would
        # come back as the same generic "Expect failed" a real mismatch gives.
        f = timeout_fixture()
        loc = Playwright.locator(f.frame, "h1")

        err = try
            expect(f.page; to_have_text = "nope")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("to_have_text", err.msg)
        # The message has to point at the right target, not merely refuse.
        @test occursin("Locator", err.msg)
        @test occursin("to_have_title", err.msg)   # ...and list what does work

        err2 = try
            expect(loc; to_have_title = "nope")
            nothing
        catch e
            e
        end
        @test err2 isa ArgumentError
        @test occursin("to_have_title", err2.msg)
        @test occursin("page", lowercase(err2.msg))

        # Nothing reached the driver in either direction.
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end

    @testset "an unknown matcher is refused, and lists the document matchers" begin
        f = timeout_fixture()
        err = try
            expect(f.page; to_have_titel = "typo")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("to_have_title", err.msg)
        close(f.fake.connection)
    end

    @testset "expect with no matcher at all is refused" begin
        f = timeout_fixture()
        @test_throws ArgumentError expect(f.page)
        close(f.fake.connection)
    end

    @testset "Not negates a document matcher too" begin
        f = timeout_fixture()
        sent = waiting_request(f.fake, () -> expect(f.page; to_have_title = Not("Wrong")))
        @test sent["params"]["isNot"] == true
        @test sent["params"]["expectedText"] == [Dict("string" => "Wrong")]
        close(f.fake.connection)
    end
end

# --- T2: retry_until's three knobs (SPEC-M4.md B1-B3, D5) -----------------
#
# All hermetic: the predicates are pure Julia, so none of this needs a driver.
# Every default is the M3 behaviour, and the tests above still pass unchanged —
# that is the "purely additive" claim, asserted rather than asserted-to.

"""
A testset that keeps its results instead of reporting them, so a test can
assert on what stdlib `Test` *recorded* — the difference between a `Fail` and
an `Error` is the whole of SC 7, and it cannot be seen from inside a normal
testset.
"""
struct RecordingTestSet <: Test.AbstractTestSet
    description::String
    results::Vector{Any}
end
RecordingTestSet(description) = RecordingTestSet(description, [])
Test.record(ts::RecordingTestSet, result) = (push!(ts.results, result); result)
Test.finish(ts::RecordingTestSet) = ts

@testset "retry_until knobs" begin
    @testset "on_timeout = :false returns false instead of raising" begin
        # B1. The whole point: a value @test can render as a Fail.
        result = retry_until(() -> false; timeout = 200, interval = 10, on_timeout = :false)
        @test result === false
    end

    @testset "on_timeout = :false still returns true when the condition holds" begin
        @test retry_until(() -> true; timeout = 200, on_timeout = :false) === true
    end

    @testset ":false and false are the same knob" begin
        # `:false` is not a Symbol — Julia parses it as the boolean `false`,
        # unlike `:throw` and `:retry`. SPEC-M4.md spells it `:false`
        # throughout, so both spellings have to work and mean one thing.
        @test :false === false
        @test retry_until(() -> false; timeout = 100, interval = 10, on_timeout = false) ===
              false
    end

    @testset "@test retry_until(…; on_timeout = :false) records a Fail, not an Error" begin
        # SC 7, asserted with a recording testset rather than eyeballed.
        #
        # Precisely what changes: stdlib Test records a *throwing* @test as a
        # Test.Error and a false one as a Test.Fail. Both fail the suite, so
        # the difference is in the report, and it is not cosmetic — an Error
        # says "this test is broken", a Fail says "this assertion did not
        # hold", which is the truth about a condition that never came. A Fail
        # also renders the expression and its value; an Error renders a
        # stacktrace into the package internals.
        recorded = @testset RecordingTestSet "recording" begin
            @test retry_until(() -> false; timeout = 200, interval = 10, on_timeout = :false)
            @test true          # the testset carries on to the next assertion
        end
        results = recorded.results
        @test length(results) == 2
        @test results[1] isa Test.Fail
        @test !(results[1] isa Test.Error)
        @test results[2] isa Test.Pass

        # ...and the M3 default is the Error case, which is what B1 reported.
        under_default = @testset RecordingTestSet "recording" begin
            @test retry_until(() -> false; timeout = 200, interval = 10)
        end
        @test under_default.results[1] isa Test.Error
    end

    @testset "on_error = :retry treats a throwing predicate as 'not yet'" begin
        # B3: the HTTP-against-a-warming-server shape.
        n = Ref(0)
        ok = retry_until(; timeout = 2_000, interval = 10, on_error = :retry) do
            n[] += 1
            n[] < 3 && error("still warming up")
            return true
        end
        @test ok === true
        @test n[] == 3
    end

    @testset "on_error = :throw (the default) propagates the first exception" begin
        n = Ref(0)
        err = try
            retry_until(; timeout = 2_000, interval = 10) do
                n[] += 1
                error("broken")
            end
            nothing
        catch e
            e
        end
        @test err isa ErrorException
        @test occursin("broken", err.msg)
        @test n[] == 1          # it really did not retry
    end

    @testset "a predicate that always throws under :retry times out, saying why" begin
        # Deliberate silence has to stay bounded: the retry must not swallow
        # the reason. The *last* exception rides along on the timeout.
        err = try
            retry_until(; timeout = 200, interval = 10, on_error = :retry) do
                error("connection refused")
            end
            nothing
        catch e
            e
        end
        @test err isa Playwright.AssertionFailure
        @test occursin("200", err.message)
        @test occursin("connection refused", err.message)
    end

    @testset "the two knobs compose in all four corners" begin
        never = () -> false
        always_throws = () -> error("nope")

        # :throw × :throw — the M3 behaviour, unchanged
        @test_throws Playwright.AssertionFailure retry_until(
            never;
            timeout = 100,
            interval = 10,
        )
        @test_throws ErrorException retry_until(always_throws; timeout = 100, interval = 10)

        # :false × :throw — a timeout is a value, a predicate bug is still loud
        @test retry_until(never; timeout = 100, interval = 10, on_timeout = :false) ===
              false
        @test_throws ErrorException retry_until(
            always_throws;
            timeout = 100,
            interval = 10,
            on_timeout = :false,
        )

        # :throw × :retry
        @test_throws Playwright.AssertionFailure retry_until(
            always_throws;
            timeout = 100,
            interval = 10,
            on_error = :retry,
        )

        # :false × :retry — nothing escapes at all
        @test retry_until(
            always_throws;
            timeout = 100,
            interval = 10,
            on_timeout = :false,
            on_error = :retry,
        ) === false
    end

    @testset "a typo'd knob is an ArgumentError listing the valid values" begin
        # The closed-set discipline MATCHERS already uses: `:allways` must not
        # silently mean "never".
        err = try
            retry_until(() -> true; on_timeout = :bogus)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("on_timeout", err.msg)
        @test occursin(":throw", err.msg)
        @test occursin(":false", err.msg)

        err2 = try
            retry_until(() -> true; on_error = :bogus)
            nothing
        catch e
            e
        end
        @test err2 isa ArgumentError
        @test occursin("on_error", err2.msg)
        @test occursin(":retry", err2.msg)
    end

    @testset "the target form joins the timeout cascade" begin
        # B2. Under M3 this fell back to DEFAULT_TIMEOUT regardless.
        f = timeout_fixture()
        set_default_timeout!(f.page, 300)

        elapsed = @elapsed @test retry_until(
            () -> false,
            f.page;
            interval = 10,
            on_timeout = :false,
        ) === false
        # SC 8: it honoured 300ms, not the 30s package default.
        @test elapsed < 5.0

        err = try
            retry_until(() -> false, f.page; interval = 10)
            nothing
        catch e
            e
        end
        @test err isa Playwright.AssertionFailure
        @test occursin("300", err.message)

        # ...and an explicit keyword still wins over the setting
        err2 = try
            retry_until(() -> false, f.page; timeout = 150, interval = 10)
            nothing
        catch e
            e
        end
        @test occursin("150", err2.message)

        # A context works as a target too, and a frame resolves through it.
        set_default_timeout!(f.context2, 250)
        err3 = try
            retry_until(() -> false, f.context2; interval = 10)
            nothing
        catch e
            e
        end
        @test occursin("250", err3.message)

        close(f.fake.connection)
    end

    @testset "the target form still takes a do-block" begin
        f = timeout_fixture()
        set_default_timeout!(f.page, 300)
        @test retry_until(f.page; interval = 10, on_timeout = :false) do
            false
        end === false
        close(f.fake.connection)
    end
end
