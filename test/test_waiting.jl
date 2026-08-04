# T5: wait_for_selector / wait_for_function. Hermetic — these assert the
# protocol frame each entry point sends, which is where an option that is
# silently dropped (or a timeout that never consulted the cascade) shows up.
# The behaviour against a real DOM is in the smoke suite.

using Playwright: wait_for_selector, wait_for_function

"""
Run `action()` against the fake, reply `result`, and return the frame it sent.

Waits for the message rather than blocking on `take!` forever: an action that
throws before sending anything (a missing method, a rejected argument) would
otherwise hang the whole suite instead of reporting itself.
"""
function waiting_request(fake, action; result = Dict{String,Any}())
    task = @async action()
    if timedwait(() -> isready(fake.client_messages), 10.0) !== :ok
        fetch(task)   # rethrows the real reason, if there was one
        error("action sent no protocol message")
    end
    msg = take!(fake.client_messages)
    reply_ok(fake, msg["id"], result)
    try
        fetch(task)
    catch
    end
    return msg
end

@testset "waiting" begin
    @testset "wait_for_selector sends selector, strictness and the resolved timeout" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)

        sent = waiting_request(f.fake, () -> wait_for_selector(f.page, "#late"))
        @test sent["guid"] == "frame@1"          # page-level calls go via the main frame
        @test sent["method"] == "waitForSelector"
        @test sent["params"]["selector"] == "#late"
        @test sent["params"]["timeout"] == 2_000
        @test sent["params"]["strict"] == true
        # `state` is the driver's business when the caller did not ask for one:
        # sending an explicit default would override a future driver change.
        @test !haskey(sent["params"], "state")
        close(f.fake.connection)
    end

    @testset "wait_for_selector maps state symbols to the wire spelling" begin
        f = timeout_fixture()
        for state in (:attached, :detached, :visible, :hidden)
            sent = waiting_request(
                f.fake,
                () -> wait_for_selector(f.page, "#late"; state = state),
            )
            @test sent["params"]["state"] == String(state)
        end
        # the wire spelling is accepted as-is too
        sent = waiting_request(
            f.fake,
            () -> wait_for_selector(f.page, "#late"; state = "visible"),
        )
        @test sent["params"]["state"] == "visible"
        close(f.fake.connection)
    end

    @testset "wait_for_selector rejects a state the protocol does not have" begin
        f = timeout_fixture()
        @test_throws ArgumentError wait_for_selector(f.page, "#x"; state = :enabled)
        close(f.fake.connection)
    end

    @testset "wait_for_selector on a Frame and a Locator" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)

        sent = waiting_request(f.fake, () -> wait_for_selector(f.frame, "#late"))
        @test sent["guid"] == "frame@1"
        @test sent["params"]["selector"] == "#late"

        # A Locator carries its own selector and strictness — passing them again
        # would be the caller repeating what the locator already knows.
        loc = Playwright.locator(f.frame, "#late"; strict = false)
        sent = waiting_request(f.fake, () -> wait_for_selector(loc))
        @test sent["params"]["selector"] == "#late"
        @test sent["params"]["strict"] == false
        @test sent["params"]["timeout"] == 2_000
        close(f.fake.connection)
    end

    @testset "an explicit timeout beats the cascade" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        sent =
            waiting_request(f.fake, () -> wait_for_selector(f.page, "#late"; timeout = 250))
        @test sent["params"]["timeout"] == 250
        close(f.fake.connection)
    end

    @testset "wait_for_function sends expression, arg and the resolved timeout" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)

        sent = waiting_request(
            f.fake,
            () -> wait_for_function(f.page, "() => window.ready");
            result = Dict{String,Any}("handle" => nothing),
        )
        @test sent["guid"] == "frame@1"
        @test sent["method"] == "waitForFunction"
        @test sent["params"]["expression"] == "() => window.ready"
        @test sent["params"]["timeout"] == 2_000
        # No polling asked for means none on the wire — the driver polls on
        # requestAnimationFrame, which is the better default for a DOM check.
        @test !haskey(sent["params"], "pollingInterval")
        close(f.fake.connection)
    end

    @testset "wait_for_function passes its argument through the value codec" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> wait_for_function(f.page, "n => window.count > n", 41);
            result = Dict{String,Any}("handle" => nothing),
        )
        @test haskey(sent["params"], "arg")
        @test sent["params"]["arg"]["value"]["n"] == 41
        close(f.fake.connection)
    end

    @testset "polling accepts an interval in ms, or :raf for the default" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> wait_for_function(f.page, "() => true"; polling = 50);
            result = Dict{String,Any}("handle" => nothing),
        )
        @test sent["params"]["pollingInterval"] == 50

        sent = waiting_request(
            f.fake,
            () -> wait_for_function(f.page, "() => true"; polling = :raf);
            result = Dict{String,Any}("handle" => nothing),
        )
        @test !haskey(sent["params"], "pollingInterval")
        close(f.fake.connection)
    end

    @testset "wait_for_function on a Frame and a Locator" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> wait_for_function(f.frame, "() => true");
            result = Dict{String,Any}("handle" => nothing),
        )
        @test sent["guid"] == "frame@1"

        loc = Playwright.locator(f.frame, "#late")
        sent = waiting_request(
            f.fake,
            () -> wait_for_function(loc, "() => true");
            result = Dict{String,Any}("handle" => nothing),
        )
        @test sent["guid"] == "frame@1"
        close(f.fake.connection)
    end
end
