# Unit tests for src/connection.jl — a scripted "fake driver" on the other
# end of the pipes plays canned protocol traces. No browser.

using JSON

# Test double: the driver side of a Connection. `client_messages` yields each
# message the connection sends; `reply` / `event` write raw protocol frames.
struct FakeDriver
    to_driver::Pipe    # connection writes here, we read
    from_driver::Pipe  # we write here, connection reads
    connection::Playwright.Connection
    client_messages::Channel{Any}
end

function FakeDriver()
    to_driver = Pipe()
    from_driver = Pipe()
    Base.link_pipe!(to_driver)
    Base.link_pipe!(from_driver)
    transport =
        Playwright.Transport(from_driver.out, to_driver.in; on_message = _ -> nothing)
    connection = Playwright.Connection(transport)
    Playwright.start!(connection)
    messages = Channel{Any}(32)
    @async try
        while true
            len = ltoh(read(to_driver.out, UInt32))
            put!(messages, JSON.parse(String(read(to_driver.out, len))))
        end
    catch
    end
    return FakeDriver(to_driver, from_driver, connection, messages)
end

function driver_send(fake::FakeDriver, msg::AbstractDict)
    payload = Vector{UInt8}(codeunits(JSON.json(msg)))
    write(fake.from_driver.in, htol(UInt32(length(payload))))
    write(fake.from_driver.in, payload)
    flush(fake.from_driver.in)
end

reply_ok(fake, id, result) = driver_send(fake, Dict("id" => id, "result" => result))
reply_error(fake, id, message) = driver_send(
    fake,
    Dict(
        "id" => id,
        "error" => Dict(
            "error" => Dict("message" => message, "name" => "Error", "stack" => ""),
        ),
    ),
)
send_create(fake, parent, type, guid, initializer = Dict{String,Any}()) = driver_send(
    fake,
    Dict(
        "guid" => parent,
        "method" => "__create__",
        "params" => Dict("type" => type, "guid" => guid, "initializer" => initializer),
    ),
)
send_dispose(fake, guid) = driver_send(
    fake,
    Dict("guid" => guid, "method" => "__dispose__", "params" => Dict{String,Any}()),
)

"Round-trip a no-op request so every earlier frame has been dispatched."
function sync(fake::FakeDriver)
    done = @async Playwright.send_message(fake.connection, "", "sync", Dict{String,Any}())
    msg = take!(fake.client_messages)
    reply_ok(fake, msg["id"], Dict{String,Any}())
    fetch(done)
end

@testset "connection" begin
    @testset "send_message round-trip carries guid/method/params and returns result" begin
        fake = FakeDriver()
        task = @async Playwright.send_message(
            fake.connection,
            "browser@1",
            "newContext",
            Dict{String,Any}("ignoreHTTPSErrors" => true),
        )
        sent = take!(fake.client_messages)
        @test sent["guid"] == "browser@1"
        @test sent["method"] == "newContext"
        @test sent["params"]["ignoreHTTPSErrors"] == true
        @test haskey(sent, "id") && haskey(sent, "metadata")
        reply_ok(fake, sent["id"], Dict("value" => 42))
        @test fetch(task)["value"] == 42
        close(fake.connection)
    end

    @testset "local_utils names HAR replay when the driver exposes none (T2, SC 1)" begin
        # Playwright.utils is `LocalUtils?` in the protocol (playwright.yml:36),
        # so its absence is a case that has to have an answer. D1's answer is an
        # error that says what is unavailable and why, raised at the accessor —
        # rather than a `nothing` that surfaces as a MethodError three frames
        # down inside a route handler.
        fake = FakeDriver()
        @test fake.connection.local_utils === nothing
        err = try
            Playwright.local_utils(fake.connection)
            nothing
        catch e
            e
        end
        @test err isa Playwright.DriverError
        @test occursin("HAR replay", err.message)
        @test occursin("LocalUtils", err.message)
        close(fake.connection)
    end

    @testset "local_utils returns the LocalUtils when the driver has one (T2)" begin
        fake = FakeDriver()
        send_create(fake, "", "LocalUtils", "localUtils")
        sync(fake)
        utils = Playwright.lookup_object(fake.connection, "localUtils")
        @test utils isa Playwright.LocalUtils
        fake.connection.local_utils = utils
        @test Playwright.local_utils(fake.connection) === utils
        close(fake.connection)
    end

    @testset "__create__ registers objects; initializer guid refs resolve" begin
        fake = FakeDriver()
        send_create(
            fake,
            "",
            "Playwright",
            "pw@1",
            Dict("chromium" => Dict("guid" => "bt@chromium")),
        )
        send_create(fake, "pw@1", "BrowserType", "bt@chromium", Dict("name" => "chromium"))
        sync(fake)
        pw = Playwright.lookup_object(fake.connection, "pw@1")
        bt = Playwright.lookup_object(fake.connection, "bt@chromium")
        @test pw !== nothing && bt !== nothing
        @test Playwright.from_channel(fake.connection, pw.initializer["chromium"]) === bt
        @test Playwright.from_channel(fake.connection, nothing) === nothing
        close(fake.connection)
    end

    @testset "error replies raise PlaywrightError with the driver's message" begin
        fake = FakeDriver()
        task = @async Playwright.send_message(
            fake.connection,
            "page@1",
            "goto",
            Dict{String,Any}("url" => "x"),
        )
        sent = take!(fake.client_messages)
        reply_error(fake, sent["id"], "net::ERR_NAME_NOT_RESOLVED at x")
        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.exception : e
        end
        @test err isa PlaywrightError
        @test occursin("ERR_NAME_NOT_RESOLVED", err.message)
        close(fake.connection)
    end

    @testset "error replies append the driver's call log to the message" begin
        fake = FakeDriver()
        task = @async Playwright.send_message(
            fake.connection,
            "frame@1",
            "click",
            Dict{String,Any}("selector" => "#nope"),
        )
        sent = take!(fake.client_messages)
        # Real wire shape: the call log rides at the top level of the reply.
        driver_send(
            fake,
            Dict(
                "id" => sent["id"],
                "error" => Dict(
                    "error" => Dict(
                        "message" => "Timeout 500ms exceeded.",
                        "name" => "TimeoutError",
                        "stack" => "",
                    ),
                ),
                "log" => ["  - waiting for locator(\"#nope\")", "  - retrying"],
            ),
        )
        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.exception : e
        end
        @test err isa PlaywrightError
        @test occursin("Timeout 500ms exceeded", err.message)
        @test occursin("Call log:", err.message)
        @test occursin("#nope", err.message)
        close(fake.connection)
    end

    @testset "__dispose__ removes an object and its children" begin
        fake = FakeDriver()
        send_create(fake, "", "Browser", "browser@1")
        send_create(fake, "browser@1", "BrowserContext", "ctx@1")
        send_create(fake, "ctx@1", "Page", "page@1")
        sync(fake)
        @test Playwright.lookup_object(fake.connection, "page@1") !== nothing
        send_dispose(fake, "ctx@1")
        sync(fake)
        @test Playwright.lookup_object(fake.connection, "browser@1") !== nothing
        @test Playwright.lookup_object(fake.connection, "ctx@1") === nothing
        @test Playwright.lookup_object(fake.connection, "page@1") === nothing
        close(fake.connection)
    end

    @testset "driver crash fails pending calls instead of hanging" begin
        fake = FakeDriver()
        task = @async Playwright.send_message(
            fake.connection,
            "page@1",
            "goto",
            Dict{String,Any}("url" => "x"),
        )
        take!(fake.client_messages)   # request is in flight
        close(fake.from_driver.in)    # driver hangs up
        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.exception : e
        end
        @test err isa PlaywrightError
        # And further sends fail fast too.
        @test_throws PlaywrightError Playwright.send_message(
            fake.connection,
            "page@1",
            "goto",
            Dict{String,Any}(),
        )
    end

    @testset "stray replies and unknown events do not kill the read loop" begin
        fake = FakeDriver()
        reply_ok(fake, 99999, Dict("value" => 1))                    # unknown id
        driver_send(
            fake,
            Dict(
                "guid" => "nope@1",
                "method" => "someEvent",
                "params" => Dict{String,Any}(),
            ),
        )      # unknown guid
        # The connection still works afterwards:
        sync(fake)
        @test true
        close(fake.connection)
    end

    @testset "launch sends only the options that were set" begin
        fake = FakeDriver()
        bt = Playwright.BrowserType(
            fake.connection,
            "BrowserType",
            "browserType@1",
            Dict{String,Any}("name" => "chromium"),
        )

        # Defaults only: nothing but what launch() itself sets.
        task = @async launch(bt)
        msg = take!(fake.client_messages)
        @test msg["method"] == "launch"
        @test sort(collect(keys(msg["params"]))) == ["headless", "timeout"]
        send_create(fake, "browserType@1", "Browser", "browser@1")
        reply_ok(fake, msg["id"], Dict("browser" => Dict("guid" => "browser@1")))
        @test fetch(task) isa Playwright.Browser

        # Options that were set, and nothing else. In particular no key with a
        # null value: an option the caller never mentioned must be absent, not
        # present-and-null, or the driver applies its own default differently.
        task = @async launch(
            bt;
            headless = false,
            chromium_sandbox = false,
            args = ["--disable-dev-shm-usage"],
            env = Dict("PLAYWRIGHT_JL" => 1),
            firefox_user_prefs = Dict("dom.max_script_run_time" => 20),
            executable_path = "/usr/bin/chromium",
            channel = "chrome",
            slow_mo = 50,
            downloads_path = "/tmp/dl",
            proxy = Dict("server" => "http://127.0.0.1:8080"),
        )
        msg = take!(fake.client_messages)
        params = msg["params"]
        @test sort(collect(keys(params))) == sort([
            "headless",
            "timeout",
            "chromiumSandbox",
            "args",
            "env",
            "firefoxUserPrefs",
            "executablePath",
            "channel",
            "slowMo",
            "downloadsPath",
            "proxy",
        ])
        @test params["headless"] === false
        @test params["chromiumSandbox"] === false
        @test params["args"] == ["--disable-dev-shm-usage"]
        # env is a Dict on the Julia side, a NameValue array on the wire.
        @test params["env"] == [Dict("name" => "PLAYWRIGHT_JL", "value" => "1")]
        @test params["firefoxUserPrefs"] == Dict("dom.max_script_run_time" => 20)
        @test params["slowMo"] == 50
        @test params["proxy"] == Dict("server" => "http://127.0.0.1:8080")
        send_create(fake, "browserType@1", "Browser", "browser@2")
        reply_ok(fake, msg["id"], Dict("browser" => Dict("guid" => "browser@2")))
        @test fetch(task) isa Playwright.Browser

        # ...and no option is ever sent as an explicit null.
        @test !any(v -> v === nothing, values(params))
    end

end

# The hermetic tests above cover the absent case, which is the one that needs an
# error. That the pinned driver actually *has* a LocalUtils is a fact about the
# driver, so it is asserted against the driver — the probe found it present
# (m8-probe.md PQ0) and this is what keeps that true.
if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
    @testset "the pinned driver exposes a LocalUtils (T2, SC 1)" begin
        playwright() do pw
            @test pw.utils isa Playwright.LocalUtils
            @test Playwright.local_utils(pw.connection) === pw.utils
        end
    end
end
