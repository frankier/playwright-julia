# T3: event registry and subscription lifetime. Hermetic — canned protocol
# traces over FakeDriver, no driver and no browser.
#
# Lifetime is asserted directly against the registry rather than inferred from
# behaviour (SC 7): "no event arrived" is also what a silently-broken
# subscription looks like, so the tests check the registry and the buffer.

"""
Reply `ok` to every request the client sends, forever.

Opt-in events (`:console`) make `expect_event` send `updateSubscription` and
wait for the reply, so without a responder on the other end the fake driver
deadlocks the test rather than failing it.


Returns the vector it records each request into, so a test can assert on what
was sent.
"""
function autoreply!(fake::FakeDriver)
    seen = Vector{Any}()
    @async try
        while true
            msg = take!(fake.client_messages)
            push!(seen, msg)
            reply_ok(fake, msg["id"], Dict{String,Any}())
        end
    catch
    end
    return seen
end

"Build browser → context → page over a FakeDriver."
function event_fixture()
    fake = FakeDriver()
    conn = fake.connection
    requests = autoreply!(fake)
    send_create(fake, "", "Browser", "browser@1")
    send_create(fake, "browser@1", "BrowserContext", "context@1")
    send_create(fake, "context@1", "Page", "page@1")
    send_create(fake, "context@1", "Page", "page@2")
    @test timedwait(() -> Playwright.lookup_object(conn, "page@2") !== nothing, 5.0) === :ok
    return (
        fake = fake,
        conn = conn,
        requests = requests,
        browser = Playwright.lookup_object(conn, "browser@1"),
        context = Playwright.lookup_object(conn, "context@1"),
        page = Playwright.lookup_object(conn, "page@1"),
        page2 = Playwright.lookup_object(conn, "page@2"),
    )
end

"Fire a named event on `guid` from the driver side."
send_event(fake, guid, method, params = Dict{String,Any}()) =
    driver_send(fake, Dict("guid" => guid, "method" => method, "params" => params))

"Number of subscriptions the connection currently holds."
subscription_count(conn) = sum(length, values(conn.subscriptions); init = 0)

@testset "event registry" begin
    @testset "a subscribed event is delivered to the buffer" begin
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        send_event(f.fake, "page@1", "console", Dict("text" => "hello"))
        @test timedwait(() -> isready(sub.channel), 5.0) === :ok
        @test take!(sub.channel)["text"] == "hello"
        close(f.conn)
    end

    @testset "events route to the right subscriber only" begin
        f = event_fixture()
        on_page = Playwright.subscribe(f.page, "console")
        on_page2 = Playwright.subscribe(f.page2, "console")
        on_other_event = Playwright.subscribe(f.page, "close")

        send_event(f.fake, "page@1", "console", Dict("text" => "for page 1"))
        @test timedwait(() -> isready(on_page.channel), 5.0) === :ok
        @test take!(on_page.channel)["text"] == "for page 1"

        # A sibling page and a different event name on the same page must not
        # have seen it.
        @test !isready(on_page2.channel)
        @test !isready(on_other_event.channel)
        close(f.conn)
    end

    @testset "two subscriptions on the same owner and event both receive it" begin
        f = event_fixture()
        a = Playwright.subscribe(f.page, "console")
        b = Playwright.subscribe(f.page, "console")
        send_event(f.fake, "page@1", "console", Dict("text" => "broadcast"))
        @test timedwait(() -> isready(a.channel) && isready(b.channel), 5.0) === :ok
        @test take!(a.channel)["text"] == "broadcast"
        @test take!(b.channel)["text"] == "broadcast"
        close(f.conn)
    end

    @testset "an event for an unknown guid never kills the read loop" begin
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        send_event(f.fake, "no-such-guid@9", "console", Dict("text" => "orphan"))
        send_event(f.fake, "page@1", "console", Dict("text" => "still alive"))
        # The connection must still be dispatching after the orphan.
        @test timedwait(() -> isready(sub.channel), 5.0) === :ok
        @test take!(sub.channel)["text"] == "still alive"
        close(f.conn)
    end

    @testset "no event is dropped — 5 000 messages, 5 000 received" begin
        # SC 6. Buffers are unbounded precisely so this holds.
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        for i = 1:5_000
            send_event(f.fake, "page@1", "console", Dict("n" => i))
        end
        @test timedwait(() -> Base.n_avail(sub.channel) == 5_000, 60.0) === :ok
        received = [take!(sub.channel)["n"] for _ = 1:5_000]
        @test length(received) == 5_000
        @test received == collect(1:5_000)   # and in order
        close(f.conn)
    end

    @testset "close(sub) detaches from the registry and empties the buffer" begin
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        send_event(f.fake, "page@1", "console", Dict("text" => "buffered"))
        @test timedwait(() -> isready(sub.channel), 5.0) === :ok

        close(sub)
        # Detached...
        @test subscription_count(f.conn) == 0
        # ...and emptied, not merely detached: the buffered payloads must be
        # garbage now, not at some later GC of the handle.
        @test Base.n_avail(sub.channel) == 0
        @test sub.closed
        close(f.conn)
    end

    @testset "close(sub) is idempotent" begin
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        close(sub)
        @test close(sub) === nothing
        @test subscription_count(f.conn) == 0
        close(f.conn)
    end

    @testset "dispatch to a closed subscription is a no-op, not an error" begin
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        close(sub)
        send_event(f.fake, "page@1", "console", Dict("text" => "after close"))
        # Still dispatching afterwards: a fresh subscription receives.
        fresh = Playwright.subscribe(f.page, "console")
        send_event(f.fake, "page@1", "console", Dict("text" => "fresh"))
        @test timedwait(() -> isready(fresh.channel), 5.0) === :ok
        @test take!(fresh.channel)["text"] == "fresh"
        @test Base.n_avail(sub.channel) == 0
        close(f.conn)
    end

    @testset "closing an owner closes the subscriptions beneath it" begin
        f = event_fixture()
        on_page = Playwright.subscribe(f.page, "console")
        on_context = Playwright.subscribe(f.context, "page")
        @test subscription_count(f.conn) == 2

        # Disposing the context cascades to its pages, so both go.
        send_dispose(f.fake, "context@1")
        @test timedwait(() -> subscription_count(f.conn) == 0, 5.0) === :ok
        @test on_page.closed
        @test on_context.closed
        # Detached, but NOT drained — see close_subscriptions_locked. The
        # connection has dropped its reference, which is what bounds the
        # buffer; emptying it here would discard a `close` event that arrived
        # in the same breath as the dispose.
        @test !haskey(f.conn.subscriptions, "page@1")
        close(f.conn)
    end

    @testset "a dropped page does not keep its backlog alive" begin
        # D1a: buffers are unbounded, so an owner going away has to drop them.
        # "Drop" means the *connection* lets go — that is what makes the
        # backlog collectable. The buffer itself stays readable for whoever
        # still holds the handle, and dies with it; draining eagerly here would
        # destroy a `close` payload that landed just before the dispose.
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        for i = 1:100
            send_event(f.fake, "page@1", "console", Dict("n" => i))
        end
        @test timedwait(() -> Base.n_avail(sub.channel) == 100, 10.0) === :ok

        send_dispose(f.fake, "page@1")
        @test timedwait(() -> sub.closed, 5.0) === :ok
        @test subscription_count(f.conn) == 0
        @test !haskey(f.conn.subscriptions, "page@1")
        # ...and an explicit close still empties it, as it always did.
        close(sub)
        @test Base.n_avail(sub.channel) == 0
        close(f.conn)
    end

    @testset "a wait on a closed owner gives up at once, not at the timeout" begin
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        send_dispose(f.fake, "page@1")
        @test timedwait(() -> sub.closed, 5.0) === :ok
        elapsed = @elapsed @test_throws Playwright.TargetClosedError Playwright.take_event!(
            sub,
            :console,
            30_000,
            nothing,
        )
        @test elapsed < 5.0
        close(f.conn)
    end

    @testset "a buffered payload survives the dispose that follows it" begin
        # The `:close` case in miniature: the driver emits the event and then
        # disposes the object, so anything already buffered must still be
        # readable afterwards.
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        send_event(f.fake, "page@1", "console", Dict("text" => "last words"))
        @test timedwait(() -> Base.n_avail(sub.channel) == 1, 5.0) === :ok
        send_dispose(f.fake, "page@1")
        @test timedwait(() -> sub.closed, 5.0) === :ok
        @test Playwright.take_event!(sub, :console, 1_000, nothing)["text"] == "last words"
        close(f.conn)
    end

    @testset "closing the connection clears the whole registry" begin
        # playwright() teardown must not leave buffers behind.
        f = event_fixture()
        Playwright.subscribe(f.page, "console")
        Playwright.subscribe(f.context, "page")
        @test subscription_count(f.conn) == 2

        close(f.conn)
        @test timedwait(() -> subscription_count(f.conn) == 0, 5.0) === :ok
    end

    @testset "subscriptions are not shared between connections" begin
        # Same lesson as the timeout table: guids repeat across driver sessions.
        a = event_fixture()
        b = event_fixture()
        sub_a = Playwright.subscribe(a.page, "console")

        send_event(b.fake, "page@1", "console", Dict("text" => "other session"))
        send_event(a.fake, "page@1", "console", Dict("text" => "this session"))
        @test timedwait(() -> isready(sub_a.channel), 5.0) === :ok
        @test take!(sub_a.channel)["text"] == "this session"
        @test Base.n_avail(sub_a.channel) == 0

        close(a.conn)
        close(b.conn)
    end
end

# --- T4: the user-facing surface over the T3 registry ----------------------
#
# Still hermetic: canned traces prove the name mapping, payload mapping,
# predicate filtering and lifetime. Only the things that need a real browser
# (popup timing, a synchronously-fired console message) go to the smoke suite.

@testset "expect_event / wait_for_event" begin
    @testset "an event fired inside the body is caught, not missed" begin
        # The whole reason expect_event takes a do-block: subscribing must
        # happen before the body runs, or an event the body triggers
        # synchronously is gone before anyone is listening (SC 6).
        f = event_fixture()
        msg = expect_event(f.context, :console) do
            send_event(
                f.fake,
                "context@1",
                "console",
                Dict("type" => "log", "text" => "shouted"),
            )
        end
        @test msg isa Playwright.ConsoleMessage
        @test msg.text == "shouted"
        close(f.conn)
    end

    @testset "the block's own return value is not what comes back" begin
        f = event_fixture()
        got = expect_event(f.context, :console) do
            send_event(f.fake, "context@1", "console", Dict("text" => "x"))
            :block_value
        end
        @test got isa Playwright.ConsoleMessage
        close(f.conn)
    end

    @testset "event names accept Symbol, wire spelling and String" begin
        for name in (:console, :Console, "console")
            f = event_fixture()
            msg = expect_event(f.context, name) do
                send_event(f.fake, "context@1", "console", Dict("text" => "hi"))
            end
            @test msg.text == "hi"
            close(f.conn)
        end
        # camelCase wire spellings normalise to the same event
        f = event_fixture()
        send_create(f.fake, "page@1", "Frame", "frame@9")
        for name in (:frameattached, :frameAttached, "frameAttached")
            got = expect_event(f.page, name) do
                send_event(
                    f.fake,
                    "page@1",
                    "frameAttached",
                    Dict("frame" => Dict("guid" => "frame@9")),
                )
            end
            @test got isa Playwright.Frame
        end
        close(f.conn)
    end

    @testset "payloads arrive as the milestone's own types" begin
        f = event_fixture()

        # :page hands back a Page, resolved through the registry
        popup = expect_event(f.context, :page) do
            send_event(f.fake, "context@1", "page", Dict("page" => Dict("guid" => "page@2")))
        end
        @test popup === f.page2

        # :close on a page hands back the page itself
        closed = expect_event(f.page, :close) do
            send_event(f.fake, "page@1", "close")
        end
        @test closed === f.page

        # :pageerror hands back a PageError
        err = expect_event(f.context, :pageerror) do
            send_event(
                f.fake,
                "context@1",
                "pageError",
                # Shape probed off the live driver: the SerializedError sits
                # one level deeper than in the buffered `page_errors` getter.
                Dict(
                    "error" => Dict(
                        "error" => Dict("message" => "boom", "name" => "TypeError"),
                    ),
                    "page" => Dict("guid" => "page@1"),
                ),
            )
        end
        @test err isa Playwright.PageError
        @test err.message == "boom"
        @test err.name == "TypeError"
        close(f.conn)
    end

    @testset "a console payload carries type, text and location" begin
        f = event_fixture()
        msg = expect_event(f.context, :console) do
            send_event(
                f.fake,
                "context@1",
                "console",
                Dict(
                    "type" => "error",
                    "text" => "bad",
                    "timestamp" => 1234.0,
                    "location" => Dict(
                        "url" => "http://x/a.js",
                        "lineNumber" => 7,
                        "columnNumber" => 3,
                    ),
                ),
            )
        end
        @test msg.type == "error"
        @test msg.text == "bad"
        @test msg.location.url == "http://x/a.js"
        @test msg.location.line == 7
        @test msg.location.column == 3
        @test msg.timestamp == 1234.0
        close(f.conn)
    end

    @testset "opt-in events tell the driver to start and stop sending them" begin
        # `console` is silent until the client asks for it
        # (browserContext.yml:264). Subscribing to the buffer alone buys a
        # 30 s wait and nothing else, so the enable has to reach the wire.
        f = event_fixture()
        expect_event(f.context, :console) do
            send_event(f.fake, "context@1", "console", Dict("text" => "x"))
        end
        updates = [
            r for r in f.requests if
            get(r, "method", "") == "updateSubscription" && r["guid"] == "context@1"
        ]
        @test length(updates) == 2
        @test updates[1]["params"]["event"] == "console"
        @test updates[1]["params"]["enabled"] == true
        @test updates[2]["params"]["enabled"] == false
        close(f.conn)
    end

    @testset "an event that needs no opt-in does not send one" begin
        f = event_fixture()
        expect_event(f.context, :page) do
            send_event(
                f.fake,
                "context@1",
                "page",
                Dict("page" => Dict("guid" => "page@2")),
            )
        end
        @test isempty([
            r for r in f.requests if get(r, "method", "") == "updateSubscription"
        ])
        close(f.conn)
    end

    @testset "nested subscriptions do not switch each other off" begin
        # Ref-counting: the inner block finishing must not disable the event
        # the outer block is still waiting on.
        f = event_fixture()
        outer = with_events(f.context, :console) do _stream
            expect_event(f.context, :console) do
                send_event(f.fake, "context@1", "console", Dict("text" => "inner"))
            end
            # The inner block has closed; the driver must still be sending.
            disables = [
                r for
                r in f.requests if get(r, "method", "") == "updateSubscription" &&
                r["params"]["enabled"] == false
            ]
            @test isempty(disables)
            :ok
        end
        @test outer === :ok
        # ...and once the outer block ends, the last one out turns it off.
        disables = [
            r for r in f.requests if get(r, "method", "") == "updateSubscription" &&
            r["params"]["enabled"] == false
        ]
        @test length(disables) == 1
        close(f.conn)
    end

    @testset "a predicate skips events that do not match" begin
        f = event_fixture()
        msg = expect_event(f.context, :console; predicate = m -> m.text == "second") do
            send_event(f.fake, "context@1", "console", Dict("text" => "first"))
            send_event(f.fake, "context@1", "console", Dict("text" => "second"))
        end
        @test msg.text == "second"
        close(f.conn)
    end

    @testset "a wait that never matches raises TimeoutError" begin
        f = event_fixture()
        @test_throws Playwright.TimeoutError expect_event(
            f.context,
            :console;
            timeout = 200,
        ) do
        end
        # ...and the message says which event gave up
        try
            expect_event(f.context, :console; timeout = 200) do
            end
        catch e
            @test occursin("console", e.message)
        end
        close(f.conn)
    end

    @testset "the timeout comes from the cascade when none is given" begin
        f = event_fixture()
        set_default_timeout!(f.context, 200)
        elapsed = @elapsed @test_throws Playwright.TimeoutError expect_event(
            f.context,
            :console,
        ) do
        end
        @test elapsed < 5.0
        close(f.conn)
    end

    @testset "an unsupported event names itself and says it is deferred" begin
        f = event_fixture()
        # M6 T12 removed :request, :response, :requestfinished and
        # :requestfailed from DEFERRED_EVENTS (SC 13) — they are supported now,
        # and are asserted as such below. What remains deferred is what still
        # has no wrapper type.
        for bad in (:websocket, :worker, :bindingcall)
            err = try
                expect_event(f.context, bad) do
                end
                nothing
            catch e
                e
            end
            @test err isa ArgumentError
            @test occursin(String(bad), lowercase(err.msg))
            @test occursin("deferred", lowercase(err.msg))
        end
        # SC 13: the four network events are gone from DEFERRED_EVENTS, so
        # asking for one is no longer an ArgumentError. It reaches the wait and
        # times out instead, which is what "supported but nothing happened"
        # looks like.
        for supported in (:request, :response, :requestfinished, :requestfailed)
            @test haskey(Playwright.CONTEXT_EVENTS, supported)
            @test !haskey(Playwright.DEFERRED_EVENTS, supported)
            # ...and on a Page too, where it is the context subscription with a
            # page filter (D11).
            @test haskey(Playwright.events_for(f.page), supported)
        end

        # M7 T12 did the same for :download, which is a *Page* event -- so on a
        # context it is now an ordinary "no such event for this owner", and
        # must no longer claim to be deferred.
        @test haskey(Playwright.events_for(f.page), :download)
        @test !haskey(Playwright.DEFERRED_EVENTS, :download)
        # M7 T14 took :dialog out too. It is a *context* event, and it is
        # reachable -- but on_dialog!/with_dialog is the documented path,
        # because subscribing is what disarms the driver's auto-dismiss.
        @test !haskey(Playwright.DEFERRED_EVENTS, :dialog)
        err = try
            expect_event(f.context, :download) do
            end
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test !occursin("deferred", lowercase(err.msg))

        # An event that simply does not exist is also an ArgumentError, but
        # must not claim to be deferred — it is a typo, not a roadmap entry.
        err = try
            expect_event(f.context, :not_an_event) do
            end
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test !occursin("deferred", lowercase(err.msg))
        close(f.conn)
    end

    # M7 T18 (D14). The table had drifted: :download claimed "Artifact is not
    # wrapped yet" long after Artifact was wrapped, so the error told users
    # something false about why their event was unsupported. The drift was the
    # finding, not the entry -- a table that drifts once will drift again.
    @testset "the deferred table names only unsupported events (SC 23, 24)" begin
        f = event_fixture()

        # The gate itself, on both owners.
        for owner in (f.page, f.context)
            @test Playwright.deferred_table_is_honest(Playwright.DEFERRED_EVENTS, owner) ==
                  Symbol[]
        end

        # SC 24: prove the gate fails when it should. Re-adding a supported
        # event to a *copy* of the table must be caught -- a gate nobody has
        # watched fail is a gate nobody knows works.
        tampered = merge(
            Playwright.DEFERRED_EVENTS,
            Dict(:download => "pretend this is still deferred"),
        )
        @test Playwright.deferred_table_is_honest(tampered, f.page) == [:download]

        # Every surviving entry says something true. :route is the one that
        # needed rewriting rather than deleting -- Route IS wrapped, it is
        # simply not offered as an event.
        @test occursin("route!", Playwright.DEFERRED_EVENTS[:route])
        @test !occursin("not wrapped", Playwright.DEFERRED_EVENTS[:route])
        for key in (:worker, :websocket, :bindingcall)
            @test occursin("no accessors yet", Playwright.DEFERRED_EVENTS[key])
        end

        # And the three Part C events really are gone.
        for gone in (:download, :dialog, :filechooser)
            @test !haskey(Playwright.DEFERRED_EVENTS, gone)
        end
        close(f.conn)
    end

    @testset "an event on the wrong owner type is rejected" begin
        f = event_fixture()
        # :console lives on the context, not the page
        @test_throws ArgumentError expect_event(f.page, :console) do
        end
        close(f.conn)
    end

    @testset "the registry is empty after the block, however it ends" begin
        f = event_fixture()
        @test subscription_count(f.conn) == 0

        expect_event(f.context, :console) do
            send_event(f.fake, "context@1", "console", Dict("text" => "x"))
        end
        @test subscription_count(f.conn) == 0

        # ...after a timeout
        try
            expect_event(f.context, :console; timeout = 100) do
            end
        catch
        end
        @test subscription_count(f.conn) == 0

        # ...and after the body throws, which must propagate the body's error
        # rather than a timeout.
        @test_throws ErrorException expect_event(f.context, :console) do
            error("body blew up")
        end
        @test subscription_count(f.conn) == 0
        close(f.conn)
    end

    @testset "wait_for_event waits for something already in flight" begin
        f = event_fixture()
        sub_ready = Ref(false)
        waiter = @async wait_for_event(f.context, :console; timeout = 5_000)
        @test timedwait(() -> subscription_count(f.conn) == 1, 5.0) === :ok
        send_event(f.fake, "context@1", "console", Dict("text" => "later"))
        @test fetch(waiter).text == "later"
        @test subscription_count(f.conn) == 0
        close(f.conn)
    end

    @testset "with_events collects every event in the block" begin
        f = event_fixture()
        collected = with_events(f.context, :console) do events
            for i = 1:5
                send_event(f.fake, "context@1", "console", Dict("text" => "m$i"))
            end
            # The buffer is unbounded, so nothing is dropped while we wait.
            # `length` peeks; `pending_events` drains, so polling on the latter
            # would eat the very events it is waiting for.
            @test timedwait(() -> length(events) == 5, 5.0) === :ok
            pending_events(events)
        end
        @test [m.text for m in collected] == ["m1", "m2", "m3", "m4", "m5"]
        @test subscription_count(f.conn) == 0
        close(f.conn)
    end

    @testset "with_events closes its subscription even when the block throws" begin
        f = event_fixture()
        @test_throws ErrorException with_events(f.context, :console) do events
            error("nope")
        end
        @test subscription_count(f.conn) == 0
        close(f.conn)
    end

    @testset "next_event pulls one payload at a time" begin
        f = event_fixture()
        with_events(f.context, :console) do events
            send_event(f.fake, "context@1", "console", Dict("text" => "a"))
            send_event(f.fake, "context@1", "console", Dict("text" => "b"))
            @test next_event(events; timeout = 5_000).text == "a"
            @test next_event(events; timeout = 5_000).text == "b"
            @test_throws Playwright.TimeoutError next_event(events; timeout = 100)
        end
        close(f.conn)
    end

    @testset "no event is dropped across a 5 000-message burst" begin
        f = event_fixture()
        with_events(f.context, :console) do events
            for i = 1:5000
                send_event(f.fake, "context@1", "console", Dict("text" => "m$i"))
            end
            @test timedwait(() -> length(events) == 5000, 60.0) === :ok
            texts = [m.text for m in pending_events(events)]
            @test texts[1] == "m1"
            @test texts[end] == "m5000"
        end
        close(f.conn)
    end

    @testset "framedetached still reaches subscribers despite internal handling" begin
        # dispatch intercepts frameDetached to prune the frame from the page.
        # If that interception swallowed the event, a subscriber would never
        # see it — and the payload must resolve before the frame is disposed.
        f = event_fixture()
        send_create(f.fake, "page@1", "Frame", "frame@7")
        @test timedwait(
            () -> Playwright.lookup_object(f.conn, "frame@7") !== nothing,
            5.0,
        ) === :ok
        frame = Playwright.lookup_object(f.conn, "frame@7")

        got = expect_event(f.page, :framedetached) do
            send_event(
                f.fake,
                "page@1",
                "frameDetached",
                Dict("frame" => Dict("guid" => "frame@7")),
            )
        end
        @test got === frame
        # ...and the internal handling still happened
        @test timedwait(
            () -> Playwright.lookup_object(f.conn, "frame@7") === nothing,
            5.0,
        ) === :ok
        close(f.conn)
    end
end
