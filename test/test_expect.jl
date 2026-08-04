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
