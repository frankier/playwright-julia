# Route interception, hermetically: the registry, the pattern union, the
# settle verbs' parameter building, and — first — the dispatcher's lifetime.
#
# The lifetime tests come first and get their own section. A
# dispatcher that leaks, dies or deadlocks presents to a user identically:
# requests hang and an unrelated `goto!` times out thirty seconds later. The
# tests therefore assert on the task and the registry directly rather than
# inferring from behaviour — "no route arrived" is also what a silently broken
# dispatcher looks like.
#
# the tripwire: no test here may use `sleep` to pass. Where a test must wait
# for the dispatcher to get to something, it waits on a condition with
# `timedwait`, never on a duration.

using Base64: base64decode
using JSON

using Playwright:
    route!,
    unroute!,
    unroute_all!,
    with_route,
    abort!,
    continue!,
    fulfill!,
    request,
    RouteRegistration,
    is_settled

"""
Wait for the most recent client message whose method is `method`, and return
it. Fails rather than hangs — the same rule as R3's timeouts.
"""
function until_message(requests, method; seconds = 10.0)
    found = Ref{Any}(nothing)
    ok = timedwait(seconds) do
        idx = findlast(m -> get(m, "method", "") == method, requests)
        idx === nothing && return false
        found[] = requests[idx]
        return true
    end
    ok === :ok || error("no `$method` message arrived within $(seconds)s")
    return found[]
end

"The registry for `owner`, or `nothing` when nothing is registered."
routing_registry(owner) = Playwright.registry_for(owner)

"Number of live registrations on `owner`."
registration_count(owner) =
    (r = routing_registry(owner)) === nothing ? 0 : length(r.registrations)

"Wait for `cond` to hold, failing rather than hanging. Never a bare sleep."
function until(cond, seconds = 10.0)
    ok = timedwait(cond, seconds) === :ok
    ok || error("condition never held within $(seconds)s")
    return true
end

"Build browser → context → page over a FakeDriver, with a route-capable owner."
function routing_fixture()
    fake = FakeDriver()
    conn = fake.connection
    requests = autoreply!(fake)
    send_create(fake, "", "Browser", "browser@1")
    send_create(fake, "browser@1", "BrowserContext", "context@1")
    send_create(fake, "context@1", "Page", "page@1")
    @test timedwait(() -> Playwright.lookup_object(conn, "page@1") !== nothing, 5.0) === :ok
    return (
        fake = fake,
        conn = conn,
        requests = requests,
        context = Playwright.lookup_object(conn, "context@1"),
        page = Playwright.lookup_object(conn, "page@1"),
    )
end

const ROUTE_GUID_SEQ = Ref(0)

"""
Deliver a `route` event carrying a Route whose request is for `target`.

`guid` is suffixed with a counter so no two routes in this file ever share one.
Reused guids let one testset's state decide another's outcome, which is how the
unbounded SETTLED_ROUTES leak first showed itself.

`navigation` sets `isNavigationRequest`, which HAR replay needs: the driver
answers a redirecting archive entry with `redirect` for a navigation and
`fulfill` for a sub-resource, and those are different code paths.
"""
function send_route(fake, owner_guid, guid, target; navigation::Bool = false)
    guid = "$(guid)-$(ROUTE_GUID_SEQ[] += 1)"
    send_create(
        fake,
        "",
        "Request",
        "req-$guid",
        Dict{String,Any}(
            "url" => target,
            "method" => "GET",
            "resourceType" => navigation ? "document" : "fetch",
            "isNavigationRequest" => navigation,
            "headers" => Any[],
        ),
    )
    send_create(
        fake,
        "",
        "Route",
        guid,
        Dict{String,Any}("request" => Dict("guid" => "req-$guid")),
    )
    @test timedwait(
        () -> Playwright.lookup_object(fake.connection, guid) !== nothing,
        5.0,
    ) === :ok
    send_event(fake, owner_guid, "route", Dict{String,Any}("route" => Dict("guid" => guid)))
    return Playwright.lookup_object(fake.connection, guid)
end

"The interception patterns of the most recent setNetworkInterceptionPatterns."
function last_patterns(requests)
    for msg in Iterators.reverse(requests)
        if get(msg, "method", "") == "setNetworkInterceptionPatterns"
            return [p["glob"] for p in msg["params"]["patterns"]]
        end
    end
    return nothing
end

@testset "routing" begin
    # --- The dispatcher's lifetime ---------------------------------------------

    @testset "the dispatcher spawns on the first registration, not before" begin
        f = routing_fixture()

        # Nothing registered: no registry, no task, no subscription. A package
        # that spawns a task per owner regardless leaks one per page.
        @test routing_registry(f.context) === nothing

        reg = route!(f.context, "**/api/*", route -> abort!(route))
        registry = routing_registry(f.context)
        @test registry !== nothing
        @test registry.task isa Task
        @test !istaskdone(registry.task)
        @test registry.subscription !== nothing

        # A second registration reuses the task rather than spawning another:
        # one per owner, not one per route.
        task = registry.task
        reg2 = route!(f.context, "**/other/*", route -> abort!(route))
        @test routing_registry(f.context).task === task
        @test registration_count(f.context) == 2

        unroute!(f.context, reg)
        unroute!(f.context, reg2)
        shutdown!(f.fake)
    end

    @testset "the dispatcher stops on the last unregistration" begin
        f = routing_fixture()
        reg1 = route!(f.context, "**/a", route -> abort!(route))
        reg2 = route!(f.context, "**/b", route -> abort!(route))
        task = routing_registry(f.context).task

        unroute!(f.context, reg1)
        # One left, so the task lives on.
        @test !istaskdone(task)
        @test routing_registry(f.context) !== nothing

        unroute!(f.context, reg2)
        # ...and now it is gone, waited for rather than assumed.
        @test istaskdone(task)
        @test routing_registry(f.context) === nothing

        shutdown!(f.fake)
    end

    @testset "a handler that throws does not kill the dispatcher" begin
        f = routing_fixture()
        seen = Channel{String}(10)
        reg = route!(f.context, "**/*", function (route)
            put!(seen, url(request(route)))
            error("handler is broken")
        end)
        task = routing_registry(f.context).task

        send_route(f.fake, "context@1", "route@1", "https://x.test/one")
        @test take_within!(seen, "a value on `seen`") == "https://x.test/one"

        # The dispatcher survived, and serves the *next* request — which is the
        # property that matters: a dead dispatcher hangs everything after it.
        @test !istaskdone(task)
        send_route(f.fake, "context@1", "route@2", "https://x.test/two")
        @test take_within!(seen, "a value on `seen`") == "https://x.test/two"
        @test !istaskdone(task)

        # ...and the exceptions surface on the caller's task at release.
        @test_throws CompositeException unroute!(f.context, reg)

        shutdown!(f.fake)
    end

    @testset "the dispatcher survives an owner that closes mid-route" begin
        f = routing_fixture()
        entered = Channel{Bool}(4)
        reg = route!(f.context, "**/*", function (route)
            put!(entered, true)
            # Settling a route whose owner has gone raises inside the handler;
            # that is a handler exception like any other and must not be fatal.
            continue!(route)
        end)
        task = routing_registry(f.context).task

        send_route(f.fake, "context@1", "route@1", "https://x.test/one")
        @test take_within!(entered, "a value on `entered`")
        @test !istaskdone(task)

        # Tear the connection down under the dispatcher, then release. The
        # handler's `continue!` fails against a dead connection — that is a
        # handler exception like any other, so it is collected and rethrown
        # here rather than killing the dispatcher where it happened.
        shutdown!(f.fake)
        @test_throws Exception unroute!(f.context, reg)

        # The point of the test: the task ended cleanly rather than being left
        # blocked on a channel nobody will ever feed.
        @test istaskdone(task)
    end

    # --- Registration and the pattern union ------------------------------------

    @testset "the driver gets the union, re-sent on every change" begin
        f = routing_fixture()

        reg1 = route!(f.context, "**/api/*", route -> abort!(route))
        @test until(() -> last_patterns(f.requests) == ["**/api/*"])

        reg2 = route!(f.context, "**/img/*", route -> abort!(route))
        @test until(() -> last_patterns(f.requests) == ["**/api/*", "**/img/*"])

        unroute!(f.context, reg1)
        @test until(() -> last_patterns(f.requests) == ["**/img/*"])

        unroute!(f.context, reg2)
        @test until(() -> last_patterns(f.requests) == String[])

        shutdown!(f.fake)
    end

    @testset "a Regex or predicate widens the union to **/*" begin
        f = routing_fixture()

        reg = route!(f.context, r"api", route -> abort!(route))
        @test until(() -> last_patterns(f.requests) == ["**/*"])
        unroute!(f.context, reg)

        reg = route!(f.context, u -> occursin("api", u), route -> abort!(route))
        @test until(() -> last_patterns(f.requests) == ["**/*"])
        unroute!(f.context, reg)

        # A glob alongside a Regex still widens: the union is what the driver
        # can express, and it cannot express the Regex.
        reg1 = route!(f.context, "**/api/*", route -> abort!(route))
        reg2 = route!(f.context, r"other", route -> abort!(route))
        @test until(() -> last_patterns(f.requests) == ["**/api/*", "**/*"])
        unroute!(f.context, reg1)
        unroute!(f.context, reg2)

        shutdown!(f.fake)
    end

    @testset "a Page routes through its own channel, not its context's" begin
        f = routing_fixture()
        reg = route!(f.page, "**/api/*", route -> abort!(route))

        sent = [
            m for
            m in f.requests if get(m, "method", "") == "setNetworkInterceptionPatterns"
        ]
        @test !isempty(sent)
        @test last(sent)["guid"] == "page@1"

        unroute!(f.page, reg)
        shutdown!(f.fake)
    end

    # --- Handler selection -----------------------------------------------------

    @testset "the newest matching registration wins" begin
        f = routing_fixture()
        winner = Channel{String}(4)

        old = route!(f.context, "**/*", route -> (put!(winner, "old"); abort!(route)))
        new = route!(f.context, "**/*", route -> (put!(winner, "new"); abort!(route)))

        send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        @test take_within!(winner, "a value on `winner`") == "new"

        # Remove the newest and the older one takes over — the registration
        # order is a stack, not a set.
        unroute!(f.context, new)
        send_route(f.fake, "context@1", "route@2", "https://x.test/b")
        @test take_within!(winner, "a value on `winner`") == "old"

        unroute!(f.context, old)
        shutdown!(f.fake)
    end

    @testset "a non-matching registration is skipped, not consulted" begin
        f = routing_fixture()
        ran = Channel{String}(4)

        miss = route!(f.context, "**/never/*", route -> (put!(ran, "miss"); abort!(route)))
        hit = route!(f.context, "**/api/*", route -> (put!(ran, "hit"); abort!(route)))

        send_route(f.fake, "context@1", "route@1", "https://x.test/api/items")
        @test take_within!(ran, "a value on `ran`") == "hit"

        unroute!(f.context, miss)
        unroute!(f.context, hit)
        shutdown!(f.fake)
    end

    @testset "handlers run sequentially, never concurrently" begin
        f = routing_fixture()
        # If two handlers ran at once this counter would see 2. Sequential
        # dispatch is what lets a user closure touch shared state unlocked.
        concurrent = Ref(0)
        peak = Ref(0)
        done = Channel{Bool}(8)
        gate = Channel{Bool}(8)

        reg = route!(f.context, "**/*", function (route)
            concurrent[] += 1
            peak[] = max(peak[], concurrent[])
            take_within!(gate, "a value on `gate`")                   # hold the handler open
            concurrent[] -= 1
            abort!(route)
            put!(done, true)
        end)

        send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        send_route(f.fake, "context@1", "route@2", "https://x.test/b")
        put!(gate, true)
        @test take_within!(done, "a value on `done`")
        put!(gate, true)
        @test take_within!(done, "a value on `done`")
        @test peak[] == 1

        unroute!(f.context, reg)
        shutdown!(f.fake)
    end

    # --- Exception collection --------------------------------------------------

    @testset "one handler exception is rethrown directly" begin
        f = routing_fixture()
        ran = Channel{Bool}(4)
        reg = route!(f.context, "**/*", function (route)
            put!(ran, true)
            throw(ArgumentError("just the one"))
        end)

        send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        @test take_within!(ran, "a value on `ran`")

        err = try
            unroute!(f.context, reg)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test err.msg == "just the one"

        shutdown!(f.fake)
    end

    @testset "several become a CompositeException" begin
        f = routing_fixture()
        ran = Channel{Bool}(8)
        reg = route!(f.context, "**/*", function (route)
            put!(ran, true)
            error("boom")
        end)

        send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        @test take_within!(ran, "a value on `ran`")
        send_route(f.fake, "context@1", "route@2", "https://x.test/b")
        @test take_within!(ran, "a value on `ran`")

        err = try
            unroute!(f.context, reg)
            nothing
        catch e
            e
        end
        @test err isa CompositeException
        @test length(err.exceptions) == 2

        shutdown!(f.fake)
    end

    @testset "unroute! waits for an in-flight route to settle" begin
        f = routing_fixture()
        entered = Channel{Bool}(4)
        release = Channel{Bool}(4)
        settled = Ref(false)

        reg = route!(f.context, "**/*", function (route)
            put!(entered, true)
            take_within!(release, "a value on `release`")          # hold the handler open, mid-flight
            abort!(route)
            settled[] = true
        end)

        send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        @test take_within!(entered, "a value on `entered`")                 # the handler is running now
        @test settled[] == false

        # unroute! must not return while that handler is still going. Prove it
        # by unrouting on another task and checking it has not returned...
        returned = Ref(false)
        waiter = @async begin
            unroute!(f.context, reg)
            returned[] = true
        end
        @test timedwait(() -> returned[], 1.0) !== :ok
        @test returned[] == false

        # ...then letting the handler finish and watching it return.
        put!(release, true)
        @test timedwait(() -> returned[], 10.0) === :ok
        @test settled[] == true

        await(waiter)
        shutdown!(f.fake)
    end

    @testset "with_route unregisters even when the body throws" begin
        f = routing_fixture()
        reg_count_before = registration_count(f.context)

        @test_throws ErrorException with_route(f.context, "**/*", route -> abort!(route)) do
            error("the body failed")
        end

        # The registration is gone despite the throw, and so is the dispatcher.
        @test registration_count(f.context) == reg_count_before
        @test routing_registry(f.context) === nothing

        shutdown!(f.fake)
    end

    @testset "with_route returns the body's value" begin
        f = routing_fixture()
        result = with_route(f.context, "**/*", route -> abort!(route)) do
            42
        end
        @test result == 42
        @test routing_registry(f.context) === nothing
        shutdown!(f.fake)
    end

    @testset "unroute! is idempotent and unroute_all! clears everything" begin
        f = routing_fixture()
        reg = route!(f.context, "**/a", route -> abort!(route))
        route!(f.context, "**/b", route -> abort!(route))

        unroute!(f.context, reg)
        unroute!(f.context, reg)          # again: a no-op, not an error
        @test registration_count(f.context) == 1

        unroute_all!(f.context)
        @test routing_registry(f.context) === nothing
        unroute_all!(f.context)           # nothing registered: still a no-op
        @test routing_registry(f.context) === nothing

        shutdown!(f.fake)
    end

    # --- The release hook --------------------------------------------------
    #
    # A registration can own a resource — HAR replay's open archive and its temp
    # directory — whose lifetime is the registration's. The hook is what makes
    # `unroute!` the owner of that lifetime, so these tests are about *when* it
    # runs and how many times, not about what it does.

    @testset "a release hook runs exactly once on unroute!" begin
        f = routing_fixture()
        runs = Ref(0)
        reg = route!(f.context, "**/*", route -> abort!(route); release = () -> runs[] += 1)

        @test runs[] == 0                 # not at registration
        unroute!(f.context, reg)
        @test runs[] == 1
        unroute!(f.context, reg)          # idempotent: the hook does not run twice
        @test runs[] == 1

        shutdown!(f.fake)
    end

    @testset "unroute_all! runs every registration's release hook" begin
        f = routing_fixture()
        a = Ref(0)
        b = Ref(0)
        route!(f.context, "**/a", route -> abort!(route); release = () -> a[] += 1)
        route!(f.context, "**/b", route -> abort!(route); release = () -> b[] += 1)

        unroute_all!(f.context)
        @test a[] == 1
        @test b[] == 1

        shutdown!(f.fake)
    end

    @testset "with_route runs the release hook even when the body throws" begin
        f = routing_fixture()
        runs = Ref(0)

        @test_throws ErrorException with_route(
            f.context,
            "**/*",
            route -> abort!(route);
            release = () -> runs[] += 1,
        ) do
            error("the body failed")
        end
        @test runs[] == 1

        # ...and on the path where it does not throw.
        with_route(
            f.context,
            "**/*",
            route -> abort!(route);
            release = () -> runs[] += 1,
        ) do
            42
        end
        @test runs[] == 2

        shutdown!(f.fake)
    end

    @testset "a registration without a release hook is unchanged" begin
        f = routing_fixture()
        reg = route!(f.context, "**/*", route -> abort!(route))
        @test reg.release === nothing
        unroute!(f.context, reg)          # no hook, and no error for the want of one
        @test routing_registry(f.context) === nothing
        shutdown!(f.fake)
    end

    @testset "the release hook runs after the handler's exception is collected" begin
        # Ordering matters: the hook releases what the handler was using,
        # so it must run after the last dispatch and not before. Asserted through
        # the exception path because that is where an early release would show
        # up as a resource freed under a running handler.
        f = routing_fixture()
        runs = Ref(0)
        reg = route!(
            f.context,
            "**/*",
            route -> error("handler blew up");
            release = () -> runs[] += 1,
        )
        send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        until(() -> !isempty(reg.exceptions))

        @test_throws ErrorException unroute!(f.context, reg)
        @test runs[] == 1                 # ran despite the rethrow

        shutdown!(f.fake)
    end

    # --- The settle verbs --------------------------------------------------

    @testset "abort! validates its error code client-side" begin
        f = routing_fixture()
        route = send_route(f.fake, "context@1", "route@1", "https://x.test/a")

        @test_throws ArgumentError abort!(route; error_code = "failled")
        # ...and the typo did not settle it, so a correct call still can.
        @test !is_settled(route)
        abort!(route; error_code = "connectionrefused")
        @test is_settled(route)

        shutdown!(f.fake)
    end

    @testset "a route settles exactly once" begin
        f = routing_fixture()
        route = send_route(f.fake, "context@1", "route@1", "https://x.test/a")

        continue!(route)
        @test is_settled(route)
        @test_throws ArgumentError continue!(route)
        @test_throws ArgumentError abort!(route)
        @test_throws ArgumentError fulfill!(route; body = "late")

        shutdown!(f.fake)
    end

    @testset "fulfill! rejects two body sources at the call site" begin
        f = routing_fixture()
        route = send_route(f.fake, "context@1", "route@1", "https://x.test/a")

        err = try
            fulfill!(route; body = "a", json = Dict("b" => 1))
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("body", err.msg) && occursin("json", err.msg)
        # The rejection happened before anything was sent, so the route is
        # still settleable — an ArgumentError must not consume the route.
        @test !is_settled(route)

        shutdown!(f.fake)
    end

    @testset "fulfill! builds the parameters the protocol expects" begin
        f = routing_fixture()

        route = send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        fulfill!(route; json = Dict("items" => [1, 2]))
        sent = until_message(f.requests, "fulfill")
        @test sent["params"]["body"] == JSON.json(Dict("items" => [1, 2]))
        @test sent["params"]["isBase64"] == false
        @test ("content-type" => "application/json") in
              [h["name"] => h["value"] for h in sent["params"]["headers"]]

        route2 = send_route(f.fake, "context@1", "route@2", "https://x.test/b")
        fulfill!(route2; status = 404, body = "nope")
        sent2 = until_message(f.requests, "fulfill")
        @test sent2["params"]["status"] == 404
        @test sent2["params"]["body"] == "nope"
        @test sent2["params"]["isBase64"] == false

        # Bytes go base64, which is the difference a String cannot express.
        route3 = send_route(f.fake, "context@1", "route@3", "https://x.test/c")
        fulfill!(route3; body = UInt8[0x00, 0xff])
        sent3 = until_message(f.requests, "fulfill")
        @test sent3["params"]["isBase64"] == true
        @test base64decode(sent3["params"]["body"]) == UInt8[0x00, 0xff]

        shutdown!(f.fake)
    end

    @testset "fulfill! infers content type from a path's extension" begin
        f = routing_fixture()
        dir = mktempdir()
        file = joinpath(dir, "mock.json")
        write(file, "{\"from\":\"disk\"}")

        route = send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        fulfill!(route; path = file)
        sent = until_message(f.requests, "fulfill")
        @test ("content-type" => "application/json") in
              [h["name"] => h["value"] for h in sent["params"]["headers"]]
        @test String(base64decode(sent["params"]["body"])) == "{\"from\":\"disk\"}"

        # ...and an explicit content_type beats the inference.
        route2 = send_route(f.fake, "context@1", "route@2", "https://x.test/b")
        fulfill!(route2; path = file, content_type = "text/plain")
        sent2 = until_message(f.requests, "fulfill")
        @test ("content-type" => "text/plain") in
              [h["name"] => h["value"] for h in sent2["params"]["headers"]]

        shutdown!(f.fake)
    end

    @testset "fulfill! names a bad body type rather than sending it" begin
        f = routing_fixture()
        route = send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        @test_throws ArgumentError fulfill!(route; body = 42)
        @test_throws ArgumentError fulfill!(route; response = "not an APIResponse")
        @test !is_settled(route)
        shutdown!(f.fake)
    end

    @testset "continue! sends its rewrites in the protocol's shape" begin
        f = routing_fixture()

        route = send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        continue!(
            route;
            url = "https://x.test/elsewhere",
            method = "POST",
            headers = Dict("X-Test" => "1"),
            post_data = "hello",
        )
        sent = until_message(f.requests, "continue")
        @test sent["params"]["url"] == "https://x.test/elsewhere"
        @test sent["params"]["method"] == "POST"
        @test sent["params"]["isFallback"] == false
        @test [h["name"] => h["value"] for h in sent["params"]["headers"]] == ["X-Test" => "1"]
        @test base64decode(sent["params"]["postData"]) == Vector{UInt8}("hello")

        shutdown!(f.fake)
    end

    @testset "abort! sends its error code" begin
        f = routing_fixture()
        route = send_route(f.fake, "context@1", "route@1", "https://x.test/a")
        abort!(route)
        sent = until_message(f.requests, "abort")
        @test sent["params"]["errorCode"] == "failed"
        shutdown!(f.fake)
    end

    @testset "request(route) and url(route) read the initializer" begin
        f = routing_fixture()
        route = send_route(f.fake, "context@1", "route@1", "https://x.test/api/items")
        @test request(route) isa Playwright.Request
        @test url(route) == "https://x.test/api/items"
        @test url(request(route)) == url(route)
        shutdown!(f.fake)
    end
end
