# Unit tests for src/transport.jl — framing over in-memory pipes, no browser.

@testset "transport" begin
    @testset "round-trips messages through a pipe" begin
        wire = Pipe()
        Base.link_pipe!(wire)
        received = Channel{Any}(10)
        transport =
            Playwright.Transport(wire.out, wire.in; on_message = msg -> put!(received, msg))
        Playwright.start_reading!(transport)

        msg1 = Dict{String,Any}(
            "id" => 1,
            "method" => "initialize",
            "params" => Dict{String,Any}("sdkLanguage" => "julia"),
        )
        msg2 = Dict{String,Any}("id" => 2, "method" => "ping")
        Playwright.send(transport, msg1)
        Playwright.send(transport, msg2)

        got1 = take_within!(received, "a value on `received`")
        got2 = take_within!(received, "a value on `received`")
        @test got1["id"] == 1
        @test got1["params"]["sdkLanguage"] == "julia"
        @test got2["method"] == "ping"
        close(transport)
    end

    @testset "parses a frame delivered one byte at a time" begin
        wire = Pipe()
        Base.link_pipe!(wire)
        received = Channel{Any}(1)
        transport =
            Playwright.Transport(wire.out, devnull; on_message = msg -> put!(received, msg))
        Playwright.start_reading!(transport)

        payload = Vector{UInt8}(codeunits("{\"id\":42}"))
        frame = vcat(reinterpret(UInt8, [htol(UInt32(length(payload)))]), payload)
        for byte in frame
            write(wire.in, byte)
            flush(wire.in)
        end
        @test take_within!(received, "a value on `received`")["id"] == 42
        close(transport)
    end

    @testset "EOF mid-frame closes cleanly instead of hanging" begin
        wire = Pipe()
        Base.link_pipe!(wire)
        closed = Channel{Bool}(1)
        transport = Playwright.Transport(
            wire.out,
            devnull;
            on_message = _ -> nothing,
            on_close = () -> put!(closed, true),
        )
        Playwright.start_reading!(transport)

        # Announce a 100-byte frame but deliver only 3 bytes, then hang up.
        write(wire.in, htol(UInt32(100)))
        write(wire.in, UInt8[0x7b, 0x22, 0x69])
        close(wire.in)

        @test take_within!(closed, "a value on `closed`")      # on_close fired
        await(transport.reader)
        @test transport.closed
    end

    @testset "send on a closed transport raises" begin
        wire = Pipe()
        Base.link_pipe!(wire)
        transport = Playwright.Transport(wire.out, wire.in; on_message = _ -> nothing)
        close(transport)
        @test_throws Exception Playwright.send(transport, Dict{String,Any}("id" => 1))
    end
end
