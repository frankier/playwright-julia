# Artifact capture: tracing, video and PDF (SPEC-M4.md part A).
#
# Everything that can be asserted without a browser is asserted without one —
# wire params, argument validation, repo hygiene. The browser legs live behind
# PLAYWRIGHT_JL_SMOKE=1 at the bottom of the file.

@testset "artifacts stay out of git (T0)" begin
    # The tests below write real binaries — trace zips, .webm video, PDF — into
    # artifacts/. Ignoring the directory is what stops one of them being
    # committed by a `git add -A` on a bad day, so it is asserted rather than
    # assumed.
    ignore = read(joinpath(@__DIR__, "..", ".gitignore"), String)
    patterns = strip.(split(ignore, '\n'))
    @test "artifacts/" in patterns
end

using Base64: base64encode
using Playwright: pdf

"""
A page under a second, **Firefox-named** browser on the same fake connection.

D7 decides `pdf`'s Chromium-only restriction client-side, from the engine name
on the owning browser — so testing the refusal needs a page whose ancestry says
"firefox", and needs no driver at all.
"""
function firefox_fixture_page(f)
    send_create(f.fake, "", "Browser", "browser@ff", Dict("name" => "firefox"))
    send_create(f.fake, "browser@ff", "BrowserContext", "context@ff")
    send_create(f.fake, "context@ff", "Frame", "frame@ff")
    send_create(
        f.fake,
        "context@ff",
        "Page",
        "page@ff",
        Dict("mainFrame" => Dict("guid" => "frame@ff")),
    )
    @test timedwait(
        () -> Playwright.lookup_object(f.fake.connection, "page@ff") !== nothing,
        5.0,
    ) === :ok
    return Playwright.lookup_object(f.fake.connection, "page@ff")
end

# --- T7: pdf (SPEC-M4.md A3, D7) ------------------------------------------

@testset "pdf (T7)" begin
    "Reply to a pdf request with `bytes`, the way the driver does (base64)."
    pdf_reply(fake, id, bytes) =
        reply_ok(fake, id, Dict{String,Any}("pdf" => base64encode(bytes)))

    @testset "options are marshalled to the protocol's spelling" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> pdf(
                f.page;
                format = "A4",
                landscape = true,
                print_background = true,
                margin = (top = "1cm", bottom = "2cm"),
                scale = 0.5,
                page_ranges = "1-2",
            );
            result = Dict{String,Any}("pdf" => base64encode(UInt8[1, 2, 3])),
        )
        @test sent["guid"] == "page@1"
        @test sent["method"] == "pdf"
        params = sent["params"]
        @test params["format"] == "A4"
        @test params["landscape"] == true
        # snake_case in, camelCase out — the package's standing convention.
        @test params["printBackground"] == true
        @test params["margin"] == Dict("top" => "1cm", "bottom" => "2cm")
        @test params["scale"] == 0.5
        @test params["pageRanges"] == "1-2"
        close(f.fake.connection)
    end

    @testset "an unset option is omitted entirely, not sent as null" begin
        # The driver's own defaults have to apply, which they cannot do if the
        # key is present and null.
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> pdf(f.page),
            result = Dict{String,Any}("pdf" => base64encode(UInt8[1])),
        )
        for key in ("format", "landscape", "margin", "scale", "pageRanges")
            @test !haskey(sent["params"], key)
        end
        close(f.fake.connection)
    end

    @testset "the bytes come back, and are written when a path is given" begin
        f = timeout_fixture()
        bytes = Vector{UInt8}("%PDF-1.4 pretend")
        dest = joinpath(mktempdir(), "out.pdf")
        task = @async pdf(f.page; path = dest)
        msg = take!(f.fake.client_messages)
        pdf_reply(f.fake, msg["id"], bytes)
        got = fetch(task)
        @test got == bytes
        @test isfile(dest)
        @test read(dest) == bytes
        close(f.fake.connection)
    end

    @testset "off Chromium it is an ArgumentError, decided without a round trip" begin
        # D7 / SC 5. The answer is knowable client-side, so asking the driver
        # only to be told no is a wasted trip — and the driver's own error is
        # far less clear than one that names the engine and the restriction.
        f = timeout_fixture()
        firefox_page = firefox_fixture_page(f)

        err = try
            pdf(firefox_page)
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("Chromium", err.msg)
        @test occursin("firefox", err.msg)
        # Nothing went to the driver.
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end
end

@testset "the m4 fixture exists (T0)" begin
    fixture = joinpath(@__DIR__, "fixtures", "m4.html")
    @test isfile(fixture)

    html = read(fixture, String)
    # The target snippet asserts `to_have_title = "M4"`, and SC 6 wants that
    # value to arrive *late* — a title that is already correct at parse proves
    # nothing about retrying. So the document starts under a different title
    # and renames itself.
    @test occursin("document.title", html)
    @test !occursin("<title>M4</title>", html)
    # Something for report_diagnostics to find (T9).
    @test occursin("console.log", html)
end

# --- Smoke: real browsers, both engines -----------------------------------

"Where the artifact tests write. Gitignored, and cleared per run."
const ARTIFACT_DIR = joinpath(@__DIR__, "..", "artifacts")

if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
    @testset "artifacts, live (M4)" begin
        mkpath(ARTIFACT_DIR)
        with_fixture_server() do base_url
            playwright() do pw
                for engine in ("chromium", "firefox")
                    bt = getfield(pw, Symbol(engine))

                    @testset "$engine: pdf (T7, SC 5)" begin
                        browser = launch(bt; headless = true)
                        ctx = new_context(browser)
                        page = new_page(ctx)
                        goto(page, "$base_url/m4.html")

                        @test browser_name(page) == engine

                        if engine == "chromium"
                            dest = joinpath(ARTIFACT_DIR, "page.pdf")
                            isfile(dest) && rm(dest)
                            bytes = pdf(page; path = dest, format = "A4")
                            @test !isempty(bytes)
                            @test isfile(dest)
                            @test filesize(dest) > 0
                            @test read(dest) == bytes
                            # It really is a PDF.
                            @test bytes[1:4] == Vector{UInt8}("%PDF")
                        else
                            # The Firefox leg asserting a *clean* failure is a
                            # required test, not an omission (SC 5).
                            err = try
                                pdf(page)
                                nothing
                            catch e
                                e
                            end
                            @test err isa ArgumentError
                            @test occursin("Chromium", err.msg)
                            @test occursin("firefox", err.msg)
                        end

                        close(browser)
                    end
                end
            end
        end
    end
end
