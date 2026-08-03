# T3: event registry and subscription lifetime. Hermetic — canned protocol
# traces over FakeDriver, no driver and no browser.
#
# Lifetime is asserted directly against the registry rather than inferred from
# behaviour (SC 7): "no event arrived" is also what a silently-broken
# subscription looks like, so the tests check the registry and the buffer.

"Build browser → context → page over a FakeDriver."
function event_fixture()
    fake = FakeDriver()
    conn = fake.connection
    send_create(fake, "", "Browser", "browser@1")
    send_create(fake, "browser@1", "BrowserContext", "context@1")
    send_create(fake, "context@1", "Page", "page@1")
    send_create(fake, "context@1", "Page", "page@2")
    @test timedwait(() -> Playwright.lookup_object(conn, "page@2") !== nothing, 5.0) === :ok
    return (
        fake = fake,
        conn = conn,
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
        @test Base.n_avail(on_page.channel) == 0
        close(f.conn)
    end

    @testset "a dropped page does not keep its backlog alive" begin
        # D1a: buffers are unbounded, so an owner going away has to drop them.
        f = event_fixture()
        sub = Playwright.subscribe(f.page, "console")
        for i = 1:100
            send_event(f.fake, "page@1", "console", Dict("n" => i))
        end
        @test timedwait(() -> Base.n_avail(sub.channel) == 100, 10.0) === :ok

        send_dispose(f.fake, "page@1")
        @test timedwait(() -> sub.closed, 5.0) === :ok
        @test Base.n_avail(sub.channel) == 0
        @test subscription_count(f.conn) == 0
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
