#!/usr/bin/env julia
#
# Generate src/generated/channels.jl from the vendored protocol spec.
#
#     julia --project=gen gen/generate.jl           # write the file
#     julia --project=gen gen/generate.jl --check    # exit non-zero if stale
#
# What is generated (SPEC-M2.md D1): the *channel layer* only — one concrete
# ChannelOwner type per protocol interface, the CHANNEL_TYPES registry, and one
# mechanical `_<interface>_<command>` function per protocol command. Nothing
# here is user-facing: the idiomatic snake_case API with docstrings, Julia
# argument order and Locator ergonomics stays hand-written in src/api/.
#
# The output is checked in (D2), so it must be byte-reproducible: everything is
# emitted in sorted order and formatted by the JuliaFormatter version pinned in
# gen/Project.toml.

using YAML
using JuliaFormatter

const REPO_ROOT = dirname(@__DIR__)
const SPEC_DIR = joinpath(REPO_ROOT, "protocol", "spec")
const OUTPUT = joinpath(REPO_ROOT, "src", "generated", "channels.jl")

# Protocol interface names that would collide in the Playwright module. Only
# the root does: the wire calls it "Playwright", which is the module itself.
const TYPE_RENAMES = Dict("Playwright" => "PlaywrightRoot")

# Scalar spec types → Julia argument types. Anything not here and not a named
# spec entry is reported as unmapped rather than silently becoming Any.
const SCALAR_TYPES = Dict(
    "string" => "AbstractString",
    "boolean" => "Bool",
    "float" => "Real",
    "int" => "Real",
    "number" => "Real",
    "binary" => "Vector{UInt8}",
    "json" => "Any",
    "any" => "Any",
    "Channel" => "ChannelOwner",
    "undefined" => "Nothing",
)

const JULIA_KEYWORDS = Set([
    "baremodule", "begin", "break", "catch", "const", "continue", "do", "else",
    "elseif", "end", "export", "false", "finally", "for", "function", "global",
    "if", "import", "let", "local", "macro", "module", "quote", "return",
    "struct", "true", "try", "using", "while", "abstract", "mutable",
    "primitive", "where", "in", "isa", "outer",
])

# ---------------------------------------------------------------------------
# Spec loading
# ---------------------------------------------------------------------------

"""
    load_spec() -> (entries, sources)

Every top-level spec entry merged across the ~19 yml files, plus a map from
entry name to the file it came from (used for the per-command provenance
comment in the output).
"""
function load_spec(specdir = SPEC_DIR)
    entries = Dict{String,Any}()
    sources = Dict{String,String}()
    for file in sort(readdir(specdir))
        endswith(file, ".yml") || continue
        for (name, node) in YAML.load_file(joinpath(specdir, file))
            key = String(name)
            haskey(entries, key) &&
                error("duplicate spec entry $key in $file and $(sources[key])")
            entries[key] = node
            sources[key] = file
        end
    end
    return entries, sources
end

kind(node) = node isa AbstractDict ? String(get(node, "type", "")) : ""
is_interface(node) = kind(node) == "interface"

"""
    subtype_closure(entries) -> Dict{String,Vector{String}}

Interface name → itself plus every interface transitively extending it. The
spec has exactly one `extends` today (ElementHandle extends JSHandle), but
resolving the general case keeps the generator honest against future spec
changes: a command declared on JSHandle must accept an ElementHandle.
"""
function subtype_closure(entries)
    interfaces = sort([n for (n, node) in entries if is_interface(node)])
    parent = Dict(
        n => (p = get(entries[n], "extends", nothing); p === nothing ? nothing : String(p))
        for n in interfaces
    )
    closure = Dict(n => Set([n]) for n in interfaces)
    for n in interfaces
        p = parent[n]
        while p !== nothing
            haskey(closure, p) || error("$n extends unknown interface $p")
            push!(closure[p], n)
            p = parent[p]
        end
    end
    return Dict(n => sort(collect(s)) for (n, s) in closure)
end

# ---------------------------------------------------------------------------
# Naming
# ---------------------------------------------------------------------------

"""
    snake(name) -> String

camelCase/PascalCase → snake_case, keeping acronym runs together:
`evalOnSelector` → `eval_on_selector`, `CDPSession` → `cdp_session`.
"""
function snake(name::AbstractString)
    s = replace(String(name), r"([A-Z]+)([A-Z][a-z])" => s"\1_\2")
    s = replace(s, r"([a-z0-9])([A-Z])" => s"\1_\2")
    return lowercase(s)
end

julia_type_name(iface::AbstractString) = get(TYPE_RENAMES, String(iface), String(iface))
channel_alias(iface::AbstractString) = julia_type_name(iface) * "Channel"
command_name(iface, command) = "_$(snake(julia_type_name(iface)))_$(snake(command))"

"Quote a parameter name that would otherwise be a Julia keyword."
safe_ident(name::AbstractString) =
    String(name) in JULIA_KEYWORDS ? "var\"$name\"" : String(name)

# ---------------------------------------------------------------------------
# Type mapping
# ---------------------------------------------------------------------------

"A spec type node, reduced to what the generator needs to emit."
struct SpecType
    julia::String     # Julia type annotation
    optional::Bool    # spec `?` suffix — omitted from the wire when unset
    channel::Bool     # resolves through from_channel on the way back
    binary::Bool      # base64 on the wire
end

"""
    map_type(node, entries, unmapped) -> SpecType

Spec type node → Julia annotation. Unrecognised types become `Any` *and* are
recorded in `unmapped`, which the generator prints: silently widening to `Any`
is how a protocol change slips through unnoticed.
"""
function map_type(node, entries, unmapped::Set{String})
    if node isa AbstractDict
        raw = String(get(node, "type", "any"))
    elseif node isa AbstractString
        raw = String(node)
    else
        push!(unmapped, string(node))
        return SpecType("Any", false, false, false)
    end

    optional = endswith(raw, "?")
    base = optional ? chop(raw) : raw

    if base in ("object", "array")
        return SpecType(base == "array" ? "AbstractVector" : "AbstractDict",
                        optional, false, false)
    elseif base == "enum"
        return SpecType("AbstractString", optional, false, false)
    elseif haskey(SCALAR_TYPES, base)
        return SpecType(SCALAR_TYPES[base], optional, base == "Channel", base == "binary")
    elseif haskey(entries, base)
        referenced = entries[base]
        k = kind(referenced)
        if k == "interface"
            return SpecType(channel_alias(base), optional, true, false)
        elseif k == "enum"
            return SpecType("AbstractString", optional, false, false)
        elseif k in ("object", "mixin")
            return SpecType("AbstractDict", optional, false, false)
        end
    end

    push!(unmapped, base)
    return SpecType("Any", optional, false, false)
end

"""
    resolve_parameters(node, entries) -> Dict{String,Any}

A command's `parameters` with `\$mixin` / `\$mixin1` / `\$mixin2` inclusions
spliced in. Only top-level inclusions matter: a mixin nested inside an object
property is part of a value we map to `AbstractDict` wholesale.
"""
function resolve_parameters(node, entries)
    node isa AbstractDict || return Dict{String,Any}()
    params = Dict{String,Any}()
    for (name, value) in node
        key = String(name)
        if startswith(key, raw"$mixin")
            mixin = get(entries, String(value), nothing)
            mixin === nothing && error("unknown mixin $value")
            merge!(params, resolve_parameters(get(mixin, "properties", nothing), entries))
        else
            params[key] = value
        end
    end
    return params
end

# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------

function emit_command(io, iface, cmd_name, cmd, entries, sources, unmapped)
    params = resolve_parameters(get(cmd, "parameters", nothing), entries)
    typed = [(name = n, spec = map_type(params[n], entries, unmapped)) for n in sort(collect(keys(params)))]
    required = [p for p in typed if !p.spec.optional]
    optional = [p for p in typed if p.spec.optional]

    returns = get(cmd, "returns", nothing)
    ret_names = returns isa AbstractDict ? sort(collect(String.(keys(returns)))) : String[]

    println(io, "# $(sources[iface]): $iface.$cmd_name")
    print(io, "function $(command_name(iface, cmd_name))(_obj::$(channel_alias(iface))")
    if !isempty(typed)
        print(io, "; ")
        args = String[]
        for p in required
            push!(args, "$(safe_ident(p.name))::$(p.spec.julia)")
        end
        for p in optional
            # `Union{Any,Nothing}` is just `Any`; leave those unannotated.
            annotation = p.spec.julia == "Any" ? "" : "::Union{$(p.spec.julia),Nothing}"
            push!(args, "$(safe_ident(p.name))$annotation = nothing")
        end
        print(io, join(args, ", "))
    end
    println(io, ")")

    println(io, "params = Dict{String,Any}()")
    for p in required
        println(io, "params[\"$(p.name)\"] = to_wire($(safe_ident(p.name)))")
    end
    for p in optional
        println(io, "$(safe_ident(p.name)) === nothing || (params[\"$(p.name)\"] = to_wire($(safe_ident(p.name))))")
    end

    if isempty(ret_names)
        println(io, "send_message(_obj, \"$cmd_name\", params)")
        println(io, "return nothing")
    else
        println(io, "result = send_message(_obj, \"$cmd_name\", params)")
        exprs = [(name = n, expr = return_expr(n, map_type(returns[n], entries, unmapped)))
                 for n in ret_names]
        if length(exprs) == 1
            println(io, "return $(exprs[1].expr)")
        else
            println(io, "return (", join(["$(safe_ident(e.name)) = $(e.expr)" for e in exprs], ", "), ")")
        end
    end
    println(io, "end")
    println(io)
    return
end

"How one field of a command's result is turned into a Julia value."
function return_expr(name, spec::SpecType)
    access = spec.optional ? "get(result, \"$name\", nothing)" : "result[\"$name\"]"
    spec.channel && return "from_channel(_obj.connection, $access)"
    spec.binary && return spec.optional ?
           "(_v = $access; _v === nothing ? nothing : base64decode(_v))" :
           "base64decode($access)"
    return access
end

function generate(; specdir = SPEC_DIR, version = read_version())
    entries, sources = load_spec(specdir)
    closure = subtype_closure(entries)
    interfaces = sort(collect(keys(closure)))
    unmapped = Set{String}()

    io = IOBuffer()
    println(io, """
        # GENERATED by gen/generate.jl from protocol/spec/*.yml (Playwright $version).
        # DO NOT EDIT — run `julia --project=gen gen/generate.jl` instead.
        #
        # The mechanical channel layer: one ChannelOwner type per protocol
        # interface and one function per protocol command, with wire-level names
        # and wire-level argument types. The documented, idiomatic API that users
        # actually call is hand-written on top of this in src/api/.
        """)

    println(io, "# --- Channel owner types ---")
    println(io)
    for iface in interfaces
        println(io, "mutable struct $(julia_type_name(iface)) <: ChannelOwner")
        println(io, "@channel_owner_fields")
        println(io, "end")
        println(io)
    end

    println(io, "# --- Wire type name → Julia type ---")
    println(io)
    for iface in interfaces
        println(io, "CHANNEL_TYPES[\"$iface\"] = $(julia_type_name(iface))")
    end
    println(io)

    println(io, """
        # Accepted receiver for each interface's commands: the interface itself plus
        # everything extending it, so a command declared on JSHandle also accepts an
        # ElementHandle.
        """)
    for iface in interfaces
        members = join([julia_type_name(s) for s in closure[iface]], ",")
        println(io, "const $(channel_alias(iface)) = Union{$members}")
    end
    println(io)

    println(io, "# --- Commands ---")
    println(io)
    for iface in interfaces
        commands = get(entries[iface], "commands", nothing)
        commands isa AbstractDict || continue
        for cmd_name in sort(collect(String.(keys(commands))))
            cmd = commands[cmd_name]
            cmd isa AbstractDict || (cmd = Dict{String,Any}())
            emit_command(io, iface, cmd_name, cmd, entries, sources, unmapped)
        end
    end

    text = format_text(String(take!(io)))
    return text, unmapped
end

function read_version()
    stamp = joinpath(REPO_ROOT, "protocol", "VERSION")
    isfile(stamp) || error("protocol/VERSION is missing — run gen/fetch_spec.jl first")
    return strip(read(stamp, String))
end

function report_unmapped(unmapped)
    if isempty(unmapped)
        @info "All spec types mapped to concrete Julia types"
    else
        @warn """
              $(length(unmapped)) spec type(s) had no Julia mapping and were emitted \
              as `Any`. Review these — an unmapped type is how a protocol change \
              slips past the generator:

              $(join(sort(collect(unmapped)), ", "))
              """
    end
end

function main(args)
    check = "--check" in args
    text, unmapped = generate()
    if check
        if !isfile(OUTPUT)
            @error "$OUTPUT does not exist — run gen/generate.jl"
            exit(1)
        elseif read(OUTPUT, String) != text
            @error """
                   $(relpath(OUTPUT, REPO_ROOT)) is stale: it differs from a fresh \
                   generation off protocol/spec/. Run `julia --project=gen \
                   gen/generate.jl` and commit the result.
                   """
            exit(1)
        end
        @info "Generated channel layer is in sync with protocol/spec/"
    else
        mkpath(dirname(OUTPUT))
        write(OUTPUT, text)
        report_unmapped(unmapped)
        @info "Wrote $(relpath(OUTPUT, REPO_ROOT))" bytes = length(text)
    end
    return nothing
end

abspath(PROGRAM_FILE) == abspath(@__FILE__) && main(ARGS)
