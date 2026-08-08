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

using Playwright: route_from_har, route!, unroute!, unroute_all!

const HAR_FIXTURE = joinpath(@__DIR__, "fixtures", "api.har")

"""
A FakeDriver whose replies are chosen by method, so one test can hand
`harLookup` an `action` and watch which settle verb comes back.

`lookup` is a zero-argument callable returning the reply body; it is a callable
rather than a value so a test can change the answer between requests.
"""
function har_fixture(; lookup = () -> Dict{String,Any}("action" => "noentry"))
    fake = FakeDriver()
    conn = fake.connection
    requests = Vector{Any}()
    reply_for = Ref{Any}(lookup)
    @async try
        while true
            msg = take!(fake.client_messages)
            push!(requests, msg)
            method = get(msg, "method", "")
            if method == "harOpen"
                reply_ok(fake, msg["id"], Dict{String,Any}("harId" => "har@1"))
            elseif method == "harLookup"
                reply_ok(fake, msg["id"], reply_for[]())
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

@testset "HAR replay (M8 Part A)" begin
    @testset "the archive is opened once, at registration (T4, D2)" begin
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

    @testset "`fulfill` serves the archived response (T4, SC 2)" begin
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

    @testset "a binary body survives as bytes (T4)" begin
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

    @testset "the lookup carries what the request actually was (T4)" begin
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

    @testset "`noentry` under :abort fails the request (T4, SC 3)" begin
        f = har_fixture()   # the default reply is noentry
        reg = route_from_har(f.context, HAR_FIXTURE; not_found = :abort)
        route = send_route(f.fake, "context@1", "har@na", "http://probe.test/missing")

        settled = settled_with(f.requests, route.guid)
        @test settled["method"] == "abort"

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "`noentry` under :fallback reaches the real network (T4, SC 3)" begin
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

    @testset "`not_found` names both values when given a third (T4)" begin
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

    @testset "`url` restricts which requests are served (T4, D2)" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE; url = "**/api/**")
        # `url` is route!'s matcher under a keyword name, so the glob reaches
        # the driver's interception pattern set unchanged.
        @test last_patterns(f.requests) == ["**/api/**"]

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "no `url` serves everything (T4, D2)" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE)
        @test last_patterns(f.requests) == ["**/*"]

        unroute!(f.context, reg)
        close(f.conn)
    end

    @testset "harOpen answering with `error` names the archive (T4, D5a)" begin
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

    @testset "a missing archive is named before the driver is asked (T4, D5a)" begin
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
