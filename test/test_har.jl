# HAR replay, hermetically: the action table, `not_found`, and the archive's
# lifetime. No Node, no browser — `harLookup`'s replies are canned, which is the
# point. Each of the driver's four actions has to produce the settle verb D2's
# table names, and a canned reply is the only way to drive all four from one
# test file without a network to break.
#
# The archive itself (test/fixtures/api.har) is hand-written on purpose, per
# SPEC-M8 R2: replay must be known-good against known input before any
# *recorded* archive exists, or T11's round trip fails for two reasons at once.

using Base64: base64encode, base64decode

using Playwright:
    route_from_har,
    with_har,
    start_har_recording!,
    stop_har_recording!,
    with_har_recording,
    route!,
    unroute!,
    unroute_all!

const HAR_FIXTURE = joinpath(@__DIR__, "fixtures", "api.har")
const HAR_ZIP_FIXTURE = joinpath(@__DIR__, "fixtures", "api.har.zip")

const HAR_ARTIFACT_SEQ = Ref(0)

"""
A FakeDriver whose replies are chosen by method, so one test can hand
`harLookup` an `action` and watch which settle verb comes back.

`lookup` is a zero-argument callable returning the reply body; it is a callable
rather than a value so a test can change the answer between requests.
`export_artifact` is what `harExport` answers with — an `Artifact`, or nothing
at all, which is the case D8's guard exists for.
"""
function har_fixture(;
    lookup = () -> Dict{String,Any}("action" => "noentry"),
    export_artifact::Bool = true,
)
    fake = FakeDriver()
    conn = fake.connection
    requests = Vector{Any}()
    reply_for = Ref{Any}(lookup)
    exports_artifact = Ref(export_artifact)
    @async try
        while true
            msg = take!(fake.client_messages)
            push!(requests, msg)
            method = get(msg, "method", "")
            if method == "harOpen"
                reply_ok(fake, msg["id"], Dict{String,Any}("harId" => "har@1"))
            elseif method == "harLookup"
                reply_ok(fake, msg["id"], reply_for[]())
            elseif method == "harStart"
                reply_ok(fake, msg["id"], Dict{String,Any}("harId" => "harrec@1"))
            elseif method == "harExport"
                if exports_artifact[]
                    # An Artifact, exactly as tracingStopChunk answers with one,
                    # which is why save_as! is already the writer (D8). A fresh
                    # guid per export so no test can settle another's artifact.
                    guid = "artifact@har-$(HAR_ARTIFACT_SEQ[] += 1)"
                    send_create(
                        fake,
                        "context@1",
                        "Artifact",
                        guid,
                        Dict("absolutePath" => "/tmp/pw/$guid"),
                    )
                    reply_ok(
                        fake,
                        msg["id"],
                        Dict{String,Any}("artifact" => Dict("guid" => guid)),
                    )
                else
                    reply_ok(fake, msg["id"], Dict{String,Any}())
                end
            else
                reply_ok(fake, msg["id"], Dict{String,Any}())
            end
        end
    catch e
        # Deliberately loud. The channel closing at the end of a test is the
        # expected way out, but *any other* failure here means a reply is never
        # sent, which presents as a handler blocked forever and a test file that
        # hangs with no message. It cost a debugging session once; it does not
        # get to be silent again.
        e isa InvalidStateException ||
            @error "the HAR fake driver's reply loop died" exception =
                (e, catch_backtrace())
    end

    # Every fixture in this file reuses the same guids, and ROUTE_REGISTRIES is
    # keyed by guid — so a testset that forgets to unroute leaves a registry
    # whose owner belongs to a connection that is now closed, and the *next*
    # fixture's route! publishes its patterns down the dead pipe. That presents
    # as "connection closed: the Playwright driver exited" in a testset that did
    # nothing wrong, metres from the one that did. Dropping the entry here makes
    # each fixture independent of its predecessors' tidiness — the same lesson
    # test_routing.jl records about reused guids.
    lock(Playwright.ROUTE_REGISTRIES_LOCK) do
        for guid in ("context@1", "page@1")
            delete!(Playwright.ROUTE_REGISTRIES, guid)
        end
    end
    lock(Playwright.WS_ROUTE_REGISTRIES_LOCK) do
        for guid in ("context@1", "page@1")
            delete!(Playwright.WS_ROUTE_REGISTRIES, guid)
        end
    end

    send_create(fake, "", "LocalUtils", "localUtils")
    send_create(fake, "", "Browser", "browser@1")
    send_create(fake, "browser@1", "BrowserContext", "context@1")
    send_create(fake, "context@1", "Page", "page@1")
    @test timedwait(() -> Playwright.lookup_object(conn, "page@1") !== nothing, 5.0) === :ok
    conn.local_utils = Playwright.lookup_object(conn, "localUtils")

    return (
        fake = fake,
        conn = conn,
        requests = requests,
        reply_for = reply_for,
        context = Playwright.lookup_object(conn, "context@1"),
        page = Playwright.lookup_object(conn, "page@1"),
    )
end

"""
Give the HAR fixture's context a Tracing channel, the way the real driver does —
via the context initializer rather than a generated accessor. Recording hangs
off Tracing (D6), so every start_har_recording! test needs this first.
"""
function har_tracing(f)
    send_create(f.fake, "context@1", "Tracing", "tracing@1")
    @test timedwait(
        () -> Playwright.lookup_object(f.conn, "tracing@1") !== nothing,
        5.0,
    ) === :ok
    f.context.initializer["tracing"] = Dict("guid" => "tracing@1")
    return nothing
end

"The settle verb a route reached, waiting rather than sleeping (R1's tripwire)."
function settled_with(requests, guid; seconds = 10.0)
    found = Ref{Any}(nothing)
    ok = timedwait(seconds) do
        idx = findlast(
            m ->
                get(m, "guid", "") == guid &&
                    get(m, "method", "") in ("fulfill", "continue", "abort"),
            requests,
        )
        idx === nothing && return false
        found[] = requests[idx]
        return true
    end
    ok === :ok || error("no route settled within $(seconds)s")
    return found[]
end

@testset "HAR replay" begin
    @testset "the archive is opened once, at registration" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE; url = "**/api/**")

        opens = filter(m -> get(m, "method", "") == "harOpen", f.requests)
        @test length(opens) == 1
        # The path goes out absolute: the driver's cwd is not the test's, and a
        # relative archive path would resolve against the wrong one.
        @test opens[1]["params"]["file"] == abspath(HAR_FIXTURE)
        @test opens[1]["guid"] == "localUtils"

        # It is a route registration like any other, so unroute! already works
        # on it and no new handle type was invented (D2).
        @test reg isa Playwright.RouteRegistration
        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "`fulfill` serves the archived response" begin
        f = har_fixture(
            lookup = () -> Dict{String,Any}(
                "action" => "fulfill",
                "status" => 201,
                "headers" =>
                    Any[Dict("name" => "content-type", "value" => "text/plain")],
                "body" => base64encode("BODY-B"),
            ),
        )
        reg = route_from_har(f.context, HAR_FIXTURE)
        route = send_route(f.fake, "context@1", "har@r", "http://probe.test/b")

        settled = settled_with(f.requests, route.guid)
        @test settled["method"] == "fulfill"
        @test settled["params"]["status"] == 201
        @test String(base64decode(settled["params"]["body"])) == "BODY-B"
        @test Dict(h["name"] => h["value"] for h in settled["params"]["headers"])["content-type"] ==
              "text/plain"

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "a binary body survives as bytes" begin
        # The generated layer base64-decodes harLookup's body and fulfill!
        # re-encodes it; a round trip through String would mangle a PNG, so the
        # bytes are asserted rather than the text.
        png = UInt8[0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0xff]
        f = har_fixture(
            lookup = () -> Dict{String,Any}(
                "action" => "fulfill",
                "status" => 200,
                "headers" =>
                    Any[Dict("name" => "content-type", "value" => "image/png")],
                "body" => base64encode(png),
            ),
        )
        reg = route_from_har(f.context, HAR_FIXTURE)
        route = send_route(f.fake, "context@1", "har@png", "http://probe.test/api/logo.png")

        settled = settled_with(f.requests, route.guid)
        @test settled["method"] == "fulfill"
        @test base64decode(settled["params"]["body"]) == png

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "the lookup carries what the request actually was" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE)
        route = send_route(f.fake, "context@1", "har@lk", "http://probe.test/api/items")
        settled_with(f.requests, route.guid)

        lookup = only(filter(m -> get(m, "method", "") == "harLookup", f.requests))
        @test lookup["params"]["harId"] == "har@1"
        @test lookup["params"]["url"] == "http://probe.test/api/items"
        @test lookup["params"]["method"] == "GET"
        @test lookup["params"]["isNavigationRequest"] === false

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "`noentry` under :abort fails the request" begin
        f = har_fixture()   # the default reply is noentry
        reg = route_from_har(f.context, HAR_FIXTURE; not_found = :abort)
        route = send_route(f.fake, "context@1", "har@na", "http://probe.test/missing")

        settled = settled_with(f.requests, route.guid)
        @test settled["method"] == "abort"

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "`noentry` under :fallback reaches the real network" begin
        # SC 3 is that the *same* reply produces different observable outcomes.
        # A test that changed the reply as well as the keyword would prove
        # nothing about the keyword, so the lookup answer here is identical to
        # the one above and only `not_found` differs.
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE; not_found = :fallback)
        route = send_route(f.fake, "context@1", "har@nf", "http://probe.test/missing")

        settled = settled_with(f.requests, route.guid)
        @test settled["method"] == "continue"

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "`not_found` names both values when given a third" begin
        f = har_fixture()
        err = try
            route_from_har(f.context, HAR_FIXTURE; not_found = :ignore)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin(":abort", err.msg)
        @test occursin(":fallback", err.msg)
        @test occursin("ignore", err.msg)

        # ...and it raised before the wire, so nothing was opened.
        @test isempty(filter(m -> get(m, "method", "") == "harOpen", f.requests))
        close(f.conn)
    end

    @testset "`url` restricts which requests are served" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE; url = "**/api/**")
        # `url` is route!'s matcher under a keyword name, so the glob reaches
        # the driver's interception pattern set unchanged.
        @test last_patterns(f.requests) == ["**/api/**"]

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "no `url` serves everything" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE)
        @test last_patterns(f.requests) == ["**/*"]

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "`redirect` is one continue! at redirectURL" begin
        # A navigation whose archive entry is a 302. The driver asks for the
        # navigation to be re-issued at the new URL, which is one continue! —
        # not a re-lookup and not a hop counter. D5 said otherwise until the
        # probe; see tasks/m8-probe.md OQ1.
        f = har_fixture(
            lookup = () -> Dict{String,Any}(
                "action" => "redirect",
                "redirectURL" => "http://probe.test/b",
            ),
        )
        reg = route_from_har(f.context, HAR_FIXTURE)
        route = send_route(
            f.fake,
            "context@1",
            "har@nav",
            "http://probe.test/a";
            navigation = true,
        )

        settled = settled_with(f.requests, route.guid)
        @test settled["method"] == "continue"
        @test settled["params"]["url"] == "http://probe.test/b"

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "a sub-resource redirect is fulfilled, not continued" begin
        # The other half, and the reason the two are separate tests: for a
        # sub-resource the driver resolves the chain internally and answers
        # `fulfill` with the *final* response already attached. A single test
        # covering "a redirect entry" would hide that they are different
        # actions with different answers.
        f = har_fixture(
            lookup = () -> Dict{String,Any}(
                "action" => "fulfill",
                "status" => 200,
                "headers" => Any[],
                "body" => base64encode("BODY-B"),
            ),
        )
        reg = route_from_har(f.context, HAR_FIXTURE)
        route = send_route(f.fake, "context@1", "har@sub", "http://probe.test/a")

        settled = settled_with(f.requests, route.guid)
        @test settled["method"] == "fulfill"
        @test String(base64decode(settled["params"]["body"])) == "BODY-B"
        # No continue! happened: the chain was the driver's to follow.
        @test isempty(
            filter(
                m -> get(m, "guid", "") == route.guid && get(m, "method", "") == "continue",
                f.requests,
            ),
        )

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "`error` carries the driver's message to unroute!" begin
        f = har_fixture(
            lookup = () -> Dict{String,Any}(
                "action" => "error",
                "message" => "HAR error: Found redirect cycle for http://probe.test/loop1",
            ),
        )
        reg = route_from_har(f.context, HAR_FIXTURE)
        send_route(
            f.fake,
            "context@1",
            "har@cyc",
            "http://probe.test/loop1";
            navigation = true,
        )
        until(() -> !isempty(reg.exceptions))

        err = only(reg.exceptions)
        @test err isa Playwright.DriverError
        # The driver's own text, verbatim: a cycle is its problem and it already
        # solves it, so a message of ours would only paraphrase a better one.
        @test occursin("Found redirect cycle", err.message)
        @test occursin("http://probe.test/loop1", err.message)
        # ...and it is rethrown where the handler's exceptions are rethrown.
        @test_throws Playwright.DriverError unroute!(f.context, reg)

        close(f.conn)
    end

    @testset "`error` supplies the names the driver's message omits" begin
        # The driver's own text for a file that is not a HAR is a raw JS
        # TypeError — "Cannot read properties of undefined (reading 'entries')"
        # — which names neither the archive nor the request. Pinned live in the
        # driver-gated testset at the bottom of this file. That is the case D5a
        # is about, and the `error` branch is where it lands, so this is where
        # both names have to be added.
        f = har_fixture(
            lookup = () -> Dict{String,Any}(
                "action" => "error",
                "message" => "HAR error: Cannot read properties of undefined (reading 'entries')",
            ),
        )
        reg = route_from_har(f.context, HAR_FIXTURE)
        send_route(f.fake, "context@1", "har@bad", "http://probe.test/api/items")
        until(() -> !isempty(reg.exceptions))

        err = only(reg.exceptions)
        @test occursin("Cannot read properties", err.message)   # the driver's words
        @test occursin("http://probe.test/api/items", err.message)
        @test occursin(abspath(HAR_FIXTURE), err.message)

        @test_throws Playwright.DriverError unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "an aborted noentry names the archive and the URL" begin
        # The trap D5a found: harOpen succeeds on a file that is not a HAR, so a
        # typo'd archive is indistinguishable at open time and then misses
        # everything. Under :abort that is a page whose every request fails with
        # no clue why — unless the abort says which archive it consulted.
        #
        # Asserted on the message a user actually sees, not only on the fact
        # that something was logged — the distinction m7-api-gaps.md gap 2 paid
        # for.
        f = har_fixture()
        logger = Test.TestLogger(; min_level = Base.CoreLogging.Warn)
        # The registration is made *inside* the block on purpose: the warning is
        # emitted on the dispatcher task, which inherits the logger current when
        # it was spawned. Registering first and wrapping only the request would
        # test logger propagation instead of behaviour — the trap
        # test_dialogs.jl:208 records and test_smoke_network.jl:340 avoids the
        # same way.
        Base.CoreLogging.with_logger(logger) do
            reg = route_from_har(f.context, HAR_FIXTURE)
            route = send_route(f.fake, "context@1", "har@nn2", "http://probe.test/missing")
            settled_with(f.requests, route.guid)
            unroute!(f.context, reg)
        end

        warnings = filter(r -> r.level == Base.CoreLogging.Warn, logger.logs)
        @test length(warnings) == 1
        text = string(warnings[1].message, " ", warnings[1].kwargs)
        @test occursin("http://probe.test/missing", text)
        @test occursin(abspath(HAR_FIXTURE), text)

        close(f.conn)
    end

    @testset ":fallback misses are not warned about" begin
        # A miss under :fallback is the configuration working as asked — "archive
        # the API, let the CDN through" — so warning on it would train the
        # reader to ignore the warning that matters.
        f = har_fixture()
        logger = Test.TestLogger(; min_level = Base.CoreLogging.Warn)
        Base.CoreLogging.with_logger(logger) do
            reg = route_from_har(f.context, HAR_FIXTURE; not_found = :fallback)
            route = send_route(f.fake, "context@1", "har@nn3", "http://probe.test/missing")
            settled_with(f.requests, route.guid)
            unroute!(f.context, reg)
        end
        @test isempty(filter(r -> r.level == Base.CoreLogging.Warn, logger.logs))

        close(f.conn)
    end

    # --- .har.zip, and who owns the temp directory -----------------------------

    @testset "a .zip is unzipped by the driver, into a temp dir" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_ZIP_FIXTURE)

        unzips = filter(m -> get(m, "method", "") == "harUnzip", f.requests)
        @test length(unzips) == 1
        params = unzips[1]["params"]
        har_file = params["harFile"]
        # The extracted .har and the resources must land in the *same*
        # directory: harLookup resolves a content `_file` beside the .har, not
        # under a resources/ subdirectory. Probed — pointing resourcesDir
        # somewhere else makes every body an ENOENT at lookup time.
        @test params["resourcesDir"] == dirname(har_file)
        @test dirname(params["zipFile"]) == dirname(har_file)

        # harOpen is pointed at the extraction, not at the zip.
        opens = filter(m -> get(m, "method", "") == "harOpen", f.requests)
        @test only(opens)["params"]["file"] == har_file
        @test !endswith(har_file, ".zip")

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "the caller's .zip is copied, never handed to harUnzip" begin
        # harUnzip *deletes the zip it is given* — probed, and it cost the
        # fixture once. Replaying an archive must not consume it, so what the
        # driver gets is a copy inside the temp directory.
        f = har_fixture()
        before = read(HAR_ZIP_FIXTURE)
        reg = route_from_har(f.context, HAR_ZIP_FIXTURE)

        zip_sent =
            only(filter(m -> get(m, "method", "") == "harUnzip", f.requests))["params"]["zipFile"]
        @test zip_sent != abspath(HAR_ZIP_FIXTURE)
        @test isfile(HAR_ZIP_FIXTURE)
        @test read(HAR_ZIP_FIXTURE) == before

        unroute!(f.context, reg)
        @test isfile(HAR_ZIP_FIXTURE)
        @test read(HAR_ZIP_FIXTURE) == before
        close(f.conn)
    end

    @testset "the temp directory is gone after unroute!" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_ZIP_FIXTURE)

        har_file =
            only(filter(m -> get(m, "method", "") == "harUnzip", f.requests))["params"]["harFile"]
        tmp = dirname(har_file)
        @test isdir(tmp)

        unroute!(f.context, reg)
        # The registration owned two lifetimes and released both (D3, R5).
        @test !isdir(tmp)
        @test any(m -> get(m, "method", "") == "harClose", f.requests)

        close(f.conn)
    end

    @testset "a plain .har is not unzipped" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE)
        @test isempty(filter(m -> get(m, "method", "") == "harUnzip", f.requests))
        unroute!(f.context, reg)
        close(f.conn)
    end

    # --- with_har, the update refusal, and harClose ----------------------------

    @testset "unroute! closes the archive, on the wire" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE)
        @test isempty(filter(m -> get(m, "method", "") == "harClose", f.requests))

        unroute!(f.context, reg)

        closes = filter(m -> get(m, "method", "") == "harClose", f.requests)
        @test length(closes) == 1
        @test closes[1]["guid"] == "localUtils"
        @test closes[1]["params"]["harId"] == "har@1"

        # Idempotent: a second unroute! does not close a second time.
        unroute!(f.context, reg)
        @test length(filter(m -> get(m, "method", "") == "harClose", f.requests)) == 1

        close(f.conn)
    end

    @testset "unroute_all! closes the archive too" begin
        f = har_fixture()
        route_from_har(f.context, HAR_FIXTURE)
        unroute_all!(f.context)
        @test length(filter(m -> get(m, "method", "") == "harClose", f.requests)) == 1
        close(f.conn)
    end

    @testset "with_har closes the archive when the body throws" begin
        f = har_fixture()
        @test_throws ErrorException with_har(f.context, HAR_FIXTURE) do
            error("the body failed")
        end

        @test length(filter(m -> get(m, "method", "") == "harClose", f.requests)) == 1
        @test Playwright.registry_for(f.context) === nothing
        close(f.conn)
    end

    @testset "with_har returns the body's value" begin
        f = har_fixture()
        @test with_har(f.context, HAR_FIXTURE; url = "**/api/**") do
            42
        end == 42
        @test length(filter(m -> get(m, "method", "") == "harClose", f.requests)) == 1
        close(f.conn)
    end

    @testset "with_har cleans up a .zip's temp directory when the body throws" begin
        # The path most likely to leak: two lifetimes, an exception, and no
        # explicit unroute! in the caller's code.
        f = har_fixture()
        @test_throws ErrorException with_har(f.context, HAR_ZIP_FIXTURE) do
            error("the body failed")
        end
        har_file =
            only(filter(m -> get(m, "method", "") == "harUnzip", f.requests))["params"]["harFile"]
        @test !isdir(dirname(har_file))
        close(f.conn)
    end

    # --- update = true: a recording behind a replay's name ---------------------
    #
    # T7 shipped this keyword as an explicit refusal, and this is the commit
    # that removes it — the point of D7's two-task split. The name says "route"
    # and the behaviour is "trace", which is confusing enough that the spec says
    # it twice and so does this comment.

    @testset "update = true records instead of replaying" begin
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "refresh.har")
        cp(HAR_FIXTURE, dest)

        reg = route_from_har(f.context, dest; url = "**/api/**", update = true)
        @test reg isa Playwright.RouteRegistration

        # It is a recording: harStart, scoped to the same url pattern, aimed at
        # the same file. Not a replay: the archive is never opened for lookup.
        start = only(filter(m -> get(m, "method", "") == "harStart", f.requests))
        @test start["params"]["options"]["urlGlob"] == "**/api/**"
        @test start["params"]["options"]["path"] == dest
        @test isempty(filter(m -> get(m, "method", "") == "harOpen", f.requests))

        # ...and it intercepts nothing, so the traffic it records is the real
        # traffic rather than something round-tripped through a handler.
        @test isempty(
            filter(
                m -> get(m, "method", "") == "setNetworkInterceptionPatterns",
                f.requests,
            ),
        ) || last_patterns(f.requests) == String[]

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "unroute! on an update registration writes the file" begin
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "refresh.har")
        cp(HAR_FIXTURE, dest)

        reg = route_from_har(f.context, dest; update = true)
        @test isempty(filter(m -> get(m, "method", "") == "harExport", f.requests))

        unroute!(f.context, reg)

        export_msg = only(filter(m -> get(m, "method", "") == "harExport", f.requests))
        @test export_msg["params"]["mode"] == "archive"
        # The export is a zip, so it is staged and unzipped onto the caller's
        # path — the same write path stop_har_recording! takes anywhere else.
        @test only(filter(m -> get(m, "method", "") == "harUnzip", f.requests))["params"]["harFile"] ==
              dest
        # No archive was ever *opened*, so none is closed. (The harUnzip above
        # is the write, not a read.)
        @test isempty(filter(m -> get(m, "method", "") == "harClose", f.requests))

        close(f.conn)
    end

    @testset "with_har + update writes even when the body throws" begin
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "refresh.har")
        cp(HAR_FIXTURE, dest)

        @test_throws ErrorException with_har(f.context, dest; update = true) do
            error("the body failed")
        end
        @test length(filter(m -> get(m, "method", "") == "harExport", f.requests)) == 1

        close(f.conn)
    end

    @testset "update = true does not require the archive to exist yet" begin
        # Recording *into* a path is how the first archive gets made, so the
        # isfile check that guards replay must not guard this.
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "brand-new.har")
        @test !isfile(dest)

        reg = route_from_har(f.context, dest; update = true)
        @test only(filter(m -> get(m, "method", "") == "harStart", f.requests))["params"]["options"]["path"] ==
              dest
        unroute!(f.context, reg)

        close(f.conn)
    end

    @testset "update = true still refuses a Page target" begin
        # harStart is a Tracing command and Tracing hangs off the context, so
        # there is nowhere to put a page-scoped recording. Named rather than
        # left as a MethodError from two frames down.
        f = har_fixture()
        har_tracing(f)
        err = try
            route_from_har(f.page, HAR_FIXTURE; update = true)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("BrowserContext", err.msg)
        close(f.conn)
    end

    # --- Recording: HarRecording, start/stop -----------------------------------
    #
    # D6 makes this a start!/stop! pair rather than a new_context keyword,
    # because start_tracing!/stop_tracing! already made that decision in M4 for
    # the identical protocol shape — a Tracing command pair producing an
    # Artifact. A second feature on the same object with the opposite spelling
    # would be the package disagreeing with itself.

    @testset "start_har_recording! sends the RecordHarOptions" begin
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "out.har")

        rec = start_har_recording!(f.context, path = dest, url = "**/api/**")
        @test rec isa Playwright.HarRecording

        start = only(filter(m -> get(m, "method", "") == "harStart", f.requests))
        @test start["guid"] == "tracing@1"
        options = start["params"]["options"]
        # Symbols on the Julia side, the wire's string enums on the wire.
        @test options["content"] == "embed"
        @test options["mode"] == "full"
        @test options["urlGlob"] == "**/api/**"
        @test options["path"] == dest
        # A glob is not also sent as a regex.
        @test !haskey(options, "urlRegexSource")

        close(f.conn)
    end

    @testset "a Regex url goes out as source and flags, not as a glob" begin
        f = har_fixture()
        har_tracing(f)
        start_har_recording!(
            f.context,
            path = joinpath(mktempdir(), "o.har"),
            url = r"api/\d+"i,
        )

        options =
            only(filter(m -> get(m, "method", "") == "harStart", f.requests))["params"]["options"]
        @test options["urlRegexSource"] == "api/\\d+"
        @test occursin("i", options["urlRegexFlags"])
        @test !haskey(options, "urlGlob")

        close(f.conn)
    end

    @testset "no url records everything" begin
        f = har_fixture()
        har_tracing(f)
        start_har_recording!(f.context, path = joinpath(mktempdir(), "o.har"))
        options =
            only(filter(m -> get(m, "method", "") == "harStart", f.requests))["params"]["options"]
        @test !haskey(options, "urlGlob")
        @test !haskey(options, "urlRegexSource")
        close(f.conn)
    end

    @testset "content and mode reject a bad Symbol, naming the set" begin
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "o.har")

        err = try
            start_har_recording!(f.context, path = dest, content = :inline)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("content", err.msg)
        @test occursin(":embed", err.msg)
        @test occursin(":attach", err.msg)
        @test occursin(":omit", err.msg)

        err2 = try
            start_har_recording!(f.context, path = dest, mode = :partial)
            nothing
        catch e
            e
        end
        @test err2 isa ArgumentError
        @test occursin("mode", err2.msg)
        @test occursin(":full", err2.msg)
        @test occursin(":minimal", err2.msg)

        # Before the wire, both of them: a typo must not start a recording.
        @test isempty(filter(m -> get(m, "method", "") == "harStart", f.requests))

        # ...and the valid values are accepted.
        @test start_har_recording!(
            f.context,
            path = dest,
            content = :attach,
            mode = :minimal,
        ) isa Playwright.HarRecording
        options =
            only(filter(m -> get(m, "method", "") == "harStart", f.requests))["params"]["options"]
        @test options["content"] == "attach"
        @test options["mode"] == "minimal"

        close(f.conn)
    end

    @testset "stop_har_recording! exports, saves, and returns the path" begin
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "out.har")

        rec = start_har_recording!(f.context, path = dest)
        @test rec.path == dest

        @test stop_har_recording!(rec) == dest

        export_msg = only(filter(m -> get(m, "method", "") == "harExport", f.requests))
        # "archive" and not "entries": this package does not parse HAR, so the
        # inline-entries mode is not wrapped (D8).
        @test export_msg["params"]["mode"] == "archive"
        @test export_msg["params"]["harId"] == rec.har_id

        # The artifact is written by save_as!, the writer M4 already had — but
        # to a staging zip, because harExport(mode = "archive") always produces
        # one whatever `content` was. T11 found that the hard way: the replay
        # met `Unexpected token 'P', "PK…" is not valid JSON`.
        save = only(filter(m -> get(m, "method", "") == "saveAs", f.requests))
        @test startswith(save["guid"], "artifact@har-")
        @test endswith(save["params"]["path"], ".zip")

        # ...and the zip is unzipped onto the destination the caller asked for,
        # with resources beside it where harLookup will look.
        unzip = only(filter(m -> get(m, "method", "") == "harUnzip", f.requests))
        @test unzip["params"]["harFile"] == dest
        @test unzip["params"]["resourcesDir"] == dirname(abspath(dest))
        @test unzip["params"]["zipFile"] == save["params"]["path"]

        close(f.conn)
    end

    @testset "a .zip destination keeps the archive as exported" begin
        # The other half of the same decision: ask for a zip and no unzip
        # happens, because a zip is what the export already is.
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "out.har.zip")

        rec = start_har_recording!(f.context, path = dest, content = :attach)
        @test stop_har_recording!(rec) == dest

        @test only(filter(m -> get(m, "method", "") == "saveAs", f.requests))["params"]["path"] ==
              dest
        @test isempty(filter(m -> get(m, "method", "") == "harUnzip", f.requests))

        close(f.conn)
    end

    @testset "a zip is recognised by its bytes, not its name" begin
        # Both directions of this feature produce a zip under a .har name if you
        # let them, and the failure mode is the driver's JSON parser choking on
        # "PK". The extension is a guess; the content is the fact.
        dir = mktempdir()
        zip_named_har = joinpath(dir, "actually-a-zip.har")
        cp(HAR_ZIP_FIXTURE, zip_named_har)
        @test Playwright.is_zip_file(zip_named_har)
        @test !Playwright.is_zip_file(HAR_FIXTURE)
        @test !Playwright.is_zip_file(joinpath(dir, "nothing-here"))

        f = har_fixture()
        reg = route_from_har(f.context, zip_named_har)
        # Unzipped despite the name, so harOpen never sees the zip.
        @test length(filter(m -> get(m, "method", "") == "harUnzip", f.requests)) == 1
        @test only(filter(m -> get(m, "method", "") == "harOpen", f.requests))["params"]["file"] !=
              zip_named_har

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "an export with no artifact names the unwritten path" begin
        # The guard stop_tracing! already has (D8). Without it an export that
        # produced nothing is a silent no-op and the caller finds an absent file
        # much later.
        f = har_fixture(export_artifact = false)
        har_tracing(f)
        dest = joinpath(mktempdir(), "never-written.har")
        rec = start_har_recording!(f.context, path = dest)

        err = try
            stop_har_recording!(rec)
            nothing
        catch e
            e
        end
        @test err isa Playwright.DriverError
        @test occursin(dest, err.message)
        @test !isfile(dest)

        close(f.conn)
    end

    @testset "with_har_recording writes the archive when the body throws" begin
        # The mirror of with_route's throwing test, and the reason the block
        # form exists: a recording abandoned by an exception is a recording of
        # exactly the run worth looking at.
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "thrown.har")

        @test_throws ErrorException with_har_recording(f.context; path = dest) do
            error("the body failed")
        end

        @test length(filter(m -> get(m, "method", "") == "harStart", f.requests)) == 1
        @test length(filter(m -> get(m, "method", "") == "harExport", f.requests)) == 1
        @test only(filter(m -> get(m, "method", "") == "harUnzip", f.requests))["params"]["harFile"] ==
              dest

        close(f.conn)
    end

    @testset "with_har_recording returns the body's value" begin
        f = har_fixture()
        har_tracing(f)
        dest = joinpath(mktempdir(), "ok.har")
        @test with_har_recording(f.context; path = dest, url = "**/api/**") do
            42
        end == 42
        @test length(filter(m -> get(m, "method", "") == "harExport", f.requests)) == 1
        close(f.conn)
    end

    @testset "with_har_recording validates before it starts anything" begin
        f = har_fixture()
        har_tracing(f)
        ran = Ref(false)
        @test_throws ArgumentError with_har_recording(
            f.context;
            path = joinpath(mktempdir(), "x.har"),
            content = :inline,
        ) do
            ran[] = true
        end
        @test !ran[]
        @test isempty(filter(m -> get(m, "method", "") == "harStart", f.requests))
        close(f.conn)
    end

    @testset "harOpen answering with `error` names the archive" begin
        fake = FakeDriver()
        conn = fake.connection
        @async try
            while true
                msg = take!(fake.client_messages)
                if get(msg, "method", "") == "harOpen"
                    reply_ok(fake, msg["id"], Dict{String,Any}("error" => "bad archive"))
                else
                    reply_ok(fake, msg["id"], Dict{String,Any}())
                end
            end
        catch
        end
        send_create(fake, "", "LocalUtils", "localUtils")
        send_create(fake, "", "Browser", "browser@1")
        send_create(fake, "browser@1", "BrowserContext", "context@1")
        @test timedwait(
            () -> Playwright.lookup_object(conn, "context@1") !== nothing,
            5.0,
        ) === :ok
        conn.local_utils = Playwright.lookup_object(conn, "localUtils")
        ctx = Playwright.lookup_object(conn, "context@1")

        err = try
            route_from_har(ctx, HAR_FIXTURE)
            nothing
        catch e
            e
        end
        @test err isa Playwright.DriverError
        @test occursin("bad archive", err.message)
        @test occursin(abspath(HAR_FIXTURE), err.message)

        close(conn)
    end

    @testset "a missing archive is named before the driver is asked" begin
        f = har_fixture()
        err = try
            route_from_har(f.context, joinpath(@__DIR__, "fixtures", "nope.har"))
            nothing
        catch e
            e
        end
        # harOpen on a missing file raises DriverError: ENOENT rather than
        # returning the declared `error` field (D5a), so the check that matters
        # is that *something* names the file — which is cheapest to guarantee
        # by looking before asking.
        @test err !== nothing
        @test occursin("nope.har", sprint(showerror, err))
        close(f.conn)
    end
end

# The tests above canned every harLookup reply, which proves the mapping and
# nothing about what the driver actually answers. SC 4 asks for the driver's own
# behaviour — that a redirect entry is `redirect` for a navigation and `fulfill`
# for a sub-resource, and that a cycle comes back as the driver's own message.
#
# That needs the real LocalUtils, so it is gated. It needs **no browser**: this
# is the driver parsing a file, which is why it is here beside the hermetic
# tests rather than in a test_smoke_har.jl that has to launch two engines.
if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
    @testset "what the driver really answers" begin
        playwright() do pw
            utils = Playwright.local_utils(pw.connection)
            opened = Playwright._local_utils_har_open(utils; file = abspath(HAR_FIXTURE))
            @test opened.error === nothing
            har_id = opened.harId

            ask(url; navigation = false) = Playwright._local_utils_har_lookup(
                utils;
                harId = har_id,
                url = url,
                method = "GET",
                headers = Any[],
                isNavigationRequest = navigation,
            )

            @testset "a sub-resource redirect resolves to the final response" begin
                got = ask("http://probe.test/a")
                @test got.action == "fulfill"
                @test got.status == 200
                @test String(got.body) == "BODY-B"
            end

            @testset "the same entry as a navigation is a redirect" begin
                got = ask("http://probe.test/a"; navigation = true)
                @test got.action == "redirect"
                @test got.redirectURL == "http://probe.test/b"
            end

            @testset "a cycle is the driver's error, with the driver's words" begin
                got = ask("http://probe.test/loop1"; navigation = true)
                @test got.action == "error"
                @test occursin("Found redirect cycle", got.message)
            end

            @testset "a URL the archive lacks is noentry" begin
                @test ask("http://probe.test/nope").action == "noentry"
            end

            # D5a predicted that a file which is not a HAR opens successfully and
            # then answers `noentry` to everything. The first half holds; the
            # second does not, and the three tests below pin what the driver
            # really does. See the T5 addendum in tasks/m8-probe.md — the
            # conclusion is unchanged (the caller must be told which archive and
            # which URL) but it is the `error` branch that has to say so, not the
            # `noentry` one.
            lookup_against(path) = begin
                opened = Playwright._local_utils_har_open(utils; file = path)
                got = Playwright._local_utils_har_lookup(
                    utils;
                    harId = opened.harId,
                    url = "http://probe.test/api/items",
                    method = "GET",
                    headers = Any[],
                    isNavigationRequest = false,
                )
                Playwright._local_utils_har_close(utils; harId = opened.harId)
                (opened, got)
            end

            @testset "a file that is not a HAR opens, then errors on lookup" begin
                path = joinpath(mktempdir(), "not-a.har")
                write(path, """{"this": "is not a har"}""")
                opened, got = lookup_against(path)
                @test opened.error === nothing      # D5a's first half: it opens
                @test opened.harId !== nothing
                @test got.action == "error"         # D5a's second half: not noentry
                # The driver's message is a raw JS TypeError naming neither the
                # archive nor the URL, which is why the `error` branch wraps it
                # with both rather than passing it through.
                @test occursin("Cannot read properties", got.message)
                @test !occursin(path, got.message)
            end

            @testset "a valid archive missing an entry is noentry" begin
                # The case the noentry warning is actually for.
                path = joinpath(mktempdir(), "empty.har")
                write(path, """{"log": {"version": "1.2", "entries": []}}""")
                _, got = lookup_against(path)
                @test got.action == "noentry"
            end

            @testset "a truncated archive raises at harOpen" begin
                path = joinpath(mktempdir(), "truncated.har")
                write(path, """{"log": {"vers""")
                err = try
                    Playwright._local_utils_har_open(utils; file = path)
                    nothing
                catch e
                    e
                end
                @test err isa Playwright.DriverError
                @test occursin("JSON", err.message)
            end

            Playwright._local_utils_har_close(utils; harId = har_id)
        end
    end

    @testset "a .har.zip really replays through harUnzip" begin
        # The hermetic tests above assert the *shape* of the unzip call against
        # canned replies. This asserts it works: the driver's own extraction,
        # its own lookup, and bodies that live outside the JSON.
        playwright() do pw
            utils = Playwright.local_utils(pw.connection)
            before = read(HAR_ZIP_FIXTURE)

            tmp = mktempdir()
            zip_copy = joinpath(tmp, "archive.har.zip")
            cp(HAR_ZIP_FIXTURE, zip_copy)
            har_file = joinpath(tmp, "har.har")
            Playwright._local_utils_har_unzip(
                utils;
                zipFile = zip_copy,
                harFile = har_file,
                resourcesDir = tmp,
            )

            # The copy was consumed and the original was not.
            @test !isfile(zip_copy)
            @test read(HAR_ZIP_FIXTURE) == before

            opened = Playwright._local_utils_har_open(utils; file = har_file)
            @test opened.error === nothing
            ask(url; navigation = false) = Playwright._local_utils_har_lookup(
                utils;
                harId = opened.harId,
                url = url,
                method = "GET",
                headers = Any[],
                isNavigationRequest = navigation,
            )

            # A text body, from a file beside the .har rather than inline.
            items = ask("http://probe.test/api/items")
            @test items.action == "fulfill"
            @test String(copy(items.body)) == "[\"a\",\"b\"]"

            # And a binary one, which is the reason content = attach exists.
            logo = ask("http://probe.test/api/logo.png")
            @test logo.action == "fulfill"
            @test logo.body[1:4] == UInt8[0x89, 0x50, 0x4e, 0x47]

            # The redirect and noentry paths survive the round trip too.
            @test ask("http://probe.test/a"; navigation = true).action == "redirect"
            @test ask("http://probe.test/nope").action == "noentry"

            Playwright._local_utils_har_close(utils; harId = opened.harId)
        end
    end
end
