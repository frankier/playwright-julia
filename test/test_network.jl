# Request and Response accessors, hermetically. No driver and no browser: the
# objects are created over a FakeDriver with the initializers the protocol
# would really deliver (protocol/spec/network.yml Request/Response), which is
# what "the accessors read the initializer" means.
#
# The wire-going calls (body, raw_headers, response) are exercised against
# canned replies rather than skipped — getting the round trip wrong is exactly
# the failure a browser test would only show as a hang.

using Base64: base64encode

using Playwright:
    headers,
    headers_array,
    raw_headers,
    resource_type,
    is_navigation_request,
    redirected_from,
    post_data,
    post_data_string,
    status,
    status_text,
    ok,
    body,
    text,
    json,
    method,
    request,
    response,
    RequestFailure,
    error_text

"""
Run `f` on a task and fail — rather than hang — if it takes longer than
`seconds`.

The three testsets below block on a canned driver reply. When the reply never
comes, the bare call blocks forever: this file cost a 25-minute hung CI run
before this guard existed, because a responder task that threw looked exactly
like a slow one. the rule for the routing tests is the same rule, and it
applies here for the same reason.
"""
function within(f, seconds = 10.0)
    result = Ref{Any}(nothing)
    failure = Ref{Any}(nothing)
    task = @async try
        result[] = f()
    catch e
        failure[] = e
    end
    if timedwait(() -> istaskdone(task), seconds) !== :ok
        error("timed out after $(seconds)s waiting for a driver reply")
    end
    failure[] === nothing || throw(failure[])
    return result[]
end

"A NameValue array as the protocol carries it."
name_values(pairs...) = [Dict{String,Any}("name" => n, "value" => v) for (n, v) in pairs]

"Build a Request over a FakeDriver with `init` as its initializer."
function fake_request(fake, guid = "request@1"; init = Dict{String,Any}())
    base = Dict{String,Any}(
        "url" => "https://x.test/api/items?page=2",
        "method" => "GET",
        "resourceType" => "fetch",
        "isNavigationRequest" => false,
        "headers" => name_values("Accept" => "application/json"),
    )
    send_create(fake, "", "Request", guid, merge(base, init))
    @test timedwait(
        () -> Playwright.lookup_object(fake.connection, guid) !== nothing,
        5.0,
    ) === :ok
    return Playwright.lookup_object(fake.connection, guid)
end

"Build a Response over a FakeDriver, with a Request behind it."
function fake_response(fake, guid = "response@1"; init = Dict{String,Any}())
    req = fake_request(fake, "request-for-$guid")
    base = Dict{String,Any}(
        "request" => Dict("guid" => req.guid),
        "url" => "https://x.test/api/items?page=2",
        "status" => 200,
        "statusText" => "OK",
        "headers" => name_values("Content-Type" => "application/json"),
    )
    send_create(fake, "", "Response", guid, merge(base, init))
    @test timedwait(
        () -> Playwright.lookup_object(fake.connection, guid) !== nothing,
        5.0,
    ) === :ok
    return Playwright.lookup_object(fake.connection, guid)
end

@testset "network" begin
    @testset "Request reads its initializer" begin
        fake = FakeDriver()
        req = fake_request(fake)

        @test url(req) == "https://x.test/api/items?page=2"
        @test method(req) == "GET"
        @test resource_type(req) == "fetch"
        @test is_navigation_request(req) == false
        @test frame(req) === nothing        # no frame in this initializer
        @test redirected_from(req) === nothing
        @test post_data(req) === nothing
        @test post_data_string(req) === nothing

        close(fake.connection)
    end

    @testset "Response reads its initializer" begin
        fake = FakeDriver()
        resp = fake_response(fake)

        @test url(resp) == "https://x.test/api/items?page=2"
        @test status(resp) == 200
        @test status_text(resp) == "OK"
        @test ok(resp)
        @test request(resp) isa Playwright.Request
        @test url(request(resp)) == "https://x.test/api/items?page=2"

        close(fake.connection)
    end

    @testset "ok covers 2xx and the 0 of file:// and data:" begin
        fake = FakeDriver()
        for (code, expected) in [
            (200, true),
            (204, true),
            (299, true),
            (0, true),
            (300, false),
            (404, false),
            (500, false),
        ]
            resp = fake_response(fake, "r$code"; init = Dict{String,Any}("status" => code))
            @test ok(resp) == expected
        end
        close(fake.connection)
    end

    @testset "headers lower-cases keys and joins duplicates with \", \"" begin
        fake = FakeDriver()
        resp = fake_response(
            fake;
            init = Dict{String,Any}(
                "headers" => name_values(
                    "Content-Type" => "application/json",
                    "Set-Cookie" => "a=1",
                    "SET-COOKIE" => "b=2",
                ),
            ),
        )

        h = headers(resp)
        @test h["content-type"] == "application/json"
        # Both spellings of the duplicate collapse to one lower-cased key...
        @test h["set-cookie"] == "a=1, b=2"
        @test length(h) == 2

        close(fake.connection)
    end

    @testset "headers_array preserves wire order, case and duplicates" begin
        fake = FakeDriver()
        resp = fake_response(
            fake;
            init = Dict{String,Any}(
                "headers" => name_values(
                    "Set-Cookie" => "a=1",
                    "Content-Type" => "application/json",
                    "SET-COOKIE" => "b=2",
                ),
            ),
        )

        arr = headers_array(resp)
        @test arr == [
            "Set-Cookie" => "a=1",
            "Content-Type" => "application/json",
            "SET-COOKIE" => "b=2",
        ]
        # ...which is the whole reason it exists: this is what `headers` loses.
        @test length([v for (k, v) in arr if lowercase(k) == "set-cookie"]) == 2

        close(fake.connection)
    end

    @testset "the three body forms return three types" begin
        fake = FakeDriver()
        # One function, one return type. Bytes, String, parsed.
        payload = "{\"items\":[1,2],\"ok\":true}"
        req = fake_request(
            fake;
            init = Dict{String,Any}(
                "method" => "POST",
                "postData" => base64encode(payload),
            ),
        )

        @test post_data(req) == Vector{UInt8}(codeunits(payload))
        @test post_data(req) isa Vector{UInt8}
        @test post_data_string(req) == payload
        @test json(req) == Dict("items" => [1, 2], "ok" => true)

        close(fake.connection)
    end

    @testset "a request with no body says so rather than guessing" begin
        fake = FakeDriver()
        req = fake_request(fake)
        @test post_data(req) === nothing
        @test post_data_string(req) === nothing
        @test_throws ArgumentError json(req)
        close(fake.connection)
    end

    @testset "binary post data survives as bytes" begin
        fake = FakeDriver()
        # Not valid UTF-8 — a file upload, say. `post_data` must still work,
        # which is why it is the byte-returning one.
        raw = UInt8[0x00, 0xff, 0xfe, 0x41]
        req = fake_request(fake; init = Dict{String,Any}("postData" => base64encode(raw)))
        @test post_data(req) == raw
        close(fake.connection)
    end

    @testset "body, text and json go to the wire" begin
        fake = FakeDriver()
        resp = fake_response(fake)
        payload = "{\"hello\":\"world\"}"

        # One canned reply per call, so each assertion pays its own round trip.
        @async begin
            for _ = 1:3
                msg = take!(fake.client_messages)
                reply_ok(
                    fake,
                    msg["id"],
                    Dict{String,Any}("binary" => base64encode(payload)),
                )
            end
        end

        @test within(() -> body(resp)) == Vector{UInt8}(codeunits(payload))
        @test within(() -> text(resp)) == payload
        @test within(() -> json(resp)) == Dict("hello" => "world")

        close(fake.connection)
    end

    @testset "raw_headers costs a round trip and keeps wire order" begin
        fake = FakeDriver()
        resp = fake_response(fake)

        sent = Ref{Any}(nothing)
        @async begin
            msg = take!(fake.client_messages)
            sent[] = msg
            reply_ok(
                fake,
                msg["id"],
                Dict{String,Any}(
                    "headers" => name_values(
                        "Content-Type" => "application/json",
                        "Set-Cookie" => "a=1",
                        "Set-Cookie" => "b=2",
                    ),
                ),
            )
        end

        raw = within(() -> raw_headers(resp))
        @test raw[1] == ("Content-Type" => "application/json")
        @test length(raw) == 3
        # It really went to the driver — this is the difference from `headers`.
        @test sent[]["method"] == "rawResponseHeaders"

        close(fake.connection)
    end

    @testset "response(request) is a round trip that may answer nothing" begin
        fake = FakeDriver()
        req = fake_request(fake)

        @async begin
            msg = take!(fake.client_messages)
            reply_ok(fake, msg["id"], Dict{String,Any}())     # no response
        end
        @test within(() -> response(req)) === nothing

        close(fake.connection)
    end

    @testset "frame and redirected_from resolve their channel references" begin
        fake = FakeDriver()
        send_create(
            fake,
            "",
            "Frame",
            "frame@1",
            Dict{String,Any}("url" => "https://x.test/"),
        )
        @test timedwait(
            () -> Playwright.lookup_object(fake.connection, "frame@1") !== nothing,
            5.0,
        ) === :ok
        main = Playwright.lookup_object(fake.connection, "frame@1")

        first_req = fake_request(fake, "request@first")
        second = fake_request(
            fake,
            "request@second";
            init = Dict{String,Any}(
                "frame" => Dict("guid" => main.guid),
                "redirectedFrom" => Dict("guid" => first_req.guid),
            ),
        )

        @test frame(second) === main
        @test redirected_from(second) === first_req
        # ...and the chain terminates rather than looping.
        @test redirected_from(first_req) === nothing

        close(fake.connection)
    end

    @testset "RequestFailure carries the request and the engine's own text" begin
        fake = FakeDriver()
        req = fake_request(fake)
        failure = RequestFailure(req, "net::ERR_CONNECTION_REFUSED")

        @test request(failure) === req
        @test error_text(failure) == "net::ERR_CONNECTION_REFUSED"
        @test occursin("net::ERR_CONNECTION_REFUSED", sprint(show, failure))
        @test occursin("x.test", sprint(show, failure))

        close(fake.connection)
    end
end
