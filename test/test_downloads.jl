# Downloads (SPEC-M7.md D10, D11), against the fake connection.
#
# Everything here is assertable without a browser: the payload mapping, the
# three forwarded verbs, failure's two answers, and the keyword mapping whose
# third case is a silent-timeout trap. The real-browser legs are T13's, in
# test_smoke_files.jl.
#
# `timeout_fixture` rather than `event_fixture`, and the difference is not
# cosmetic: event_fixture installs an autoreply task that drains
# `client_messages` and answers everything with `{}`. Every test below asserts
# on the message it sent and answers it by hand, so under event_fixture the
# autoreply wins the race and the manual `take!` blocks forever -- a hang, not
# a failure. :download needs no opt-in, so nothing here needs the autoreply.

using Playwright:
    Download,
    expect_download,
    suggested_filename,
    artifact,
    cancel!,
    failure,
    save_as!,
    path,
    delete_file!,
    url

"Announce an Artifact and a download event on the fixture's page."
function fire_download(
    f,
    guid = "artifact@dl";
    url = "http://127.0.0.1/report.csv",
    suggested = "report.csv",
    absolute_path = "/tmp/pw/dl.csv",
)
    send_create(f.fake, "page@1", "Artifact", guid, Dict("absolutePath" => absolute_path))
    @test timedwait(
        () -> Playwright.lookup_object(f.fake.connection, guid) !== nothing,
        5.0,
    ) === :ok
    send_event(
        f.fake,
        "page@1",
        "download",
        Dict{String,Any}(
            "artifact" => Dict("guid" => guid),
            "url" => url,
            "suggestedFilename" => suggested,
        ),
    )
    return nothing
end

@testset "downloads (T12)" begin
    @testset "the event payload carries what the artifact cannot" begin
        # url and suggestedFilename live on the event and nowhere else, so a
        # bare Artifact would lose both -- which is the whole reason Download
        # exists rather than the event yielding an Artifact.
        f = timeout_fixture()
        dl = expect_download(f.page; timeout = 5_000) do
            fire_download(f; url = "http://x/y/report.csv", suggested = "report-2026.csv")
        end
        @test dl isa Download
        @test url(dl) == "http://x/y/report.csv"
        @test suggested_filename(dl) == "report-2026.csv"
        @test artifact(dl) isa Playwright.Artifact
        @test Playwright.page(dl) === f.page
        close(f.fake.connection)
    end

    @testset "path, save_as! and delete_file! forward to the artifact" begin
        f = timeout_fixture()
        dl = expect_download(f.page; timeout = 5_000) do
            fire_download(f)
        end

        task = @async path(dl)
        msg = take!(f.fake.client_messages)
        @test msg["guid"] == "artifact@dl"
        @test msg["method"] == "pathAfterFinished"
        reply_ok(f.fake, msg["id"], Dict{String,Any}("value" => "/tmp/pw/done.csv"))
        @test fetch(task) == "/tmp/pw/done.csv"

        dest = joinpath(mktempdir(), "copy.csv")
        task = @async save_as!(dl; path = dest)
        msg = take!(f.fake.client_messages)
        @test msg["guid"] == "artifact@dl"
        @test msg["method"] == "saveAs"
        @test msg["params"]["path"] == dest
        reply_ok(f.fake, msg["id"], Dict{String,Any}())
        # D6 again: path is a keyword and comes back, inherited unchanged.
        @test fetch(task) == dest

        task = @async delete_file!(dl)
        msg = take!(f.fake.client_messages)
        @test msg["method"] == "delete"
        reply_ok(f.fake, msg["id"], Dict{String,Any}())
        fetch(task)
        close(f.fake.connection)
    end

    @testset "cancel! reaches the artifact" begin
        f = timeout_fixture()
        dl = expect_download(f.page; timeout = 5_000) do
            fire_download(f)
        end
        task = @async cancel!(dl)
        msg = take!(f.fake.client_messages)
        @test msg["guid"] == "artifact@dl"
        @test msg["method"] == "cancel"
        reply_ok(f.fake, msg["id"], Dict{String,Any}())
        @test fetch(task) === nothing
        close(f.fake.connection)
    end

    @testset "failure is nothing on success and a string on refusal" begin
        # The probe's finding, pinned: a refused download still arrives as an
        # ordinary Download, and `failure` is the only non-throwing way to tell.
        f = timeout_fixture()
        dl = expect_download(f.page; timeout = 5_000) do
            fire_download(f)
        end

        task = @async failure(dl)
        msg = take!(f.fake.client_messages)
        @test msg["method"] == "failure"
        reply_ok(f.fake, msg["id"], Dict{String,Any}())
        @test fetch(task) === nothing

        refused = "Pass { acceptDownloads: true } when you are creating your browser context."
        task = @async failure(dl)
        msg = take!(f.fake.client_messages)
        reply_ok(f.fake, msg["id"], Dict{String,Any}("error" => refused))
        @test fetch(task) == refused
        close(f.fake.connection)
    end

    @testset "accept_downloads maps three ways, and never to the trap value" begin
        # The mapping's whole job. "internal-browser-default" emits no event at
        # all, so a `nothing` that mapped onto it would cost a silent timeout
        # rather than a wrong-looking result -- which is why `nothing` omits.
        @test Playwright.accept_downloads_option(true) == "accept"
        @test Playwright.accept_downloads_option(false) == "deny"
        @test Playwright.accept_downloads_option(nothing) === nothing
        for value in (true, false, nothing)
            @test Playwright.accept_downloads_option(value) != "internal-browser-default"
        end
    end

    @testset "the keyword omits rather than sends when unset" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> new_context(f.browser),
            result = Dict{String,Any}("context" => Dict("guid" => "context@1")),
        )
        @test !haskey(sent["params"], "acceptDownloads")
        close(f.fake.connection)
    end

    @testset "the keyword is sent when given" begin
        f = timeout_fixture()
        sent = waiting_request(
            f.fake,
            () -> new_context(f.browser; accept_downloads = false),
            result = Dict{String,Any}("context" => Dict("guid" => "context@1")),
        )
        @test sent["params"]["acceptDownloads"] == "deny"
        close(f.fake.connection)
    end

    @testset ":download is not opt-in" begin
        # page.yml's updateSubscription enum has no `download`, so the driver
        # sends it unconditionally. Marking it opt-in would send an
        # updateSubscription the driver rejects.
        @test Playwright.PAGE_EVENTS[:download].opt_in == false
        @test !haskey(Playwright.DEFERRED_EVENTS, :download)
    end
end
