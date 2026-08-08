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
const HAR_ZIP_FIXTURE = joinpath(@__DIR__, "fixtures", "api.har.zip")

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

    @testset "`redirect` is one continue! at redirectURL (T5, SC 4)" begin
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

    @testset "a sub-resource redirect is fulfilled, not continued (T5, SC 4)" begin
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

    @testset "`error` carries the driver's message to unroute! (T5, SC 4)" begin
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

    @testset "`error` supplies the names the driver's message omits (T5, SC 5)" begin
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

    @testset "an aborted noentry names the archive and the URL (T5, SC 5)" begin
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

    @testset ":fallback misses are not warned about (T5, SC 5)" begin
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

    # --- .har.zip, and who owns the temp directory (T6, D3) ----------------

    @testset "a .zip is unzipped by the driver, into a temp dir (T6, SC 6)" begin
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

    @testset "the caller's .zip is copied, never handed to harUnzip (T6)" begin
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

    @testset "the temp directory is gone after unroute! (T6, SC 6)" begin
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

    @testset "a plain .har is not unzipped (T6)" begin
        f = har_fixture()
        reg = route_from_har(f.context, HAR_FIXTURE)
        @test isempty(filter(m -> get(m, "method", "") == "harUnzip", f.requests))
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

# The tests above canned every harLookup reply, which proves the mapping and
# nothing about what the driver actually answers. SC 4 asks for the driver's own
# behaviour — that a redirect entry is `redirect` for a navigation and `fulfill`
# for a sub-resource, and that a cycle comes back as the driver's own message.
#
# That needs the real LocalUtils, so it is gated. It needs **no browser**: this
# is the driver parsing a file, which is why it is here beside the hermetic
# tests rather than in a test_smoke_har.jl that has to launch two engines.
if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
    @testset "what the driver really answers (T5, SC 4)" begin
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

    @testset "a .har.zip really replays through harUnzip (T6, SC 6)" begin
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
