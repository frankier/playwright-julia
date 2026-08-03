# T2: timeout settings and the resolver cascade. Hermetic — the object graph
# comes from FakeDriver (see test_connection.jl), so there is no driver and no
# browser here, only real Page/BrowserContext/Frame objects with real
# parent/child links.

using Playwright: set_default_timeout!, set_default_navigation_timeout!

"Build browser → context → page → frame over a FakeDriver, returning all four."
function timeout_fixture()
    fake = FakeDriver()
    conn = fake.connection
    send_create(fake, "", "Browser", "browser@1")
    send_create(fake, "browser@1", "BrowserContext", "context@1")
    send_create(fake, "context@1", "Page", "page@1")
    send_create(fake, "page@1", "Frame", "frame@1")
    # Second context/page, to prove settings do not bleed between siblings.
    send_create(fake, "browser@1", "BrowserContext", "context@2")
    send_create(fake, "context@2", "Page", "page@2")
    @test timedwait(() -> Playwright.lookup_object(conn, "frame@1") !== nothing, 5.0) ===
          :ok
    @test timedwait(() -> Playwright.lookup_object(conn, "page@2") !== nothing, 5.0) === :ok
    return (
        fake = fake,
        browser = Playwright.lookup_object(conn, "browser@1"),
        context = Playwright.lookup_object(conn, "context@1"),
        page = Playwright.lookup_object(conn, "page@1"),
        frame = Playwright.lookup_object(conn, "frame@1"),
        context2 = Playwright.lookup_object(conn, "context@2"),
        page2 = Playwright.lookup_object(conn, "page@2"),
    )
end

@testset "timeout cascade" begin
    @testset "package defaults apply when nothing is set" begin
        f = timeout_fixture()
        @test Playwright.resolve_timeout(f.page, nothing) == 30_000
        @test Playwright.resolve_navigation_timeout(f.page, nothing) == 30_000
        close(f.fake.connection)
    end

    @testset "an explicit keyword beats every setting" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        set_default_timeout!(f.page, 3_000)
        @test Playwright.resolve_timeout(f.page, 500) == 500
        # ...including zero, which Playwright reads as "no timeout".
        @test Playwright.resolve_timeout(f.page, 0) == 0
        close(f.fake.connection)
    end

    @testset "a page inherits its context's setting" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        @test Playwright.resolve_timeout(f.page, nothing) == 2_000
        # and a sibling context is untouched
        @test Playwright.resolve_timeout(f.page2, nothing) == 30_000
        close(f.fake.connection)
    end

    @testset "a page's own setting overrides the context it inherits from" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        set_default_timeout!(f.page, 7_000)
        @test Playwright.resolve_timeout(f.page, nothing) == 7_000
        @test Playwright.resolve_timeout(f.context, nothing) == 2_000
        close(f.fake.connection)
    end

    @testset "a frame resolves through its page, then its context" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        @test Playwright.resolve_timeout(f.frame, nothing) == 2_000
        set_default_timeout!(f.page, 7_000)
        @test Playwright.resolve_timeout(f.frame, nothing) == 7_000
        close(f.fake.connection)
    end

    @testset "a Locator resolves through its frame" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        loc = Playwright.Locator(f.frame, "#x")
        @test Playwright.resolve_timeout(loc, nothing) == 2_000
        @test Playwright.resolve_timeout(loc, 250) == 250
        close(f.fake.connection)
    end

    @testset "navigation timeouts have their own setting" begin
        f = timeout_fixture()
        set_default_navigation_timeout!(f.context, 9_000)
        @test Playwright.resolve_navigation_timeout(f.page, nothing) == 9_000
        # ...and do not disturb action timeouts
        @test Playwright.resolve_timeout(f.page, nothing) == 30_000

        set_default_navigation_timeout!(f.page, 4_000)
        @test Playwright.resolve_navigation_timeout(f.page, nothing) == 4_000
        close(f.fake.connection)
    end

    @testset "navigation falls back to the default timeout before the package default" begin
        # Upstream behaviour: setting only a default timeout also governs
        # navigation, so set_default_timeout!(ctx, 2_000) does not leave
        # navigations stalling for 30 s.
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        @test Playwright.resolve_navigation_timeout(f.page, nothing) == 2_000
        # An explicit navigation setting still wins over it.
        set_default_navigation_timeout!(f.context, 9_000)
        @test Playwright.resolve_navigation_timeout(f.page, nothing) == 9_000
        close(f.fake.connection)
    end

    @testset "settings are dropped when the owner is disposed" begin
        f = timeout_fixture()
        conn = f.fake.connection
        set_default_timeout!(f.page, 7_000)
        set_default_navigation_timeout!(f.context, 9_000)
        @test haskey(conn.timeouts, "page@1")
        @test haskey(conn.timeouts, "context@1")

        send_dispose(f.fake, "context@1")
        @test timedwait(() -> Playwright.lookup_object(conn, "page@1") === nothing, 5.0) ===
              :ok
        # Disposing the context cascades to the page beneath it, so neither
        # entry may survive — a guid-keyed table that is never pruned is a leak
        # for the life of the connection.
        @test !haskey(conn.timeouts, "page@1")
        @test !haskey(conn.timeouts, "context@1")
        @test !haskey(conn.parents, "page@1")
        close(f.fake.connection)
    end

    @testset "settings do not leak between connections" begin
        # guids are only unique within one driver process, so a table keyed by
        # guid alone would let a second playwright() session inherit the first
        # one's settings for the same guid.
        a = timeout_fixture()
        set_default_timeout!(a.page, 7_000)
        @test Playwright.resolve_timeout(a.page, nothing) == 7_000

        b = timeout_fixture()   # same guids, different connection
        @test Playwright.resolve_timeout(b.page, nothing) == 30_000

        close(a.fake.connection)
        close(b.fake.connection)
    end

    @testset "setters validate and report" begin
        f = timeout_fixture()
        @test set_default_timeout!(f.page, 1_000) === nothing
        @test_throws ArgumentError set_default_timeout!(f.page, -1)
        @test_throws ArgumentError set_default_navigation_timeout!(f.page, -1)
        close(f.fake.connection)
    end
end
