# The SerializedValue / SerializedArgument codec (SPEC-M2.md D3).
#
# This is the bridge between Julia values and JavaScript values: everything
# `evaluate` sends and receives passes through here. It is hand-written rather
# than generated because the interesting parts — the handles side-channel and
# the id/ref bookkeeping for circular references — are not expressible as a
# mechanical transcription of serialized.yml.
#
# Wire shape: a value is a single-key object tagging its type, e.g. {"n": 7},
# {"s": "hi"}, {"a": [...]}. Containers additionally carry an "id", and a
# repeat occurrence of an already-serialized container becomes {"ref": id}.

const ISO8601_MS = dateformat"yyyy-mm-dd\THH:MM:SS.sss\Z"

# JS regex flags with a Julia equivalent. The rest (g, u, y) are dropped: they
# describe how a match is *driven*, which Julia's Regex has no notion of.
const REGEX_FLAGS =
    [(Base.PCRE.CASELESS, 'i'), (Base.PCRE.MULTILINE, 'm'), (Base.PCRE.DOTALL, 's')]
const JULIA_REGEX_FLAGS = "imsxa"

serialize_error(msg::AbstractString) = throw(DriverError(msg))

"""
    to_serialized(value) -> (serialized, handles)

Convert a Julia value to a protocol `SerializedValue`, hoisting any
[`JSHandle`](@ref)s it contains into `handles` (the `SerializedArgument`
handles array) and replacing them with `{"h": index}` references.

Circular and shared structures are preserved: each container is tagged with an
`id`, and later occurrences of the same object become `{"ref": id}`.

```julia
to_serialized(Dict("a" => 21))   # (Dict("o" => [...], "id" => 1), Any[])
```
"""
function to_serialized(value)
    handles = ChannelOwner[]
    visited = IdDict{Any,Int}()
    return _serialize(value, handles, visited), handles
end

_serialize(::Nothing, handles, visited) = Dict{String,Any}("v" => "null")
_serialize(::Missing, handles, visited) = Dict{String,Any}("v" => "undefined")
_serialize(x::Bool, handles, visited) = Dict{String,Any}("b" => x)
_serialize(x::AbstractString, handles, visited) = Dict{String,Any}("s" => String(x))
_serialize(x::Symbol, handles, visited) = Dict{String,Any}("s" => String(x))
_serialize(x::DateTime, handles, visited) =
    Dict{String,Any}("d" => Dates.format(x, ISO8601_MS))

function _serialize(x::Real, handles, visited)
    f = float(x)
    isnan(f) && return Dict{String,Any}("v" => "NaN")
    isinf(f) && return Dict{String,Any}("v" => f > 0 ? "Infinity" : "-Infinity")
    # JS distinguishes -0 from 0, and so does the wire format.
    (f == 0 && signbit(f)) && return Dict{String,Any}("v" => "-0")
    return Dict{String,Any}("n" => x isa Integer ? x : f)
end

function _serialize(x::Regex, handles, visited)
    flags = join(c for (bit, c) in REGEX_FLAGS if x.compile_options & bit != 0)
    return Dict{String,Any}("r" => Dict{String,Any}("p" => x.pattern, "f" => flags))
end

function _serialize(handle::ChannelOwner, handles, visited)
    index = findfirst(h -> h === handle, handles)
    if index === nothing
        push!(handles, handle)
        index = length(handles)
    end
    return Dict{String,Any}("h" => index - 1)   # 0-based on the wire
end

_serialize(x::Union{AbstractVector,Tuple}, handles, visited) =
    _serialize_container(x, visited) do id
        Dict{String,Any}(
            "a" => Any[_serialize(item, handles, visited) for item in x],
            "id" => id,
        )
    end

_serialize(x::Union{AbstractDict,NamedTuple}, handles, visited) =
    _serialize_container(x, visited) do id
        entries = Any[
            Dict{String,Any}("k" => String(k), "v" => _serialize(v, handles, visited))
            for (k, v) in pairs(x)
        ]
        Dict{String,Any}("o" => entries, "id" => id)
    end

_serialize(x, handles, visited) = serialize_error(
    "cannot serialize a value of type $(typeof(x)) for the browser; supported " *
    "types are numbers, strings, symbols, booleans, nothing, missing, dates, " *
    "regexes, arrays, dictionaries, named tuples and JSHandles",
)

"""
Assign `x` an id and build its wire body, or emit a `ref` if it has already
been serialized. Registering the id *before* `build` runs is what stops a
self-referential structure from recursing forever.
"""
function _serialize_container(build, x, visited)
    haskey(visited, x) && return Dict{String,Any}("ref" => visited[x])
    id = length(visited) + 1
    visited[x] = id
    return build(id)
end

"""
    from_serialized(value, handles=nothing) -> Any

Convert a protocol `SerializedValue` back to Julia. `handles` is the
`SerializedArgument` handles array, needed only when the value contains
`{"h": index}` references.

Numbers always come back as `Float64` — JavaScript has a single number type,
so reporting `7` rather than `7.0` would misrepresent what the page returned.
`==` comparisons are unaffected.

```jldoctest
julia> Playwright.from_serialized(Dict("n" => 7))
7.0

julia> Playwright.from_serialized(Dict("n" => 7)) == 7
true

julia> Playwright.from_serialized(Dict("s" => "hi"))
"hi"

julia> Playwright.from_serialized(Dict("v" => "null")) === nothing
true

julia> Playwright.from_serialized(Dict("a" => [Dict("n" => 1), Dict("n" => 2)], "id" => 1))
2-element Vector{Any}:
 1.0
 2.0
```
"""
from_serialized(value, handles = nothing) = _deserialize(value, handles, Dict{Int,Any}())

function _deserialize(value::AbstractDict, handles, refs)
    if haskey(value, "ref")
        id = value["ref"]
        haskey(refs, id) && return refs[id]
        serialize_error("serialized value references unknown id $id")
    end

    haskey(value, "n") && return Float64(value["n"])
    haskey(value, "b") && return Bool(value["b"])
    haskey(value, "s") && return String(value["s"])
    haskey(value, "d") && return DateTime(rstrip(String(value["d"]), 'Z'))
    haskey(value, "v") && return _deserialize_literal(String(value["v"]))
    haskey(value, "r") && return _deserialize_regex(value["r"])
    haskey(value, "a") && return _deserialize_array(value, handles, refs)
    haskey(value, "o") && return _deserialize_object(value, handles, refs)

    if haskey(value, "h")
        handles === nothing && serialize_error(
            "serialized value contains a handle reference {\"h\": $(value["h"])} " *
            "but no handles array was supplied",
        )
        index = Int(value["h"]) + 1
        checkbounds(Bool, handles, index) || serialize_error(
            "handle index $(value["h"]) is out of range for $(length(handles)) handle(s)",
        )
        return handles[index]
    end

    tags = join(sort(collect(String.(keys(value)))), ", ")
    return serialize_error(
        "unsupported serialized value tag(s): $tags. Playwright.jl understands " *
        "n, b, s, v, d, r, a, o and h; values such as BigInt (bi), URL (u), " *
        "typed arrays (ta) and Error objects (e) are not converted — return a " *
        "plain value from the expression instead",
    )
end

_deserialize(value, handles, refs) =
    serialize_error("expected a serialized value object, got $(typeof(value))")

function _deserialize_literal(literal::AbstractString)
    literal == "null" && return nothing
    literal == "undefined" && return missing
    literal == "NaN" && return NaN
    literal == "Infinity" && return Inf
    literal == "-Infinity" && return -Inf
    literal == "-0" && return -0.0
    return serialize_error("unsupported serialized literal: $literal")
end

function _deserialize_regex(spec::AbstractDict)
    flags = filter(c -> c in JULIA_REGEX_FLAGS, String(get(spec, "f", "")))
    return Regex(String(spec["p"]), flags)
end

# Arrays and objects register themselves in `refs` before their children are
# converted, so a container that contains itself resolves to the same object.
function _deserialize_array(value::AbstractDict, handles, refs)
    out = Vector{Any}()
    _register!(refs, value, out)
    for item in value["a"]
        push!(out, _deserialize(item, handles, refs))
    end
    return out
end

function _deserialize_object(value::AbstractDict, handles, refs)
    out = Dict{String,Any}()
    _register!(refs, value, out)
    for entry in value["o"]
        out[String(entry["k"])] = _deserialize(entry["v"], handles, refs)
    end
    return out
end

function _register!(refs, value::AbstractDict, out)
    id = get(value, "id", nothing)
    id === nothing || (refs[Int(id)] = out)
    return out
end
