# Uploads (SPEC-M7.md D13), against the fake connection.
#
# The validation is the interesting half, and it is asserted where it belongs:
# an ArgumentError raised at the call site, with nothing reaching the driver.
# The real-transfer legs are T17's, and they are asserted server-side because
# nothing observed from the client proves a byte moved.
#
# `timeout_fixture`, not `event_fixture` -- see test_downloads.jl's header.

using Playwright:
    set_input_files!, FileChooser, expect_file_chooser, element, is_multiple, set_files!

"A real file on disk, since set_input_files! refuses paths that do not exist."
const UPLOAD_FIXTURE = joinpath(@__DIR__, "fixtures", "upload.csv")

@testset "uploads (T16)" begin
    @testset "the fixture file exists" begin
        @test isfile(UPLOAD_FIXTURE)
    end

    # --- Validation, in exactly one place -----------------------------------

    @testset "paths and the in-memory form are mutually exclusive" begin
        # D13: raised at the call site, before any message reaches the driver.
        # The driver's own complaint arrives later and names the wire spelling.
        f = timeout_fixture()
        loc = locator(f.page, "#file")
        err = try
            set_input_files!(loc, UPLOAD_FIXTURE; name = "x.csv", buffer = UInt8[1])
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("not both", err.msg)
        # The whole point: nothing was sent.
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end

    @testset "an in-memory upload needs both a name and a buffer" begin
        f = timeout_fixture()
        loc = locator(f.page, "#file")
        @test_throws ArgumentError set_input_files!(loc; buffer = UInt8[1])
        @test_throws ArgumentError set_input_files!(loc; name = "x.csv")
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end

    @testset "a path that does not exist is refused before the wire" begin
        f = timeout_fixture()
        loc = locator(f.page, "#file")
        err = try
            set_input_files!(loc, "/no/such/file.csv")
            nothing
        catch e
            e
        end
        @test err isa ArgumentError
        @test occursin("no such file", err.msg)
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end

    @testset "validation lives in one place: set_files! inherits it" begin
        # set_files! IS set_input_files! on the chooser's element, so this is
        # not a second implementation being kept in sync -- it is the same one.
        f = timeout_fixture()
        send_create(f.fake, "page@1", "ElementHandle", "handle@1")
        @test timedwait(
            () -> Playwright.lookup_object(f.fake.connection, "handle@1") !== nothing,
            5.0,
        ) === :ok
        handle = Playwright.lookup_object(f.fake.connection, "handle@1")
        fc = FileChooser(handle, true, f.page)

        @test_throws ArgumentError set_files!(
            fc,
            UPLOAD_FIXTURE;
            name = "x",
            buffer = UInt8[1],
        )
        @test_throws ArgumentError set_files!(fc, "/no/such/file.csv")
        @test !isready(f.fake.client_messages)
        close(f.fake.connection)
    end

    # --- What reaches the wire ----------------------------------------------

    @testset "a Locator sends the selector, strictness and localPaths" begin
        f = timeout_fixture()
        loc = locator(f.page, "#file"; strict = false)
        sent = waiting_request(f.fake, () -> set_input_files!(loc, UPLOAD_FIXTURE))
        @test sent["method"] == "setInputFiles"
        @test sent["guid"] == "frame@1"
        @test sent["params"]["selector"] == "#file"
        @test sent["params"]["strict"] == false
        @test sent["params"]["localPaths"] == [UPLOAD_FIXTURE]
        @test !haskey(sent["params"], "payloads")
        close(f.fake.connection)
    end

    @testset "several paths go as a vector" begin
        f = timeout_fixture()
        loc = locator(f.page, "#file")
        sent = waiting_request(
            f.fake,
            () -> set_input_files!(loc, [UPLOAD_FIXTURE, UPLOAD_FIXTURE]),
        )
        @test sent["params"]["localPaths"] == [UPLOAD_FIXTURE, UPLOAD_FIXTURE]
        close(f.fake.connection)
    end

    @testset "the empty call clears rather than omitting" begin
        # An empty localPaths is how the protocol spells "no files"; omitting
        # both would leave the previous selection in place.
        f = timeout_fixture()
        loc = locator(f.page, "#file")
        sent = waiting_request(f.fake, () -> set_input_files!(loc))
        @test sent["params"]["localPaths"] == []
        @test !haskey(sent["params"], "payloads")
        close(f.fake.connection)
    end

    @testset "the in-memory form sends payloads, base64 by to_wire" begin
        f = timeout_fixture()
        loc = locator(f.page, "#file")
        bytes = Vector{UInt8}("a,b\n1,2\n")
        sent = waiting_request(
            f.fake,
            () -> set_input_files!(
                loc;
                name = "inline.csv",
                mime_type = "text/csv",
                buffer = bytes,
            ),
        )
        payload = only(sent["params"]["payloads"])
        @test payload["name"] == "inline.csv"
        @test payload["mimeType"] == "text/csv"
        # Encoded by to_wire rather than at the call site, which is where
        # connection.jl says wire encoding belongs.
        @test payload["buffer"] == base64encode(bytes)
        @test !haskey(sent["params"], "localPaths")
        close(f.fake.connection)
    end

    @testset "mime_type is optional" begin
        f = timeout_fixture()
        loc = locator(f.page, "#file")
        sent = waiting_request(
            f.fake,
            () -> set_input_files!(loc; name = "x.bin", buffer = UInt8[7]),
        )
        @test !haskey(only(sent["params"]["payloads"]), "mimeType")
        close(f.fake.connection)
    end

    @testset "an ElementHandle sends no selector" begin
        # The other dispatch path: ElementHandle.setInputFiles has no selector
        # or strictness, because the handle already is the element.
        f = timeout_fixture()
        send_create(f.fake, "page@1", "ElementHandle", "handle@2")
        @test timedwait(
            () -> Playwright.lookup_object(f.fake.connection, "handle@2") !== nothing,
            5.0,
        ) === :ok
        handle = Playwright.lookup_object(f.fake.connection, "handle@2")

        sent = waiting_request(f.fake, () -> set_input_files!(handle, UPLOAD_FIXTURE))
        @test sent["method"] == "setInputFiles"
        @test sent["guid"] == "handle@2"
        @test sent["params"]["localPaths"] == [UPLOAD_FIXTURE]
        @test !haskey(sent["params"], "selector")
        close(f.fake.connection)
    end

    # --- The chooser ---------------------------------------------------------

    @testset "FileChooser reads element and isMultiple" begin
        f = timeout_fixture()
        send_create(f.fake, "page@1", "ElementHandle", "handle@3")
        @test timedwait(
            () -> Playwright.lookup_object(f.fake.connection, "handle@3") !== nothing,
            5.0,
        ) === :ok
        handle = Playwright.lookup_object(f.fake.connection, "handle@3")
        fc = FileChooser(handle, true, f.page)
        @test element(fc) === handle
        @test is_multiple(fc) == true
        @test is_multiple(FileChooser(handle, false, f.page)) == false
        close(f.fake.connection)
    end

    @testset ":filechooser is opt-in, and no longer deferred" begin
        # The mirror of :download. fileChooser IS in page.yml's
        # updateSubscription enum, so the driver stays silent until asked --
        # get this wrong and the chooser never arrives.
        @test Playwright.PAGE_EVENTS[:filechooser].opt_in == true
        @test !haskey(Playwright.DEFERRED_EVENTS, :filechooser)
    end
end
