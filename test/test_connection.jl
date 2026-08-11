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
    # Frames are length-prefixed, so two tasks writing at once can interleave a
    # header with someone else's payload — the transport then reads a garbage
    # length, throws, and the connection dies as "the Playwright driver exited"
    # in a test that did nothing wrong. Tests routinely write from *two* tasks:
    # the test itself (send_create/send_event) and an autoreply loop. So every
    # write goes through this.
    write_lock::ReentrantLock
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
    return FakeDriver(to_driver, from_driver, connection, messages, ReentrantLock())
end

function driver_send(fake::FakeDriver, msg::AbstractDict)
    payload = Vector{UInt8}(codeunits(JSON.json(msg)))
    # Header and payload as one critical section — see FakeDriver.write_lock.
    lock(fake.write_lock) do
        write(fake.from_driver.in, htol(UInt32(length(payload))))
        write(fake.from_driver.in, payload)
        flush(fake.from_driver.in)
    end
end

"The next message the client sent, or a failed test if it never sends one."
next_message(fake::FakeDriver) =
    take_within!(fake.client_messages, "a message from the client")

"""
Close both pipes, not only the two ends the transport owns.

`close(fake.connection)` closes the transport's input and output; the two ends
this side holds are left open. One test leaking two OS handles does not matter,
but the suite builds a couple of hundred fake drivers, and on Windows those are
named pipes.
"""
function shutdown!(fake::FakeDriver)
    # First, because it is what stops the autoreply loops the fixtures start.
    # Those loops take! forever by design and exit on InvalidStateException --
    # test_har.jl's says so in as many words -- but nothing actually closed the
    # channel, so each one outlived its test and sat on the fake driver it was
    # built for. They are gone by the end of the process either way; the cost is
    # that a leaked loop is a second consumer if anything ever reaches the same
    # channel again.
    close(fake.client_messages)
    close(fake.connection)
    for io in
        (fake.to_driver.out, fake.to_driver.in, fake.from_driver.in, fake.from_driver.out)
        try
            close(io)
        catch
        end
    end
    return nothing
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

"""
Round-trip a no-op request so every earlier frame has been dispatched.

Only for a fake driver nobody else is reading. It answers the round-trip itself,
so a background autoreply loop on the same channel would be a second consumer
racing it for one frame -- see `sync_autoreplied`.
"""
function sync(fake::FakeDriver)
    done = @async Playwright.send_message(fake.connection, "", "sync", Dict{String,Any}())
    msg = next_message(fake)
    reply_ok(fake, msg["id"], Dict{String,Any}())
    await(done, "the sync round-trip")
end

"""
The same round-trip, for a fake driver with an autoreply loop already draining
`client_messages`.

Nothing is taken here: the loop takes the frame and answers it, and
`send_message` returns when it does. Two consumers on one channel is a coin
flip for who gets woken, and the loser waits for a frame that will never be
sent, so the two forms are separate functions rather than one with a flag.
"""
sync_autoreplied(fake::FakeDriver) =
    Playwright.send_message(fake.connection, "", "sync", Dict{String,Any}())

@testset "connection" begin
    @testset "send_message round-trip carries guid/method/params and returns result" begin
        fake = FakeDriver()
        task = @async Playwright.send_message(
            fake.connection,
            "browser@1",
            "newContext",
            Dict{String,Any}("ignoreHTTPSErrors" => true),
        )
        sent = next_message(fake)
        @test sent["guid"] == "browser@1"
        @test sent["method"] == "newContext"
        @test sent["params"]["ignoreHTTPSErrors"] == true
        @test haskey(sent, "id") && haskey(sent, "metadata")
        reply_ok(fake, sent["id"], Dict("value" => 42))
        @test await(task)["value"] == 42
        shutdown!(fake)
    end

    @testset "local_utils names HAR replay when the driver exposes none" begin
        # Playwright.utils is `LocalUtils?` in the protocol (playwright.yml:36),
        # so its absence is a case that has to have an answer. The answer is an
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
        shutdown!(fake)
    end

    @testset "local_utils returns the LocalUtils when the driver has one" begin
        fake = FakeDriver()
        send_create(fake, "", "LocalUtils", "localUtils")
        sync(fake)
        utils = Playwright.lookup_object(fake.connection, "localUtils")
        @test utils isa Playwright.LocalUtils
        fake.connection.local_utils = utils
        @test Playwright.local_utils(fake.connection) === utils
        shutdown!(fake)
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
        shutdown!(fake)
    end

    @testset "error replies raise PlaywrightError with the driver's message" begin
        fake = FakeDriver()
        task = @async Playwright.send_message(
            fake.connection,
            "page@1",
            "goto",
            Dict{String,Any}("url" => "x"),
        )
        sent = next_message(fake)
        reply_error(fake, sent["id"], "net::ERR_NAME_NOT_RESOLVED at x")
        err = try
            await(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.exception : e
        end
        @test err isa PlaywrightError
        @test occursin("ERR_NAME_NOT_RESOLVED", err.message)
        shutdown!(fake)
    end

    @testset "error replies append the driver's call log to the message" begin
        fake = FakeDriver()
        task = @async Playwright.send_message(
            fake.connection,
            "frame@1",
            "click",
            Dict{String,Any}("selector" => "#nope"),
        )
        sent = next_message(fake)
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
            await(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.exception : e
        end
        @test err isa PlaywrightError
        @test occursin("Timeout 500ms exceeded", err.message)
        @test occursin("Call log:", err.message)
        @test occursin("#nope", err.message)
        shutdown!(fake)
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
        shutdown!(fake)
    end

    @testset "driver crash fails pending calls instead of hanging" begin
        fake = FakeDriver()
        task = @async Playwright.send_message(
            fake.connection,
            "page@1",
            "goto",
            Dict{String,Any}("url" => "x"),
        )
        next_message(fake)   # request is in flight
        close(fake.from_driver.in)    # driver hangs up
        err = try
            await(task)
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
        shutdown!(fake)
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
        msg = next_message(fake)
        @test msg["method"] == "launch"
        @test sort(collect(keys(msg["params"]))) == ["headless", "timeout"]
        send_create(fake, "browserType@1", "Browser", "browser@1")
        reply_ok(fake, msg["id"], Dict("browser" => Dict("guid" => "browser@1")))
        @test await(task) isa Playwright.Browser

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
        msg = next_message(fake)
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
        @test await(task) isa Playwright.Browser

        # ...and no option is ever sent as an explicit null.
        @test !any(v -> v === nothing, values(params))
    end

    # --- The wire-parameter pin ------------------------------------------------
    #
    # These grow *before* launch/new_context are refactored onto shared option
    # builders. launch and new_context are used by every test
    # and every example, so a subtle change to option construction would break
    # the suite far from its cause. The assertions above and below
    # pass unchanged across the refactor — which only means anything if they
    # were written against the old behaviour first.

    "Build a Browser over a FakeDriver, for asserting new_context's wire params."
    function context_fixture()
        fake = FakeDriver()
        browser = Playwright.Browser(
            fake.connection,
            "Browser",
            "browser@1",
            Dict{String,Any}("version" => "1.0", "name" => "chromium"),
        )
        return (fake = fake, browser = browser)
    end

    @testset "new_context sends only the options that were set" begin
        f = context_fixture()

        # Defaults only: new_context sets nothing of its own, so the params are
        # empty. That is the half most at risk from a builder that helpfully
        # supplies a default.
        task = @async new_context(f.browser)
        msg = next_message(f.fake)
        @test msg["method"] == "newContext"
        @test isempty(msg["params"])
        send_create(f.fake, "browser@1", "BrowserContext", "context@1")
        reply_ok(f.fake, msg["id"], Dict("context" => Dict("guid" => "context@1")))
        @test await(task) isa Playwright.BrowserContext

        shutdown!(f.fake)
    end

    @testset "new_context's full option set crosses unchanged" begin
        f = context_fixture()

        task = @async new_context(
            f.browser;
            viewport = (width = 1280, height = 720),
            record_video = (dir = "artifacts/video", size = (width = 640, height = 480)),
            user_agent = "TestAgent/1.0",
            locale = "de-DE",
            timezone_id = "Europe/Berlin",
            color_scheme = "dark",
            device_scale_factor = 2,
            is_mobile = true,
            has_touch = true,
            offline = false,
            permissions = ["geolocation"],
            base_url = "https://app.example.com",
            extra_http_headers = Dict("x-custom" => "yes"),
            ignore_https_errors = true,
            java_script_enabled = false,
            accept_downloads = true,
        )
        msg = next_message(f.fake)
        params = msg["params"]

        @test sort(collect(keys(params))) == sort([
            "viewport",
            "recordVideo",
            "userAgent",
            "locale",
            "timezoneId",
            "colorScheme",
            "deviceScaleFactor",
            "isMobile",
            "hasTouch",
            "offline",
            "permissions",
            "baseURL",
            "extraHTTPHeaders",
            "ignoreHTTPSErrors",
            "javaScriptEnabled",
            "acceptDownloads",
        ])

        # The three that are *transformed* rather than passed through, which are
        # the three a refactor is most likely to get wrong.
        @test params["viewport"] == Dict("width" => 1280, "height" => 720)
        @test params["recordVideo"] == Dict(
            "dir" => "artifacts/video",
            "size" => Dict("width" => 640, "height" => 480),
        )
        @test params["extraHTTPHeaders"] == [Dict("name" => "x-custom", "value" => "yes")]
        # ...and the enum mapping that is load-bearing rather than tidy: `true`
        # becomes "accept", never "internal-browser-default".
        @test params["acceptDownloads"] == "accept"

        @test params["userAgent"] == "TestAgent/1.0"
        @test params["javaScriptEnabled"] === false
        @test params["deviceScaleFactor"] == 2
        @test !any(v -> v === nothing, values(params))

        send_create(f.fake, "browser@1", "BrowserContext", "context@2")
        reply_ok(f.fake, msg["id"], Dict("context" => Dict("guid" => "context@2")))
        @test await(task) isa Playwright.BrowserContext

        shutdown!(f.fake)
    end

    @testset "launch_persistent_context sends the union of both" begin
        fake = FakeDriver()
        bt = Playwright.BrowserType(
            fake.connection,
            "BrowserType",
            "browserType@1",
            Dict{String,Any}("name" => "chromium"),
        )

        task = @async launch_persistent_context(
            bt,
            "/tmp/test-profile";
            headless = false,           # a launch option
            args = ["--no-sandbox"],    # ...another
            viewport = (width = 800, height = 600),   # a context option
            locale = "de-DE",           # ...another
        )
        msg = next_message(fake)
        @test msg["method"] == "launchPersistentContext"
        params = msg["params"]

        @test params["userDataDir"] == "/tmp/test-profile"
        # Both families, in one message, through the shared builders.
        @test params["headless"] === false
        @test params["args"] == ["--no-sandbox"]
        @test params["viewport"] == Dict("width" => 800, "height" => 600)
        @test params["locale"] == "de-DE"
        # launch's defaults come along, because a persistent context is still a
        # launch and the protocol requires the timeout.
        @test haskey(params, "timeout")
        # ...and still no explicit nulls.
        @test !any(v -> v === nothing, values(params))

        send_create(fake, "browserType@1", "Browser", "browser@1")
        send_create(fake, "browser@1", "BrowserContext", "context@1")
        reply_ok(
            fake,
            msg["id"],
            Dict(
                "browser" => Dict("guid" => "browser@1"),
                "context" => Dict("guid" => "context@1"),
            ),
        )
        # The *context* is returned, not the browser: it is what every caller
        # then uses, and the browser has exactly one context anyway.
        ctx = await(task)
        @test ctx isa Playwright.BrowserContext
        @test ctx.guid == "context@1"

        shutdown!(fake)
    end

    @testset "an empty user_data_dir is refused before the wire" begin
        fake = FakeDriver()
        bt = Playwright.BrowserType(
            fake.connection,
            "BrowserType",
            "browserType@1",
            Dict{String,Any}("name" => "chromium"),
        )

        # Playwright allows "" — meaning a temp profile — and this package does
        # not: a *persistent* context whose profile evaporates is a call the
        # caller did not mean to make.
        err = try
            launch_persistent_context(bt, "")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("user_data_dir", err.msg)

        # Nothing was sent, so no browser was started to be leaked.
        @test !isready(fake.client_messages)
        shutdown!(fake)
    end

    @testset "an unknown keyword names itself, not a builder" begin
        # The cost of forwarding kwargs to the shared builders is that a typo would
        # otherwise surface as a MethodError inside launch_options. It is caught
        # here instead, where the caller can see which keyword they meant.
        fake = FakeDriver()
        bt = Playwright.BrowserType(
            fake.connection,
            "BrowserType",
            "browserType@1",
            Dict{String,Any}("name" => "chromium"),
        )
        err = try
            launch_persistent_context(bt, "/tmp/p"; headles = true)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("headles", err.msg)
        shutdown!(fake)
    end

    @testset "the option-key split covers both builders exactly" begin
        # The guard against silent drift: if a keyword is
        # added to either builder, the splitting in launch_persistent_context
        # must see it, or that option silently stops reaching the wire for the
        # third caller only.
        launch_keys = Playwright.option_keywords(Playwright.launch_options)
        context_keys = Playwright.option_keywords(Playwright.context_options)

        @test :headless in launch_keys
        @test :viewport in context_keys
        # The two families are disjoint, which is what makes splitting by name
        # unambiguous.
        @test isempty(intersect(launch_keys, context_keys))
    end

    @testset "close! on a persistent context closes only the context" begin
        # close!(ctx) might be expected to close the browser as well, on the
        # premise that otherwise every use leaks a browser process. **That
        # premise is false on this driver**. On both engines, closing a
        # persistent context
        # already takes the browser process with it and disposes the Browser,
        # and an explicit close afterwards raises TargetClosedError.
        #
        # So exactly one close goes out, and this test is what would notice if
        # someone re-added the second one.
        fake = FakeDriver()
        bt = Playwright.BrowserType(
            fake.connection,
            "BrowserType",
            "browserType@1",
            Dict{String,Any}("name" => "chromium"),
        )

        task = @async launch_persistent_context(bt, "/tmp/test-owned")
        msg = next_message(fake)
        send_create(fake, "browserType@1", "Browser", "browser@own")
        send_create(fake, "browser@own", "BrowserContext", "context@own")
        reply_ok(
            fake,
            msg["id"],
            Dict(
                "browser" => Dict("guid" => "browser@own"),
                "context" => Dict("guid" => "context@own"),
            ),
        )
        ctx = await(task)

        seen = Vector{Any}()
        @async try
            while true
                m = next_message(fake)
                push!(seen, m)
                reply_ok(fake, m["id"], Dict{String,Any}())
            end
        catch
        end

        close!(ctx)
        # The loop above is still draining client_messages, so this must not
        # take! as well. That race is what stalled four Windows jobs a run.
        sync_autoreplied(fake)

        closes = filter(m -> get(m, "method", "") == "close", seen)
        @test length(closes) == 1
        @test closes[1]["guid"] == "context@own"
        # In particular, not the browser: the driver has already done that, and
        # asking again is an error rather than a no-op.
        @test !any(m -> get(m, "guid", "") == "browser@own", closes)

        shutdown!(fake)
    end

    @testset "a non-persistent context closes only itself" begin
        # Unchanged by any of the above, and asserted so it stays that way.
        fake = FakeDriver()
        ctx = Playwright.BrowserContext(
            fake.connection,
            "BrowserContext",
            "context@plain",
            Dict{String,Any}(),
        )

        closer = @async close!(ctx)
        msg = next_message(fake)
        @test msg["guid"] == "context@plain"
        @test msg["method"] == "close"
        reply_ok(fake, msg["id"], Dict{String,Any}())
        await(closer)

        sync(fake)
        @test true

        shutdown!(fake)
    end

    @testset "accept_downloads = false denies rather than omitting" begin
        f = context_fixture()
        task = @async new_context(f.browser; accept_downloads = false)
        msg = next_message(f.fake)
        @test msg["params"]["acceptDownloads"] == "deny"
        send_create(f.fake, "browser@1", "BrowserContext", "context@3")
        reply_ok(f.fake, msg["id"], Dict("context" => Dict("guid" => "context@3")))
        @test await(task) isa Playwright.BrowserContext
        shutdown!(f.fake)
    end

end

# --- Engines (D1a) --------------------------------------------------------
#
# `engine(pw, name)` is the whole of M9's new API surface, and it exists
# because the five engine names are not five of a kind: "webkit" names a field
# on `pw`, while "chrome" names `pw.chromium` *plus* a channel. These tests are
# hermetic -- no browser is involved -- because the mapping is the thing being
# checked, and the two branded names differ from their siblings only in what
# goes on the wire.

"A PlaywrightAPI over the fake driver, with all three BrowserTypes."
function engine_fixture()
    fake = FakeDriver()
    types = map(("chromium", "firefox", "webkit")) do name
        Playwright.BrowserType(
            fake.connection,
            "BrowserType",
            "browserType@$name",
            Dict{String,Any}("name" => name),
        )
    end
    # PlaywrightAPI's `process` field is typed Base.Process and nothing under
    # test touches it, so this is the cheapest real one available rather than
    # anything meaningful. It exits immediately; a Process that has exited is
    # still a Process.
    # --startup-file=no: without it this inherits the developer's startup.jl,
    # which on a machine with Revise in it prints a load error into the suite.
    proc = open(`$(Base.julia_cmd()[1]) --startup-file=no -e ""`, "r+")
    pw = Playwright.PlaywrightAPI(types..., proc, fake.connection, nothing)
    return (; fake, pw, types)
end

@testset "engines" begin
    @testset "each name maps to its browser type and channel" begin
        f = engine_fixture()
        chromium, firefox, webkit = f.types

        # The three bundled engines: their own type, and no channel at all.
        # `nothing` rather than "" matters -- it is what decides whether the
        # key reaches the wire.
        for (name, bt) in (("chromium", chromium), ("firefox", firefox), ("webkit", webkit))
            e = engine(f.pw, name)
            @test e isa Playwright.Engine
            @test e.browser_type === bt
            @test engine_name(e) == name
            @test e.channel === nothing
        end

        # The branded two: chromium's type, their own name, and a channel.
        for name in ("chrome", "msedge")
            e = engine(f.pw, name)
            @test e.browser_type === chromium
            @test engine_name(e) == name
            @test e.channel == name
        end

        shutdown!(f.fake)
    end

    @testset "an unknown name names all five" begin
        f = engine_fixture()
        # The point of asking by name is a name that came from somewhere else
        # -- an env var, a matrix, a command line -- so the error has to be
        # readable by someone who does not know the set.
        err = try
            engine(f.pw, "edge")
        catch e
            e
        end
        @test err isa ArgumentError
        for name in ("chromium", "firefox", "webkit", "chrome", "msedge")
            @test occursin(name, err.msg)
        end
        @test occursin("edge", err.msg)
        # Not a silent success by another spelling, either.
        @test_throws ArgumentError engine(f.pw, "Chrome")
        @test_throws ArgumentError engine(f.pw, "")
        shutdown!(f.fake)
    end

    @testset "launch sends channel for the branded two and omits it otherwise" begin
        # On the wire, because "omitted" and "null" are different messages and
        # only one of them is right: a present-and-null channel makes the
        # driver apply a different default from the one it applies when the
        # caller never mentioned it.
        f = engine_fixture()

        for name in ("chromium", "firefox", "webkit")
            task = @async launch(engine(f.pw, name))
            msg = next_message(f.fake)
            @test msg["method"] == "launch"
            @test !haskey(msg["params"], "channel")
            send_create(f.fake, "browserType@$name", "Browser", "browser@$name")
            reply_ok(f.fake, msg["id"], Dict("browser" => Dict("guid" => "browser@$name")))
            @test await(task) isa Playwright.Browser
        end

        for name in ("chrome", "msedge")
            task = @async launch(engine(f.pw, name))
            msg = next_message(f.fake)
            @test msg["params"]["channel"] == name
            send_create(f.fake, "browserType@chromium", "Browser", "browser@$name")
            reply_ok(f.fake, msg["id"], Dict("browser" => Dict("guid" => "browser@$name")))
            @test await(task) isa Playwright.Browser
        end

        shutdown!(f.fake)
    end

    @testset "an explicit channel keyword wins over the engine's" begin
        # Deliberately no warning (D1a): passing channel = "chrome-beta" to
        # engine(pw, "chrome") is a coherent thing to want. Beta and dev
        # channels stay reachable exactly this way and are not engine names.
        f = engine_fixture()

        task = @async launch(engine(f.pw, "chrome"); channel = "chrome-beta")
        msg = next_message(f.fake)
        @test msg["params"]["channel"] == "chrome-beta"
        send_create(f.fake, "browserType@chromium", "Browser", "browser@beta")
        reply_ok(f.fake, msg["id"], Dict("browser" => Dict("guid" => "browser@beta")))
        @test await(task) isa Playwright.Browser

        # ...and it can add one to a bundled engine that had none.
        task = @async launch(engine(f.pw, "chromium"); channel = "chrome-canary")
        msg = next_message(f.fake)
        @test msg["params"]["channel"] == "chrome-canary"
        send_create(f.fake, "browserType@chromium", "Browser", "browser@canary")
        reply_ok(f.fake, msg["id"], Dict("browser" => Dict("guid" => "browser@canary")))
        @test await(task) isa Playwright.Browser

        shutdown!(f.fake)
    end

    @testset "PLAYWRIGHT_JL_ENGINE parsing takes one name, a list, or nothing" begin
        parse = Playwright.parse_engine_names
        all_five = ["chromium", "firefox", "webkit", "chrome", "msedge"]

        @test parse("webkit") == ["webkit"]
        @test parse("chrome,msedge") == ["chrome", "msedge"]
        @test parse("chromium, firefox") == ["chromium", "firefox"]  # spaces
        # Blank means all five, matching an unset variable: a CI matrix whose
        # engine value failed to interpolate should over-test, never under-test.
        @test parse("") == all_five
        @test parse("   ") == all_five

        # The case that matters. An unknown name must *throw*, not yield a
        # short or empty list -- an empty engine loop is a suite that passes by
        # testing nothing, which is the actual risk D5 names.
        for bad in ("edge", "safari", "Chrome", "chromium,safari", "chromium,")
            err = try
                parse(bad)
            catch e
                e
            end
            @test err isa ArgumentError
            for name in all_five
                @test occursin(name, err.msg)
            end
        end
    end

    @testset "the other launch keywords still reach the wire" begin
        # launch(::Engine) forwards to launch(::BrowserType); this is the
        # assertion that it forwards *everything* rather than only what the
        # Engine knows about.
        f = engine_fixture()
        task = @async launch(engine(f.pw, "msedge"); headless = false, slow_mo = 50)
        msg = next_message(f.fake)
        @test msg["params"]["channel"] == "msedge"
        @test msg["params"]["headless"] === false
        @test msg["params"]["slowMo"] == 50
        send_create(f.fake, "browserType@chromium", "Browser", "browser@e")
        reply_ok(f.fake, msg["id"], Dict("browser" => Dict("guid" => "browser@e")))
        @test await(task) isa Playwright.Browser
        shutdown!(f.fake)
    end
end

# The hermetic tests above cover the absent case, which is the one that needs an
# error. That the pinned driver actually *has* a LocalUtils is a fact about the
# driver, so it is asserted against the driver: the pinned driver exposes one,
# and this is what keeps that true.
if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
    @testset "the pinned driver exposes a LocalUtils" begin
        playwright() do pw
            @test pw.utils isa Playwright.LocalUtils
            @test Playwright.local_utils(pw.connection) === pw.utils
        end
    end
end
