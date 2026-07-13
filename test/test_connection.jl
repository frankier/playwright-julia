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
    transport = Playwright.Transport(from_driver.out, to_driver.in;
        on_message = _ -> nothing)
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
reply_error(fake, id, message) = driver_send(fake,
    Dict("id" => id,
         "error" => Dict("error" => Dict("message" => message, "name" => "Error",
                                         "stack" => ""))))
send_create(fake, parent, type, guid, initializer = Dict{String,Any}()) =
    driver_send(fake, Dict("guid" => parent, "method" => "__create__",
                           "params" => Dict("type" => type, "guid" => guid,
                                            "initializer" => initializer)))
send_dispose(fake, guid) =
    driver_send(fake, Dict("guid" => guid, "method" => "__dispose__",
                           "params" => Dict{String,Any}()))

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
        task = @async Playwright.send_message(fake.connection, "browser@1", "newContext",
                                              Dict{String,Any}("ignoreHTTPSErrors" => true))
        sent = take!(fake.client_messages)
        @test sent["guid"] == "browser@1"
        @test sent["method"] == "newContext"
        @test sent["params"]["ignoreHTTPSErrors"] == true
        @test haskey(sent, "id") && haskey(sent, "metadata")
        reply_ok(fake, sent["id"], Dict("value" => 42))
        @test fetch(task)["value"] == 42
        close(fake.connection)
    end

    @testset "__create__ registers objects; initializer guid refs resolve" begin
        fake = FakeDriver()
        send_create(fake, "", "Playwright", "pw@1",
                    Dict("chromium" => Dict("guid" => "bt@chromium")))
        send_create(fake, "pw@1", "BrowserType", "bt@chromium",
                    Dict("name" => "chromium"))
        sync(fake)
        pw = Playwright.lookup_object(fake.connection, "pw@1")
        bt = Playwright.lookup_object(fake.connection, "bt@chromium")
        @test pw !== nothing && bt !== nothing
        @test Playwright.from_channel(fake.connection,
                                      pw.initializer["chromium"]) === bt
        @test Playwright.from_channel(fake.connection, nothing) === nothing
        close(fake.connection)
    end

    @testset "error replies raise PlaywrightError with the driver's message" begin
        fake = FakeDriver()
        task = @async Playwright.send_message(fake.connection, "page@1", "goto",
                                              Dict{String,Any}("url" => "x"))
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
        task = @async Playwright.send_message(fake.connection, "page@1", "goto",
                                              Dict{String,Any}("url" => "x"))
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
            fake.connection, "page@1", "goto", Dict{String,Any}())
    end

    @testset "stray replies and unknown events do not kill the read loop" begin
        fake = FakeDriver()
        reply_ok(fake, 99999, Dict("value" => 1))                    # unknown id
        driver_send(fake, Dict("guid" => "nope@1", "method" => "someEvent",
                               "params" => Dict{String,Any}()))      # unknown guid
        # The connection still works afterwards:
        sync(fake)
        @test true
        close(fake.connection)
    end
end
