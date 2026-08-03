# Tests for the generated channel layer (src/generated/channels.jl) and the
# generator that writes it (gen/generate.jl).
#
# The first testset is hermetic: it inspects the checked-in generated code
# through the loaded Playwright module, needing no `gen` environment. The rest
# shell out to gen/generate.jl and are skipped with a clear message when `gen`
# is not instantiated — a plain `Pkg.test()` must not require it.

const REPO = dirname(@__DIR__)

"Whether the gen/ environment is instantiated and can load its dependencies."
function gen_available()
    isfile(joinpath(REPO, "gen", "Manifest.toml")) || return false
    return success(
        pipeline(
            Cmd(
                `$(Base.julia_cmd()) --project=$(joinpath(REPO, "gen")) -e "using YAML, JuliaFormatter"`,
            );
            stdout = devnull,
            stderr = devnull,
        ),
    )
end

"Run gen/generate.jl with `args`, returning (success, combined output)."
function run_generator(args::Vector{String} = String[])
    out = IOBuffer()
    cmd = Cmd(
        `$(Base.julia_cmd()) --project=$(joinpath(REPO, "gen")) $(joinpath(REPO, "gen", "generate.jl")) $args`,
    )
    ok = success(pipeline(cmd; stdout = out, stderr = out))
    return ok, String(take!(out))
end

"The text of a generated function, from its signature to its closing `end`."
function command_body(text::AbstractString, name::AbstractString)
    lines = split(text, '\n')
    start = findfirst(l -> startswith(l, "function $name("), lines)
    start === nothing && return ""
    stop = findnext(l -> l == "end", lines, start)
    return join(lines[start:something(stop, length(lines))], '\n')
end

@testset "codegen" begin
    @testset "generated channel layer" begin
        path = joinpath(REPO, "src", "generated", "channels.jl")
        @test isfile(path)
        header = first(eachline(path))
        @test occursin("GENERATED", header)
        @test occursin("gen/generate.jl", header)
        @test occursin(Playwright.PLAYWRIGHT_VERSION, header)

        # Milestone-1 types must survive the move out of src/objects.jl, and
        # the generated set is much wider than what milestone 1 hand-wrote.
        for type in [
            :PlaywrightRoot,
            :BrowserType,
            :Browser,
            :BrowserContext,
            :Page,
            :Frame,
            :Response,
            :Request,
            :JSHandle,
            :ElementHandle,
            :Worker,
        ]
            @test isdefined(Playwright, type)
            @test getfield(Playwright, type) <: Playwright.ChannelOwner
        end
        @test Playwright.CHANNEL_TYPES["Playwright"] === Playwright.PlaywrightRoot
        @test Playwright.CHANNEL_TYPES["Page"] === Playwright.Page

        # Commands the milestone-2 API is built on.
        for fn in [
            :_frame_goto,
            :_frame_title,
            :_frame_click,
            :_frame_fill,
            :_frame_evaluate_expression,
            :_frame_dispatch_event,
            :_frame_query_count,
            :_page_screenshot,
            :_browser_type_launch,
            :_js_handle_evaluate_expression,
        ]
            @test isdefined(Playwright, fn)
        end

        # A command declared on JSHandle must accept an ElementHandle (the
        # spec's one `extends` relationship).
        @test Playwright.ElementHandle <: Playwright.JSHandleChannel
        @test Playwright.JSHandle <: Playwright.JSHandleChannel
        @test !(Playwright.Page <: Playwright.JSHandleChannel)
    end

    if !gen_available()
        @info "Skipping generator tests: gen/ is not instantiated " *
              "(run `julia --project=gen -e 'using Pkg; Pkg.instantiate()'`)"
    else
        @testset "--check tracks the checked-in output" begin
            ok, output = run_generator(["--check"])
            @test ok
            @test occursin("in sync", output)

            # A one-character edit must be caught, and --check must not repair it.
            path = joinpath(REPO, "src", "generated", "channels.jl")
            original = read(path, String)
            try
                write(path, original * "\n# tampered\n")
                stale_ok, stale_output = run_generator(["--check"])
                @test !stale_ok
                @test occursin("stale", stale_output)
                @test read(path, String) == original * "\n# tampered\n"
            finally
                write(path, original)
            end
        end

        @testset "generation is reproducible" begin
            path = joinpath(REPO, "src", "generated", "channels.jl")
            original = read(path, String)
            rm(path)
            ok, _ = run_generator()
            @test ok
            @test read(path, String) == original
        end

        @testset "output shape, from a fixture spec" begin
            script = """
            include(joinpath("$(escape_string(REPO))", "gen", "generate.jl"))
            text, unmapped = generate(;
                specdir = joinpath("$(escape_string(REPO))", "test", "fixtures", "spec"),
                version = "0.0.0-fixture",
            )
            print(text)
            print("\\nUNMAPPED:", join(sort(collect(unmapped)), ","))
            """
            out = IOBuffer()
            cmd = Cmd(`$(Base.julia_cmd()) --project=$(joinpath(REPO, "gen")) -e $script`)
            @test success(pipeline(cmd; stdout = out, stderr = devnull))
            text = String(take!(out))

            @test occursin("mutable struct Widget <: ChannelOwner", text)
            @test occursin("CHANNEL_TYPES[\"Widget\"] = Widget", text)
            # Inheritance: FancyGadget extends Gadget, so Gadget's commands take both.
            @test occursin("const GadgetChannel = Union{FancyGadget,Gadget}", text)
            @test occursin("const WidgetChannel = Union{Widget}", text)

            poke = command_body(text, "_widget_poke")
            # Mixin properties are spliced in: `timeout` is required, `slowMo` optional.
            @test occursin("timeout::Real", poke)
            @test occursin("slowMo::Union{Real,Nothing} = nothing", poke)
            @test occursin("selector::AbstractString", poke)
            @test occursin("strict::Union{Bool,Nothing} = nothing", poke)
            # A named object type becomes AbstractDict; a keyword-named parameter
            # is emitted quoted so the generated file parses.
            @test occursin("position::Union{AbstractDict,Nothing} = nothing", poke)
            @test occursin("var\"end\"", poke)
            # Optional parameters are omitted from the wire when unset.
            @test occursin(
                "strict === nothing || (params[\"strict\"] = to_wire(strict))",
                poke,
            )
            # A single channel-typed result resolves through from_channel.
            @test occursin("return from_channel(_obj.connection, result[\"gadget\"])", poke)

            @test occursin(
                "return base64decode(result[\"binary\"])",
                command_body(text, "_widget_snap"),
            )
            @test occursin("return nothing", command_body(text, "_widget_reset"))
            # Several result fields come back as a NamedTuple, in sorted order —
            # everything is emitted sorted so the output is byte-reproducible.
            @test occursin(
                "return (count = get(result, \"count\", nothing), value = result[\"value\"])",
                command_body(text, "_gadget_ping"),
            )

            # An unrecognised type widens to Any, but is reported rather than
            # silently swallowed — that report is what makes reviewing the real
            # spec's coverage possible.
            @test occursin("thing::Any", command_body(text, "_widget_mystery"))
            @test occursin("UNMAPPED:NotAThingWeKnow", text)
        end
    end
end
