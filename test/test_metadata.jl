# Engine metadata. Hermetic — the initializer is canned, so no browser.
#
# The launch-option half is a docstring claim, and a claim about what the
# *driver* does cannot be checked without one: it lives in the smoke suite.

@testset "engine metadata" begin
    @testset "browser_name reads the Browser initializer" begin
        # `name` and `browserName` are identical on both engines, so `name` is what is read — matching the
        # existing BrowserType method, one name with one return type.
        fake = FakeDriver()
        send_create(
            fake,
            "",
            "Browser",
            "browser@1",
            Dict("name" => "firefox", "browserName" => "firefox", "version" => "151.0"),
        )
        @test timedwait(
            () -> Playwright.lookup_object(fake.connection, "browser@1") !== nothing,
            5.0,
        ) === :ok
        browser = Playwright.lookup_object(fake.connection, "browser@1")

        @test browser_name(browser) == "firefox"
        @test browser_name(browser) isa String
        close(fake.connection)
    end

    @testset "browser_name works on a BrowserType too, with the same type" begin
        # The method that already existed, now exported alongside the new one.
        fake = FakeDriver()
        send_create(fake, "", "BrowserType", "bt@1", Dict("name" => "chromium"))
        @test timedwait(
            () -> Playwright.lookup_object(fake.connection, "bt@1") !== nothing,
            5.0,
        ) === :ok
        bt = Playwright.lookup_object(fake.connection, "bt@1")
        @test browser_name(bt) == "chromium"
        @test browser_name(bt) isa String
        close(fake.connection)
    end

    @testset "browser_name is exported" begin
        @test :browser_name in names(Playwright)
    end
end
