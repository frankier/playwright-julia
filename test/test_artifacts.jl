# Artifact capture: tracing, video and PDF.
#
# Everything that can be asserted without a browser is asserted without one —
# wire params, argument validation, repo hygiene. The browser legs live behind
# PLAYWRIGHT_JL_SMOKE=1 at the bottom of the file.

@testset "artifacts stay out of git" begin
    # The tests below write real binaries — trace zips, .webm video, PDF — into
    # artifacts/. Ignoring the directory is what stops one of them being
    # committed by a `git add -A` on a bad day, so it is asserted rather than
    # assumed.
    ignore = read(joinpath(@__DIR__, "..", ".gitignore"), String)
    patterns = strip.(split(ignore, '\n'))
    @test "artifacts/" in patterns
end

using Base64: base64encode
using Playwright:
    pdf, save_as!, path, delete_file!, start_tracing!, stop_tracing!, with_tracing, video

"""
Answer a whole `with_tracing` session on the fake driver: the two start calls,
the archiving stop, the saveAs and the final tracingStop.

Written once because five tests need it and none of them is *about* the
message sequence — the one that is asserts the sequence itself, above.
"""
function drive_tracing_session(f, dest)
    for _ = 1:2   # tracingStart, tracingStartChunk
        msg = take!(f.fake.client_messages)
        reply_ok(f.fake, msg["id"], Dict{String,Any}("traceName" => "trace-1"))
    end
    stop = take!(f.fake.client_messages)
    send_create(
        f.fake,
        "context@1",
        "Artifact",
        "artifact@trace",
        Dict("absolutePath" => "/tmp/pw/trace.zip"),
    )
    reply_ok(
        f.fake,
        stop["id"],
        Dict{String,Any}("artifact" => Dict("guid" => "artifact@trace")),
    )
    save = take!(f.fake.client_messages)
    reply_ok(f.fake, save["id"], Dict{String,Any}())
    final = take!(f.fake.client_messages)
    reply_ok(f.fake, final["id"], Dict{String,Any}())
    return nothing
end

"""
A page under a second, **Firefox-named** browser on the same fake connection.

`pdf`'s Chromium-only restriction is decided client-side, from the engine name
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

"An Artifact hanging off the fixture's context, as the driver announces one."
function fixture_artifact(f, guid = "artifact@1"; absolute_path = "/tmp/pw/thing.zip")
    send_create(
        f.fake,
        "context@1",
        "Artifact",
        guid,
        Dict("absolutePath" => absolute_path),
    )
    @test timedwait(
        () -> Playwright.lookup_object(f.fake.connection, guid) !== nothing,
        5.0,
    ) === :ok
    return Playwright.lookup_object(f.fake.connection, guid)
end

# --- The Artifact wrapper --------------------------------------------------
#
# The shared surface under tracing and video. The generated _artifact_* calls
# already exist; this is the hand-written layer over them, and its whole job is
# to keep wire spellings out of the API layer.

@testset "Artifact" begin
    @testset "save_as! sends the path and returns it" begin
        f = timeout_fixture()
        art = fixture_artifact(f)
        dest = joinpath(mktempdir(), "saved.zip")

        sent = waiting_request(f.fake, () -> save_as!(art; path = dest))
        @test sent["guid"] == "artifact@1"
        @test sent["method"] == "saveAs"
        @test sent["params"]["path"] == dest
        close(f.fake.connection)
    end

    @testset "save_as! returns the path it was given, so calls chain" begin
        f = timeout_fixture()
        art = fixture_artifact(f)
        dest = joinpath(mktempdir(), "saved.zip")
        task = @async save_as!(art; path = dest)
        msg = take!(f.fake.client_messages)
        reply_ok(f.fake, msg["id"], Dict{String,Any}())
        @test fetch(task) == dest
        close(f.fake.connection)
    end

    # The last member of the family still taking `path` positionally.
    # Called out on its own because Download extends this exact signature,
    # and a new name should be born with the right shape rather than renamed a
    # week later.
    @testset "the artifact family agrees on one calling convention" begin
        f = timeout_fixture()
        art = fixture_artifact(f)
        dest = joinpath(mktempdir(), "chained.zip")

        # Positional is gone, not merely discouraged.
        @test_throws MethodError save_as!(art, dest)

        task = @async save_as!(art; path = dest)
        msg = take!(f.fake.client_messages)
        @test msg["params"]["path"] == dest
        reply_ok(f.fake, msg["id"], Dict{String,Any}())
        @test fetch(task) == dest

        # All four members now read the same way at the call site. `screenshot`
        # and `pdf` are checked against a Page rather than an Artifact, so this
        # asserts the shape they share: `path` is a keyword, and it comes back.
        for fn in (save_as!, stop_tracing!, screenshot, pdf)
            @test any(m -> :path in Base.kwarg_decl(m), methods(fn).ms)
        end
        close(f.fake.connection)
    end

    @testset "path blocks on pathAfterFinished, not on the initializer" begin
        # The initializer's absolutePath is where the file will *end up*; it is
        # there before the file is. pathAfterFinished is the one that waits,
        # which is the entire reason this wrapper is not a field read.
        f = timeout_fixture()
        art = fixture_artifact(f; absolute_path = "/tmp/pw/not-yet.zip")
        task = @async path(art)
        msg = take!(f.fake.client_messages)
        @test msg["method"] == "pathAfterFinished"
        reply_ok(f.fake, msg["id"], Dict{String,Any}("value" => "/tmp/pw/finished.zip"))
        @test fetch(task) == "/tmp/pw/finished.zip"
        close(f.fake.connection)
    end

    @testset "delete_file! sends delete" begin
        f = timeout_fixture()
        art = fixture_artifact(f)
        sent = waiting_request(f.fake, () -> delete_file!(art))
        @test sent["method"] == "delete"
        close(f.fake.connection)
    end
end

# --- Tracing ---------------------------------------------------------------
#
# The stop path: tracingStopChunk(mode="archive") returns a
# real Artifact whose saveAs writes the zip. No localUtils.zip, no Julia zip
# dependency.

"""
Give the fixture's context a Tracing channel, the way the real driver does —
via the context initializer rather than a generated accessor.
"""
function fixture_tracing(f)
    send_create(f.fake, "context@1", "Tracing", "tracing@1")
    @test timedwait(
        () -> Playwright.lookup_object(f.fake.connection, "tracing@1") !== nothing,
        5.0,
    ) === :ok
    f.context.initializer["tracing"] = Dict("guid" => "tracing@1")
    return Playwright.lookup_object(f.fake.connection, "tracing@1")
end

@testset "tracing" begin
    @testset "start_tracing! starts a recording and opens a chunk" begin
        # Both calls are needed: tracingStart configures the recording,
        # tracingStartChunk opens the span that tracingStopChunk closes. A
        # stop with no chunk open has nothing to archive.
        f = timeout_fixture()
        fixture_tracing(f)
        sent = Vector{Any}()
        task = @async start_tracing!(f.context; screenshots = true, snapshots = true)
        for _ = 1:2
            @test timedwait(() -> isready(f.fake.client_messages), 10.0) === :ok
            msg = take!(f.fake.client_messages)
            push!(sent, msg)
            reply_ok(f.fake, msg["id"], Dict{String,Any}("traceName" => "trace-1"))
        end
        fetch(task)

        @test sent[1]["method"] == "tracingStart"
        @test sent[1]["guid"] == "tracing@1"
        @test sent[1]["params"]["screenshots"] == true
        @test sent[1]["params"]["snapshots"] == true
        @test sent[2]["method"] == "tracingStartChunk"
        close(f.fake.connection)
    end

    @testset "sources is not a keyword at all" begin
        # Inverted rather than deleted. It used to be accepted and refused at
        # runtime with an ArgumentError. It is out of the signature now, so
        # the same call is a MethodError. Same answer, delivered earlier and by
        # the language instead of by a hand-written check -- and, as before,
        # nothing reaches the driver.
        f = timeout_fixture()
        fixture_tracing(f)
        @test_throws MethodError start_tracing!(f.context; sources = true)
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end

    @testset "stop_tracing! archives and saves, in that order" begin
        f = timeout_fixture()
        fixture_tracing(f)
        dest = joinpath(mktempdir(), "trace.zip")

        task = @async stop_tracing!(f.context; path = dest)

        stop = take!(f.fake.client_messages)
        @test stop["method"] == "tracingStopChunk"
        # archive mode is what makes the driver assemble the zip.
        @test stop["params"]["mode"] == "archive"
        # Announce the artifact, then hand it back as the reply.
        send_create(
            f.fake,
            "context@1",
            "Artifact",
            "artifact@trace",
            Dict("absolutePath" => "/tmp/pw/trace.zip"),
        )
        reply_ok(
            f.fake,
            stop["id"],
            Dict{String,Any}("artifact" => Dict("guid" => "artifact@trace")),
        )

        save = take!(f.fake.client_messages)
        @test save["method"] == "saveAs"
        @test save["params"]["path"] == dest
        reply_ok(f.fake, save["id"], Dict{String,Any}())

        stop_msg = take!(f.fake.client_messages)
        @test stop_msg["method"] == "tracingStop"
        reply_ok(f.fake, stop_msg["id"], Dict{String,Any}())

        @test fetch(task) == dest
        close(f.fake.connection)
    end

    @testset "with_tracing writes the zip when the block returns" begin
        f = timeout_fixture()
        fixture_tracing(f)
        dest = joinpath(mktempdir(), "trace.zip")
        ran = Ref(false)

        task = @async with_tracing(f.context; path = dest) do
            ran[] = true
            return :body_result
        end
        drive_tracing_session(f, dest)
        @test fetch(task) == :body_result
        @test ran[]
        close(f.fake.connection)
    end

    @testset "the zip is written when the block THROWS, and the block's error wins" begin
        # The whole point of the block form: the run worth tracing is the
        # one that failed. The trace must still be written, and the caller must
        # still see their own exception rather than a tracing one.
        f = timeout_fixture()
        fixture_tracing(f)
        dest = joinpath(mktempdir(), "trace.zip")

        task = @async with_tracing(f.context; path = dest) do
            error("the body blew up")
        end
        drive_tracing_session(f, dest)

        err = try
            fetch(task)
            nothing
        catch e
            e isa TaskFailedException ? e.task.result : e
        end
        @test err isa ErrorException
        @test occursin("the body blew up", err.msg)
        close(f.fake.connection)
    end

    # The next two run with_tracing on *this* task and answer the driver from
    # a spawned one — the opposite way round from the tests above. @test_logs
    # installs its capture logger where it is written, and a task started
    # before that inherits the outer logger, so a warning raised inside an
    # @async body would escape the capture entirely and the test would pass
    # for the wrong reason.
    "Answer the two start calls, then fail the archiving stop."
    function fail_the_stop(f, message)
        return @async begin
            for _ = 1:2
                msg = take!(f.fake.client_messages)
                reply_ok(f.fake, msg["id"], Dict{String,Any}("traceName" => "t"))
            end
            stop = take!(f.fake.client_messages)
            reply_error(f.fake, stop["id"], message)
        end
    end

    @testset "a failure to save the trace is a warning, not an exception" begin
        # The rule for teardown-path functions: they never throw. Otherwise
        # with_tracing masks the caller's failure in new
        # clothes -- replacing the caller's real failure with a worse one.
        f = timeout_fixture()
        fixture_tracing(f)
        dest = joinpath(mktempdir(), "trace.zip")
        responder = fail_the_stop(f, "tracing exploded")

        traced() =
            with_tracing(f.context; path = dest) do
                :fine
            end
        result = @test_logs (:warn,) match_mode = :any traced()

        @test result == :fine
        wait(responder)
        close(f.fake.connection)
    end

    @testset "...and it still loses to the body's own exception" begin
        # Both go wrong at once: the body threw AND the trace could not be
        # saved. The body's exception is the one that must propagate.
        f = timeout_fixture()
        fixture_tracing(f)
        dest = joinpath(mktempdir(), "trace.zip")
        responder = fail_the_stop(f, "tracing exploded too")

        traced() =
            with_tracing(f.context; path = dest) do
                error("the body blew up")
            end
        # collect_test_logs rather than @test_logs: the latter records a
        # throwing expression as a test Error instead of rethrowing, and an
        # exception propagating is exactly what this test is about.
        logs, err = Test.collect_test_logs() do
            try
                traced()
                nothing
            catch e
                e
            end
        end

        @test err isa ErrorException
        @test occursin("the body blew up", err.msg)
        @test !occursin("tracing exploded", err.msg)
        # The trace failure was still reported — quietly, and as a warning.
        @test any(l -> l.level == Base.CoreLogging.Warn, logs)
        @test any(l -> occursin("could not save trace", l.message), logs)
        wait(responder)
        close(f.fake.connection)
    end
end

# --- Video -----------------------------------------------------------------

@testset "video" begin
    @testset "record_video marshals to the recordVideo object" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> new_context(
                f.browser;
                record_video = (
                    dir = "artifacts/video",
                    size = (width = 640, height = 480),
                ),
            ),
        )
        @test sent["method"] == "newContext"
        rv = sent["params"]["recordVideo"]
        @test rv["dir"] == "artifacts/video"
        @test rv["size"] == Dict("width" => 640, "height" => 480)
        close(f.fake.connection)
    end

    @testset "size is optional; dir alone is enough" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> new_context(f.browser; record_video = (dir = "artifacts/video",)),
        )
        rv = sent["params"]["recordVideo"]
        @test rv["dir"] == "artifacts/video"
        @test !haskey(rv, "size")
        close(f.fake.connection)
    end

    @testset "no record_video means no recordVideo key at all" begin
        f = timeout_fixture()
        sent = waiting_request(f.fake, () -> new_context(f.browser))
        @test !haskey(sent["params"], "recordVideo")
        close(f.fake.connection)
    end

    @testset "a Dict works as well as a NamedTuple" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> new_context(f.browser; record_video = Dict("dir" => "artifacts/v")),
        )
        @test sent["params"]["recordVideo"]["dir"] == "artifacts/v"
        close(f.fake.connection)
    end

    @testset "video(page) is nothing without recording" begin
        # The fixture's page initializer has no `video` key, which is exactly
        # what the driver sends for a context that is not recording.
        f = timeout_fixture()
        @test video(f.page) === nothing
        close(f.fake.connection)
    end

    @testset "video(page) resolves the Artifact when there is one" begin
        f = timeout_fixture()
        send_create(
            f.fake,
            "context@1",
            "Artifact",
            "artifact@video",
            Dict("absolutePath" => "/tmp/pw/video.webm"),
        )
        @test timedwait(
            () -> Playwright.lookup_object(f.fake.connection, "artifact@video") !== nothing,
            5.0,
        ) === :ok
        f.page.initializer["video"] = Dict("guid" => "artifact@video")

        v = video(f.page)
        @test v isa Playwright.Artifact
        # ...and it is the Artifact surface, so the three verbs work on it.
        task = @async path(v)
        msg = take!(f.fake.client_messages)
        @test msg["method"] == "pathAfterFinished"
        reply_ok(f.fake, msg["id"], Dict{String,Any}("value" => "/tmp/pw/video.webm"))
        @test fetch(task) == "/tmp/pw/video.webm"
        close(f.fake.connection)
    end
end

# --- PDF -------------------------------------------------------------------

@testset "pdf" begin
    "Reply to a pdf request with `bytes`, the way the driver does (base64)."
    pdf_reply(fake, id, bytes) =
        reply_ok(fake, id, Dict{String,Any}("pdf" => base64encode(bytes)))

    @testset "options are marshalled to the protocol's spelling" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> pdf_bytes(
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
            () -> pdf_bytes(f.page),
            result = Dict{String,Any}("pdf" => base64encode(UInt8[1])),
        )
        for key in ("format", "landscape", "margin", "scale", "pageRanges")
            @test !haskey(sent["params"], key)
        end
        close(f.fake.connection)
    end

    @testset "the write returns its destination, and writes it" begin
        f = timeout_fixture()
        bytes = Vector{UInt8}("%PDF-1.4 pretend")
        dest = joinpath(mktempdir(), "out.pdf")
        task = @async pdf(f.page; path = dest)
        msg = take!(f.fake.client_messages)
        pdf_reply(f.fake, msg["id"], bytes)
        got = fetch(task)
        @test got == dest          # you named a destination, you get it back
        @test isfile(dest)
        @test read(dest) == bytes
        close(f.fake.connection)
    end

    # The split is the point: one convention for the return value, one for
    # the argument, and every function type-stable. `screenshot(page)` used to
    # be the in-memory form and is now nothing at all — a MethodError rather
    # than a silent change of return type, which is the whole reason `path`
    # became required instead of merely recommended.
    @testset "capture and export are separate functions" begin
        f = timeout_fixture()

        # A MethodError might be expected here. It is an UndefKeywordError,
        # and it could not have been anything else: `path` is a *keyword*,
        # because Julia raises UndefKeywordError for a
        # missing required keyword. The prediction was wrong about the type,
        # not about the behaviour — and the error it actually raises is the
        # better one, because it names the keyword you forgot.
        @test_throws UndefKeywordError screenshot(f.page)
        @test_throws UndefKeywordError pdf(f.page)

        dest = joinpath(mktempdir(), "shot.png")
        png = Vector{UInt8}("\x89PNG pretend")
        task = @async screenshot(f.page; path = dest)
        msg = take!(f.fake.client_messages)
        reply_ok(f.fake, msg["id"], Dict{String,Any}("binary" => base64encode(png)))
        @test fetch(task) == dest
        @test read(dest) == png

        task = @async screenshot_bytes(f.page)
        msg = take!(f.fake.client_messages)
        reply_ok(f.fake, msg["id"], Dict{String,Any}("binary" => base64encode(png)))
        @test fetch(task) == png

        close(f.fake.connection)
    end

    @testset "off Chromium it is an ArgumentError, decided without a round trip" begin
        # The answer is knowable client-side, so asking the driver
        # only to be told no is a wasted trip — and the driver's own error is
        # far less clear than one that names the engine and the restriction.
        f = timeout_fixture()
        firefox_page = firefox_fixture_page(f)

        err = try
            pdf_bytes(firefox_page)
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

@testset "the late-title fixture exists" begin
    fixture = joinpath(@__DIR__, "fixtures", "late-title.html")
    @test isfile(fixture)

    html = read(fixture, String)
    # The walkthrough asserts `to_have_title = "Dashboard"`, and wants that
    # value to arrive *late* — a title that is already correct at parse proves
    # nothing about retrying. So the document starts under a different title
    # and renames itself.
    @test occursin("document.title", html)
    @test !occursin("<title>Dashboard</title>", html)
    # Something for report_diagnostics to find.
    @test occursin("console.log", html)
end

# --- Smoke: real browsers, both engines -----------------------------------

"Where the artifact tests write. Gitignored, and cleared per run."
const ARTIFACT_DIR = joinpath(@__DIR__, "..", "artifacts")

if get(ENV, "PLAYWRIGHT_JL_SMOKE", "") == "1"
    @testset "artifacts, live" begin
        mkpath(ARTIFACT_DIR)
        with_fixture_server() do base_url
            playwright() do pw
                for engine in SMOKE_ENGINES
                    bt = getfield(pw, Symbol(engine))

                    @testset "$engine: tracing round-trip" begin
                        browser = launch(bt; headless = true)
                        ctx = new_context(browser)
                        dest = joinpath(ARTIFACT_DIR, "trace-$engine.zip")
                        isfile(dest) && rm(dest)

                        result = with_tracing(
                            ctx;
                            path = dest,
                            screenshots = true,
                            snapshots = true,
                        ) do
                            page = new_page(ctx)
                            goto!(page, "$base_url/late-title.html")
                            click!(locator(page, "h1"))
                            return :done
                        end

                        @test result == :done
                        @test isfile(dest)
                        @test filesize(dest) > 0
                        # it is a real zip. Asserted on the magic bytes
                        # rather than by unzipping, because reading the entry
                        # list would need a Julia zip dependency and the trace
                        # is an opaque artifact for upstream's viewer.
                        @test read(dest, 4) == UInt8[0x50, 0x4b, 0x03, 0x04]

                        close!(browser)
                    end

                    @testset "$engine: the trace survives a throwing block" begin
                        # The case this exists for: the run worth
                        # tracing is the one that failed.
                        browser = launch(bt; headless = true)
                        ctx = new_context(browser)
                        dest = joinpath(ARTIFACT_DIR, "trace-throw-$engine.zip")
                        isfile(dest) && rm(dest)

                        err = try
                            with_tracing(ctx; path = dest) do
                                page = new_page(ctx)
                                goto!(page, "$base_url/late-title.html")
                                error("deliberate failure mid-trace")
                            end
                            nothing
                        catch e
                            e
                        end

                        # The block's exception propagates, not a tracing one.
                        @test err isa ErrorException
                        @test occursin("deliberate failure mid-trace", err.msg)
                        # ...and the evidence was still written.
                        @test isfile(dest)
                        @test read(dest, 4) == UInt8[0x50, 0x4b, 0x03, 0x04]

                        close!(browser)
                    end

                    @testset "$engine: video" begin
                        browser = launch(bt; headless = true)
                        video_dir = joinpath(ARTIFACT_DIR, "video-$engine")
                        ispath(video_dir) && rm(video_dir; recursive = true)

                        ctx = new_context(
                            browser;
                            record_video = (
                                dir = video_dir,
                                size = (width = 640, height = 480),
                            ),
                        )
                        page = new_page(ctx)
                        goto!(page, "$base_url/late-title.html")
                        click!(locator(page, "h1"))

                        v = video(page)
                        @test v isa Playwright.Artifact

                        # the sharp edge, stated as an assertion: the file is
                        # not finished until the page closes. Closing first is
                        # what makes `path` return rather than block.
                        close!(page)
                        file = path(v)
                        @test isfile(file)
                        @test filesize(file) > 0

                        # ...and save_as! puts a copy where the caller wants it.
                        dest = joinpath(ARTIFACT_DIR, "run-$engine.webm")
                        isfile(dest) && rm(dest)
                        # `path` is a keyword and comes back, so the call
                        # chains into anything that takes a path.
                        @test save_as!(v; path = dest) |> isfile
                        @test filesize(dest) > 0

                        close!(browser)
                    end

                    @testset "$engine: no recording means video(page) is nothing" begin
                        browser = launch(bt; headless = true)
                        ctx = new_context(browser)
                        page = new_page(ctx)
                        goto!(page, "$base_url/late-title.html")
                        @test video(page) === nothing
                        close!(browser)
                    end

                    @testset "$engine: pdf" begin
                        browser = launch(bt; headless = true)
                        ctx = new_context(browser)
                        page = new_page(ctx)
                        goto!(page, "$base_url/late-title.html")

                        @test browser_name(page) == engine

                        if engine == "chromium"
                            dest = joinpath(ARTIFACT_DIR, "page.pdf")
                            isfile(dest) && rm(dest)
                            @test pdf(page; path = dest, format = "A4") == dest
                            @test isfile(dest)
                            @test filesize(dest) > 0
                            bytes = read(dest)
                            # It really is a PDF.
                            @test bytes[1:4] == Vector{UInt8}("%PDF")
                        else
                            # The Firefox leg asserting a *clean* failure is a
                            # required test, not an omission.
                            err = try
                                pdf_bytes(page)
                                nothing
                            catch e
                                e
                            end
                            @test err isa ArgumentError
                            @test occursin("Chromium", err.msg)
                            @test occursin("firefox", err.msg)
                        end

                        close!(browser)
                    end
                end
            end
        end
    end
end
