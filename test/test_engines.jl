# The gate that makes D4 enforceable: every engine a test skips must have a row
# in docs/src/engines.md explaining it.
#
# This is the machinery that makes a skip cost something. It lands before the
# work that creates the temptation to skip (T11 before T12), for the same reason
# M8 put its parity gate before its parity work: a rule that arrives after the
# pressure is a rule that gets negotiated with.
#
# Hermetic — it reads source text and a Markdown file, and launches nothing.

@testset "engine divergences are documented" begin
    engines_md = joinpath(pkgdir(Playwright), "docs", "src", "engines.md")
    page = read(engines_md, String)

    @testset "the page exists and is in the docs build" begin
        @test isfile(engines_md)
        make = read(joinpath(pkgdir(Playwright), "docs", "make.jl"), String)
        @test occursin("engines.md", make)
    end

    @testset "every engine name has a row of its own" begin
        # The table's first column. A page that never mentions an engine cannot
        # be the place a user looks up what that engine does differently.
        for name in ("chromium", "firefox", "webkit", "chrome", "msedge")
            @test occursin(name, page)
        end
    end

    # The gate proper. Find every skip_engine call in the test suite, take the
    # engine it names and the reason it gives, and require the page to account
    # for it.
    #
    # Matching on the *reason's* words rather than the whole string on purpose:
    # a row is prose written for a user and a skip reason is a sentence written
    # for a maintainer, and forcing them to be byte-identical would only teach
    # people to paste the row into the call and stop thinking.
    skip_calls = Tuple{String,String,String}[]
    for file in readdir(@__DIR__; join = true)
        endswith(file, ".jl") || continue
        src = read(file, String)
        for m in eachmatch(
            r"skip_engine\(\s*\w+\s*,\s*(\"[^\"]+\"|\([^)]*\))\s*,\s*\"([^\"]+)\"",
            src,
        )
            for name in eachmatch(r"\"([a-z]+)\"", m.captures[1])
                push!(skip_calls, (basename(file), name.captures[1], m.captures[2]))
            end
        end
    end

    @testset "every skip names an engine the page knows" begin
        for (file, name, reason) in skip_calls
            @test occursin(name, page)
        end
    end

    @testset "every skip's reason is accounted for on the page" begin
        # The content words of the reason have to appear in the page. Short and
        # common words are dropped, because requiring "the" to match proves
        # nothing.
        stop = Set([
            "the",
            "and",
            "not",
            "for",
            "with",
            "does",
            "has",
            "have",
            "any",
            "this",
            "that",
            "its",
            "are",
            "but",
            "out",
            "can",
            "all",
            "one",
            "outside",
            "there",
            "them",
            "than",
            "from",
            "only",
        ])
        for (file, name, reason) in skip_calls
            words = [lowercase(w) for w in split(reason, r"[^A-Za-z_.]+") if length(w) > 3]
            content = filter(w -> !(w in stop), words)
            missing_words = filter(w -> !occursin(w, lowercase(page)), content)
            # Logged rather than folded into the assertion: @test prints the
            # expression, not the values inside it, and "isempty(missing_words)
            # was false" is not a message anyone can act on. This says which
            # call, which engine, and exactly which words have no home yet.
            isempty(missing_words) || @error(
                "a skip with no engines.md row — add one, or reword the reason",
                file,
                engine = name,
                reason,
                missing_words,
            )
            @test isempty(missing_words)
        end
    end
end
