# The glob dialect, hermetically. No driver, no browser, no connection.
#
# R2 in tasks/plan.md: "* does not cross / while ** does" is the kind of rule
# that passes six hand-written tests and fails on the seventh real URL. So the
# cases are not invented here — they live in Playwright.GLOB_CASES, are shared
# with the guide (SC 17), and were checked against playwright-core 1.61.1's own
# globToRegexPattern rather than against memory.

using Playwright:
    glob_to_regex,
    glob_to_regex_pattern,
    resolve_glob_base,
    matches,
    driver_pattern,
    GLOB_CASES

@testset "globs" begin
    @testset "the shared case table (SC 17)" begin
        # Every row of the table the guide prints is exercised here. A case
        # that is documented but untested cannot exist, because there is only
        # one table.
        @test length(GLOB_CASES) >= 12
        for case in GLOB_CASES
            got = occursin(glob_to_regex(case.glob), case.url)
            @test got == case.matches || error(
                "$(case.glob) vs $(case.url): expected $(case.matches), " *
                "got $got — $(case.note)",
            )
        end
    end

    @testset "* does not cross /, ** does" begin
        @test occursin(glob_to_regex("**/api/*"), "https://x.test/api/items")
        @test !occursin(glob_to_regex("**/api/*"), "https://x.test/api/a/b")
        @test occursin(glob_to_regex("**/api/**"), "https://x.test/api/a/b")

        # A bare `*` between slashes is one segment, no more and no less.
        @test occursin(glob_to_regex("https://x.test/*/b"), "https://x.test/a/b")
        @test !occursin(glob_to_regex("https://x.test/*/b"), "https://x.test/a/z/b")
    end

    @testset "/**/ matches zero segments" begin
        # `a/**/b` matching `a/b` is why the pattern is `((.+/)|)` and not
        # `(.*/)`, which would insist on the slash being there.
        @test occursin(glob_to_regex("https://x.test/a/**/z"), "https://x.test/a/z")
        @test occursin(glob_to_regex("https://x.test/a/**/z"), "https://x.test/a/m/z")
        @test occursin(glob_to_regex("https://x.test/a/**/z"), "https://x.test/a/m/n/z")
    end

    @testset "the whole URL must match, not part of it" begin
        @test !occursin(glob_to_regex("/items"), "https://x.test/items")
        @test occursin(glob_to_regex("**/items"), "https://x.test/items")
        # ...unlike a Regex matcher, which is deliberately unanchored.
        @test matches(r"/items", "https://x.test/items")
    end

    @testset "{a,b} alternates, and only inside braces" begin
        @test occursin(glob_to_regex("**/*.{png,jpg}"), "https://x.test/a.png")
        @test occursin(glob_to_regex("**/*.{png,jpg}"), "https://x.test/a.jpg")
        @test !occursin(glob_to_regex("**/*.{png,jpg}"), "https://x.test/a.gif")

        # Outside a group a comma is a comma. URLs contain them.
        @test occursin(glob_to_regex("**/a,b"), "https://x.test/a,b")
    end

    @testset "malformed groups raise rather than mis-match" begin
        @test_throws ArgumentError glob_to_regex("**/{a,{b,c}}")
        @test_throws ArgumentError glob_to_regex("**/a}")
        @test_throws ArgumentError glob_to_regex("**/{a,b")
    end

    @testset "regex metacharacters are literals (R2)" begin
        # The failure mode this guards: a glob that silently becomes a much
        # broader regex. Each of these matches itself and nothing clever.
        for (glob, literal, other) in [
            ("**/a.b", "https://x.test/a.b", "https://x.test/axb"),
            ("**/x+y", "https://x.test/x+y", "https://x.test/xy"),
            ("**/q?", "https://x.test/q?", "https://x.test/qZ"),
            ("**/c[1]", "https://x.test/c[1]", "https://x.test/c1"),
            ("**/p(1)", "https://x.test/p(1)", "https://x.test/p1"),
            ("**/a|b", "https://x.test/a|b", "https://x.test/a"),
            ("**/s\$", "https://x.test/s\$", "https://x.test/s"),
            ("**/h^i", "https://x.test/h^i", "https://x.test/hi"),
        ]
            @test occursin(glob_to_regex(glob), literal)
            @test !occursin(glob_to_regex(glob), other)
        end
    end

    @testset "? is a literal, not a wildcard" begin
        # Upstream's escapedChars includes `?`, checked against the pinned
        # driver's coreBundle.js rather than assumed. URLs are full of query
        # strings, so this is the useful behaviour as well as the faithful one.
        @test occursin(glob_to_regex("**/items?page=2"), "https://x.test/items?page=2")
        @test !occursin(glob_to_regex("**/items?page=2"), "https://x.test/itemsXpage=2")
        @test occursin("\\?", glob_to_regex_pattern("a?b"))
    end

    @testset "a backslash escapes the next character" begin
        @test occursin(glob_to_regex("**/lit\\*eral"), "https://x.test/lit*eral")
        @test !occursin(glob_to_regex("**/lit\\*eral"), "https://x.test/litXeral")
    end

    @testset "base-URL resolution" begin
        base = "http://127.0.0.1:8000"

        @test resolve_glob_base(base, "/api/*") == "http://127.0.0.1:8000/api/*"
        @test matches("/api/*", "http://127.0.0.1:8000/api/items"; base_url = base)
        @test !matches("/api/*", "http://elsewhere.test/api/items"; base_url = base)

        # A glob starting with `*` is deliberately origin-agnostic, so it is
        # left alone — this is the common `**/api/*` spelling.
        @test resolve_glob_base(base, "**/api/*") == "**/api/*"

        # ...as is anything that already carries a scheme.
        @test resolve_glob_base(base, "https://other.test/x") == "https://other.test/x"
        @test resolve_glob_base(base, "data:text/html,x") == "data:text/html,x"
        @test resolve_glob_base(base, "about:blank") == "about:blank"

        # No base URL is a no-op, which is the default everywhere.
        @test resolve_glob_base(nothing, "/api/*") == "/api/*"
        @test resolve_glob_base("", "/api/*") == "/api/*"

        # A relative glob resolves against the base's directory.
        @test resolve_glob_base("http://x.test/app/index.html", "api/*") ==
              "http://x.test/app/api/*"
    end

    @testset "the matcher union dispatches on type" begin
        url = "https://x.test/api/items.json"

        @test matches("**/*.json", url)
        @test !matches("**/*.png", url)

        @test matches(r"api", url)
        @test !matches(r"^nope", url)

        @test matches(u -> endswith(u, ".json"), url)
        @test !matches(u -> endswith(u, ".png"), url)

        # A predicate that forgets to return Bool is a mistake worth naming at
        # the point it happens, not a `TypeError` from deep inside the
        # dispatcher three requests later.
        @test_throws ArgumentError matches(u -> "yes", url)
    end

    @testset "driver_pattern widens for what a glob cannot express (D9)" begin
        @test driver_pattern("**/api/*") == "**/api/*"
        @test driver_pattern(r"api") == "**/*"
        @test driver_pattern(u -> true) == "**/*"
    end
end
