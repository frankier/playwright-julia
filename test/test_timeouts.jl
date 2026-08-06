# T2: timeout settings and the resolver cascade. Hermetic — the object graph
# comes from FakeDriver (see test_connection.jl), so there is no driver and no
# browser here, only real Page/BrowserContext/Frame objects with real
# parent/child links.

using Playwright: set_default_timeout!, set_default_navigation_timeout!

"Build browser → context → page → frame over a FakeDriver, returning all four."
function timeout_fixture()
    fake = FakeDriver()
    conn = fake.connection
    # The real Browser initializer carries `name`; the fixture carries it too
    # so that anything resolving the engine client-side (D7's Chromium-only
    # `pdf` check) can be tested without a driver.
    send_create(fake, "", "Browser", "browser@1", Dict("name" => "chromium"))
    send_create(fake, "browser@1", "BrowserContext", "context@1")
    # The shape here mirrors what the real driver sends, which is *not* the
    # shape you would guess: a page's MAIN frame is parented to the browser
    # context, not to the page, and arrives before the page does. Only child
    # frames (iframes) are parented to the page. Verified against both engines
    # — see the T2b notes in tasks/plan.md. A fixture that parents the main
    # frame to the page hides the one bug that matters, because
    # `locator(page, …)` always goes through the main frame.
    send_create(fake, "context@1", "Frame", "frame@1")
    send_create(
        fake,
        "context@1",
        "Page",
        "page@1",
        Dict("mainFrame" => Dict("guid" => "frame@1")),
    )
    send_create(fake, "page@1", "Frame", "childframe@1")
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
        childframe = Playwright.lookup_object(conn, "childframe@1"),
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
        # The main frame hangs off the CONTEXT in the protocol tree, so a walk
        # that only follows __create__ parentage jumps straight past the page
        # and reports 2_000 here.
        @test Playwright.resolve_timeout(f.frame, nothing) == 7_000
        close(f.fake.connection)
    end

    @testset "a child frame resolves through the page it is parented to" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        @test Playwright.resolve_timeout(f.childframe, nothing) == 2_000
        set_default_timeout!(f.page, 7_000)
        @test Playwright.resolve_timeout(f.childframe, nothing) == 7_000
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
        # The frame → page hop is a guid-keyed side table too, so it leaks the
        # same way if it is never pruned — and a stale entry is worse than a
        # leak, because it points the cascade at a disposed page.
        @test !haskey(conn.settings_parents, "frame@1")
        close(f.fake.connection)
    end

    @testset "a disposed page leaves no stale hop behind" begin
        # Disposing only the page (its main frame lives under the context, so
        # it survives) must not leave the frame pointing at a dead page — the
        # walk would stop there and lose the context's setting.
        f = timeout_fixture()
        conn = f.fake.connection
        set_default_timeout!(f.context, 2_000)
        @test Playwright.resolve_timeout(f.frame, nothing) == 2_000

        send_dispose(f.fake, "page@1")
        @test timedwait(() -> Playwright.lookup_object(conn, "page@1") === nothing, 5.0) ===
              :ok
        @test !haskey(conn.settings_parents, "frame@1")
        @test Playwright.resolve_timeout(f.frame, nothing) == 2_000
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

    # --- T2b: the cascade reaches the wire ---------------------------------
    #
    # The resolver is only worth having if every entry point actually calls it.
    # These drive the real API functions against the fake driver and read the
    # `timeout` off the protocol frame that comes out, which is the only place
    # a missed call site shows up.

    "Run `action()` against the fake and return the params of the frame it sent."
    function sent_params(fake, action)
        task = @async action()
        msg = take!(fake.client_messages)
        reply_ok(fake, msg["id"], Dict{String,Any}("value" => nothing))
        try
            fetch(task)
        catch
        end
        return msg["params"]
    end

    @testset "locator actions send the inherited timeout, not a hardcoded 30 s" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        loc = Playwright.locator(f.frame, "#x")

        @test sent_params(f.fake, () -> text_content(loc))["timeout"] == 2_000
        @test sent_params(f.fake, () -> inner_text(loc))["timeout"] == 2_000
        @test sent_params(f.fake, () -> inner_html(loc))["timeout"] == 2_000
        @test sent_params(f.fake, () -> input_value(loc))["timeout"] == 2_000
        @test sent_params(f.fake, () -> is_checked(loc))["timeout"] == 2_000
        @test sent_params(f.fake, () -> is_enabled(loc))["timeout"] == 2_000
        @test sent_params(f.fake, () -> click!(loc))["timeout"] == 2_000
        @test sent_params(f.fake, () -> set_value!(loc, "v"))["timeout"] == 2_000
        @test sent_params(f.fake, () -> get_attribute(loc, "href"))["timeout"] == 2_000
        @test sent_params(f.fake, () -> dispatch_event(loc, "click"))["timeout"] == 2_000
        close(f.fake.connection)
    end

    @testset "an explicit keyword still beats the setting on the wire" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        loc = Playwright.locator(f.frame, "#x")
        @test sent_params(f.fake, () -> click!(loc; timeout = 250))["timeout"] == 250
        close(f.fake.connection)
    end

    @testset "a page's own setting reaches locator actions through its frame" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        set_default_timeout!(f.page, 7_000)
        loc = Playwright.locator(f.frame, "#x")
        @test sent_params(f.fake, () -> text_content(loc))["timeout"] == 7_000
        close(f.fake.connection)
    end

    @testset "page actions send the inherited timeout" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        @test sent_params(f.fake, () -> screenshot(f.page))["timeout"] == 2_000
        close(f.fake.connection)
    end

    @testset "goto! sends the navigation timeout, not the action timeout" begin
        f = timeout_fixture()
        set_default_timeout!(f.context, 2_000)
        set_default_navigation_timeout!(f.context, 9_000)
        @test sent_params(f.fake, () -> goto!(f.page, "about:blank"))["timeout"] == 9_000
        close(f.fake.connection)
    end

    @testset "no literal timeout default survives in src/api/" begin
        # The mechanical half of T2b: a call site that was missed still has its
        # old literal sitting in the source even when no test drives it.
        apidir = joinpath(pkgdir(Playwright), "src", "api")
        offenders = String[]
        for (root, _, files) in walkdir(apidir), file in files
            endswith(file, ".jl") || continue
            path = joinpath(root, file)
            in_docstring = false
            for (i, line) in enumerate(eachline(path))
                # Docstrings show *calls* like `retry_until(; timeout = 5_000)`,
                # which are examples rather than call-site defaults. Only real
                # signatures count, so track and skip docstring bodies.
                fences = count("\"\"\"", line)
                if isodd(fences)
                    in_docstring = !in_docstring
                    continue
                end
                in_docstring && continue
                # launch's driver-startup timeout is a different thing entirely
                # and is exempt by design; it is not a page/action timeout and
                # has no owner to inherit from.
                occursin("180_000", line) && continue
                occursin(r"timeout(::Real)?\s*=\s*\d", line) || continue
                push!(offenders, "$(basename(path)):$i: $(strip(line))")
            end
        end
        @test offenders == String[]
    end

    @testset "setters validate and report" begin
        f = timeout_fixture()
        @test set_default_timeout!(f.page, 1_000) === nothing
        @test_throws ArgumentError set_default_timeout!(f.page, -1)
        @test_throws ArgumentError set_default_navigation_timeout!(f.page, -1)
        close(f.fake.connection)
    end
end
