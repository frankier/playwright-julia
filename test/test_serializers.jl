# Unit tests for src/serializers.jl — the SerializedValue codec (SPEC-M2.md D3).
#
# Fully hermetic: no browser, no Node. This is where evaluate's correctness is
# actually decided, so every row of the D3 table is asserted in both
# directions, along with nesting, circular references and handle hoisting.

using Dates

# A JSHandle needs a Connection to exist, but the codec never touches it — it
# only collects handles into the SerializedArgument's handles array.
function fake_handle(guid::AbstractString)
    transport = Playwright.Transport(IOBuffer(), IOBuffer(); on_message = _ -> nothing)
    connection = Playwright.Connection(transport)
    return Playwright.JSHandle(connection, "JSHandle", guid, Dict{String,Any}())
end

@testset "serializers" begin
    # Julia value → wire value, discarding the (usually empty) handles array.
    ser(x) = first(Playwright.to_serialized(x))
    # Julia → wire → Julia.
    rt(x) = Playwright.from_serialized(ser(x))

    @testset "numbers" begin
        @test ser(7) == Dict("n" => 7)
        @test ser(7.5) == Dict("n" => 7.5)
        @test ser(3 // 4) == Dict("n" => 0.75)

        # JS has one number type, so everything comes back Float64 — narrowing
        # 7.0 to 7 would be a lie about what the page returned.
        @test rt(7) === 7.0
        @test rt(7.5) === 7.5
        @test Playwright.from_serialized(Dict("n" => 7)) === 7.0

        # ...and the natural comparison still holds.
        @test rt(7) == 7
    end

    @testset "non-finite numbers" begin
        @test ser(NaN) == Dict("v" => "NaN")
        @test ser(Inf) == Dict("v" => "Infinity")
        @test ser(-Inf) == Dict("v" => "-Infinity")
        @test ser(-0.0) == Dict("v" => "-0")

        @test isnan(rt(NaN))
        @test rt(Inf) === Inf
        @test rt(-Inf) === -Inf
        @test rt(-0.0) === -0.0
        # -0.0 must not collapse into 0.0 on the way out.
        @test ser(0.0) == Dict("n" => 0.0)
    end

    @testset "strings, symbols and booleans" begin
        @test ser("hi") == Dict("s" => "hi")
        @test ser(:hi) == Dict("s" => "hi")
        @test rt("hi") === "hi"
        @test rt(:hi) === "hi"          # Symbols are strings on the way back

        @test ser(true) == Dict("b" => true)
        @test ser(false) == Dict("b" => false)
        @test rt(true) === true
        @test rt(false) === false
        # Bool must not be mistaken for a number in either direction.
        @test Playwright.from_serialized(Dict("b" => true)) === true
    end

    @testset "null and undefined round-trip distinctly" begin
        @test ser(nothing) == Dict("v" => "null")
        @test ser(missing) == Dict("v" => "undefined")
        @test rt(nothing) === nothing
        @test rt(missing) === missing
    end

    @testset "arrays" begin
        v = ser([1, "two", true])
        @test v["a"] == [Dict("n" => 1), Dict("s" => "two"), Dict("b" => true)]

        out = rt([1, "two", true])
        @test out isa Vector{Any}
        @test out == [1.0, "two", true]

        @test rt((1, 2)) == [1.0, 2.0]      # Tuples serialize as arrays
        @test rt(Any[]) == []
    end

    @testset "objects" begin
        v = ser(Dict("a" => 1))
        @test v["o"] == [Dict("k" => "a", "v" => Dict("n" => 1))]

        out = rt(Dict("a" => 1, "b" => "two"))
        @test out isa Dict{String,Any}
        @test out == Dict("a" => 1.0, "b" => "two")

        # NamedTuples are the ergonomic way to pass an object argument.
        @test rt((a = 21, b = "x")) == Dict("a" => 21.0, "b" => "x")
        # Non-string keys are stringified, matching JS object keys.
        @test rt(Dict(:a => 1)) == Dict("a" => 1.0)
    end

    @testset "regexes" begin
        @test ser(r"ab+c")["r"]["p"] == "ab+c"
        @test ser(r"ab+c"i)["r"]["f"] == "i"
        @test occursin("m", ser(r"x"m)["r"]["f"])
        @test occursin("s", ser(r"x"s)["r"]["f"])

        out = rt(r"ab+c"i)
        @test out isa Regex
        @test out.pattern == "ab+c"
        @test occursin(out, "ABBC")        # the i flag survived

        # JS-only flags (g, u, y) have no Julia equivalent and are dropped
        # rather than erroring.
        back = Playwright.from_serialized(Dict("r" => Dict("p" => "x", "f" => "gimuy")))
        @test back.pattern == "x"
        @test occursin(back, "X")
    end

    @testset "dates" begin
        dt = DateTime(2026, 8, 3, 12, 34, 56, 789)
        @test ser(dt) == Dict("d" => "2026-08-03T12:34:56.789Z")
        @test rt(dt) === dt
        # Whole-second timestamps are still emitted with milliseconds, which is
        # what JS's toISOString produces.
        @test ser(DateTime(2026, 1, 1))["d"] == "2026-01-01T00:00:00.000Z"
    end

    @testset "nested structures survive a round-trip" begin
        nested = Dict(
            "list" => [1, [2, 3], Dict("deep" => "yes")],
            "obj" => (x = [true, nothing], y = Dict("z" => 1.5)),
        )
        out = rt(nested)
        @test out["list"][2] == [2.0, 3.0]
        @test out["list"][3]["deep"] == "yes"
        @test out["obj"]["x"] == [true, nothing]
        @test out["obj"]["y"]["z"] == 1.5
    end

    @testset "handles are hoisted into the handles array" begin
        h1 = fake_handle("handle@1")
        h2 = fake_handle("handle@2")

        value, handles = Playwright.to_serialized(h1)
        @test value == Dict("h" => 0)          # 0-based index on the wire
        @test handles == [h1]

        # A NamedTuple, not a Dict: "first-seen order" is only meaningful over a
        # container with a defined iteration order.
        value, handles = Playwright.to_serialized((a = h1, b = [h2, h1]))
        @test handles == [h1, h2]              # first-seen order, deduplicated
        entries = Dict(e["k"] => e["v"] for e in value["o"])
        @test entries["a"] == Dict("h" => 0)
        @test entries["b"]["a"] == [Dict("h" => 1), Dict("h" => 0)]

        # ...and a handle comes back out given the handles it was hoisted into.
        @test Playwright.from_serialized(Dict("h" => 1), [h1, h2]) === h2
    end

    @testset "circular references use id/ref" begin
        a = Any[1]
        push!(a, a)                            # a[2] === a

        value = ser(a)
        @test haskey(value, "id")
        @test value["a"][2] == Dict("ref" => value["id"])

        out = Playwright.from_serialized(value)
        @test out[1] == 1.0
        @test out[2] === out                   # the cycle is reconstructed

        # Shared (non-cyclic) substructure deserializes to the *same* object,
        # not two equal copies.
        shared = Dict("k" => "v")
        two = ser([shared, shared])
        back = Playwright.from_serialized(two)
        @test back[1] === back[2]

        # A dict that contains itself works the same way.
        d = Dict{String,Any}("self" => nothing)
        d["self"] = d
        back = Playwright.from_serialized(ser(d))
        @test back["self"] === back
    end

    @testset "unknown tags name the tag" begin
        err = try
            Playwright.from_serialized(Dict("bi" => "12345"))
            nothing
        catch e
            e
        end
        @test err isa Playwright.PlaywrightError
        @test occursin("bi", err.message)

        # An empty value carries no tag at all, which is equally unusable.
        @test_throws Playwright.PlaywrightError Playwright.from_serialized(Dict())
        # `h` without a handles array cannot be resolved.
        @test_throws Playwright.PlaywrightError Playwright.from_serialized(Dict("h" => 0))
    end

    @testset "unserializable Julia values are rejected clearly" begin
        err = try
            Playwright.to_serialized(sin)
            nothing
        catch e
            e
        end
        @test err isa Playwright.PlaywrightError
        @test occursin("serialize", err.message)
        @test occursin("sin", err.message)
    end
end
