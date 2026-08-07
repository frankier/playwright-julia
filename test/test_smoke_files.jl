# Downloads, dialogs and uploads against real browsers (SPEC-M7.md Part C).
# Gated behind PLAYWRIGHT_JL_SMOKE=1, and run on Chromium and Firefox alike.
#
# The server here is richer than test_smoke.jl's static one because two of the
# three surfaces cannot be asserted from the client side:
#
#   * a download's suggested filename comes from `Content-Disposition`, so the
#     server has to set one that differs from the URL -- otherwise the
#     assertion passes on a filename derived from the path and proves nothing.
#   * an upload is only proven by what the *server* received. A client-side
#     assertion that the input has a file attached says the browser did its
#     job, not that anything was transferred.
#
# Every test here is time-boxed. A dialog nobody answers blocks its page until
# the driver's own timeout, which is ten wasted CI minutes and no diagnostic
# (R1); an explicit budget turns that into a failure with a name.

using HTTP
using Base64: base64encode

"The bytes the download fixture serves, and the filename its header claims."
const M7_REPORT_BYTES = Vector{UInt8}("id,value\n1,octarine\n2,ultraviolet\n")
const M7_REPORT_FILENAME = "report-2026.csv"

"""
Serve `test/fixtures/` plus the three dynamic routes Part C needs, and hand
`f` the base URL.

`uploads` is a `Ref` holding what the last POST to `/upload` contained, as
`name => (filename, bytes)` pairs. That `Ref` is the whole point of running our
own server: it is the only place an upload can be observed honestly.
"""
function with_files_server(f::Function)
    dir = joinpath(@__DIR__, "fixtures")
    uploads = Ref{Vector{Pair{String,Tuple{String,Vector{UInt8}}}}}([])

    server = HTTP.serve!("127.0.0.1", 0; listenany = true) do req
        target = HTTP.URI(req.target).path

        if startswith(target, "/download/")
            # The filename in the header deliberately does NOT match the URL,
            # so `suggested_filename` is proven to read the header.
            return HTTP.Response(
                200,
                [
                    "Content-Type" => "text/csv",
                    "Content-Disposition" => "attachment; filename=\"$M7_REPORT_FILENAME\"",
                ],
                M7_REPORT_BYTES,
            )
        elseif target == "/upload" && req.method == "POST"
            got = Pair{String,Tuple{String,Vector{UInt8}}}[]
            for part in HTTP.parse_multipart_form(req)
                push!(got, part.name => (part.filename, read(part.data)))
            end
            uploads[] = got
            # Echo enough for a DOM assertion too, though the Ref is the one
            # the tests actually trust.
            body = join(["$(n)=$(first(v))" for (n, v) in got], ";")
            return HTTP.Response(200, ["Content-Type" => "text/plain"], body)
        end

        path = target == "/" ? "/m7.html" : target
        file = normpath(joinpath(dir, lstrip(path, '/')))
        if startswith(file, dir) && isfile(file)
            ext = splitext(file)[2]
            ctype = ext == ".csv" ? "text/csv" : "text/html"
            return HTTP.Response(200, ["Content-Type" => ctype], read(file))
        end
        return HTTP.Response(404, "not found")
    end

    port = HTTP.port(server)
    try
        f("http://127.0.0.1:$port", uploads)
    finally
        close(server)
    end
end

"Run `body(browser, base_url, uploads)` on both engines, naming the engine."
function on_both_engines(body::Function, label::AbstractString)
    playwright() do pw
        for engine in ("chromium", "firefox")
            bt = engine == "chromium" ? pw.chromium : pw.firefox
            @testset "$label ($engine)" begin
                with_files_server() do base_url, uploads
                    browser = launch(bt; headless = true)
                    try
                        body(browser, base_url, uploads, engine)
                    finally
                        close!(browser)
                    end
                end
            end
        end
    end
end

# --- T13: downloads (SC 13-16) ---------------------------------------------

@testset "downloads, both engines (T13)" begin
    on_both_engines("downloads") do browser, base_url, _uploads, engine
        ctx = new_context(browser)
        page = new_page(ctx)
        goto!(page, "$base_url/m7.html")

        @testset "SC 13: the header names the file, and the bytes survive" begin
            dl = expect_download(page; timeout = 15_000) do
                click!(locator(page, "#download-report"))
            end
            # The URL says "report.csv"; the header says "report-2026.csv".
            # Asserting the header's answer is what proves this is not just
            # the last path segment.
            @test suggested_filename(dl) == M7_REPORT_FILENAME
            @test endswith(url(dl), "/download/report.csv")

            dest = joinpath(mktempdir(), "saved.csv")
            @test save_as!(dl; path = dest) == dest
            @test read(dest) == M7_REPORT_BYTES
        end

        @testset "SC 14: path blocks until the file is there -- no sleep" begin
            dl = expect_download(page; timeout = 15_000) do
                click!(locator(page, "#download-report"))
            end
            # R5's tripwire. `isfile` is asserted on the very next line after
            # `path` returns, with no sleep anywhere in this file. If the
            # blocking semantics were not inherited correctly this fails
            # rather than flaking, because there is nothing to paper it over.
            p = path(dl)
            @test isfile(p)
            @test read(p) == M7_REPORT_BYTES
            @test isnothing(failure(dl))
        end

        @testset "SC 16: the artifact escape hatch is exercised" begin
            dl = expect_download(page; timeout = 15_000) do
                click!(locator(page, "#download-report"))
            end
            art = artifact(dl)
            @test art isa Playwright.Artifact
            # Not merely exported -- the verbs work through it.
            @test isfile(path(art))
            dest = joinpath(mktempdir(), "via-artifact.csv")
            @test save_as!(art; path = dest) == dest
            @test read(dest) == M7_REPORT_BYTES
            delete_file!(art)
        end

        close!(ctx)

        @testset "SC 15: a refused download still arrives, and then throws" begin
            # The probe's least guessable finding. `deny` does not suppress the
            # event: it arrives with a correct url and filename, and the
            # refusal surfaces only when the artifact is asked for something.
            denied_ctx = new_context(browser; accept_downloads = false)
            denied_page = new_page(denied_ctx)
            goto!(denied_page, "$base_url/m7.html")

            dl = expect_download(denied_page; timeout = 15_000) do
                click!(locator(denied_page, "#download-report"))
            end
            @test suggested_filename(dl) == M7_REPORT_FILENAME

            # Half one: failure answers, without throwing.
            reason = failure(dl)
            @test reason isa String
            @test !isempty(reason)

            # Half two, the one users get wrong: path RAISES rather than
            # returning nothing. `isnothing(path(dl))` is not a success check.
            @test_throws Playwright.DriverError path(dl)
            @test_throws Playwright.DriverError save_as!(
                dl;
                path = joinpath(mktempdir(), "never.csv"),
            )
            close!(denied_ctx)
        end
    end
end
