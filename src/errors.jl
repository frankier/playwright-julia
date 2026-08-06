# Error taxonomy. Every failure surfaced from the driver is a `PlaywrightError`,
# but callers can branch on *why* it failed without matching on message text.
#
# Classification is driven entirely by the `name` field the driver puts on its
# error replies. Probed against the vendored 1.61.1 driver: a locator timeout
# arrives as "TimeoutError", a call against a closed page/context/browser as
# "TargetClosedError", and JS exceptions and navigation failures alike as
# "Error".

"""
    PlaywrightError

Abstract supertype of every error surfaced from the Playwright driver.

Catch this to handle any driver failure:

```julia
try
    click!(locator(page, "#go"))
catch e
    e isa PlaywrightError || rethrow()
    @warn "click! failed" e.message
end
```

Every concrete subtype carries the driver's `message` (with the call log
appended, as upstream clients do), `name` and `stack`. Branch on the subtype to
tell failure kinds apart:

| Subtype | Raised when |
|---|---|
| [`TimeoutError`](@ref) | an operation exceeded its timeout |
| [`TargetClosedError`](@ref) | the page, context or browser closed under the call |
| [`AssertionFailure`](@ref) | a retrying assertion never matched |
| [`DriverError`](@ref) | anything else, including JS exceptions |

Constructing one directly is rarely useful, but it shows the shape:

```jldoctest
julia> e = DriverError("boom"; name = "Error")
DriverError("boom", "Error", "")

julia> e isa PlaywrightError
true

julia> e.message
"boom"

julia> sprint(showerror, e)
"DriverError: boom"

julia> TimeoutError("too slow") isa PlaywrightError
true
```

!!! note "Changed in milestone 3"
    `PlaywrightError` used to be a concrete struct. It is now abstract, so
    `PlaywrightError(msg)` no longer constructs — use [`DriverError`](@ref).
    `catch e isa PlaywrightError` and `e.message` are unaffected.
"""
abstract type PlaywrightError <: Exception end

# The concrete types differ only in meaning, so their bodies are identical:
# the driver triple plus a keyword constructor.
for T in (:DriverError, :TimeoutError, :TargetClosedError, :AssertionFailure)
    @eval begin
        struct $T <: PlaywrightError
            message::String
            name::String
            stack::String
        end

        $T(message::AbstractString; name = "Error", stack = "") =
            $T(String(message), String(name), String(stack))
    end
end

@doc """
    DriverError(message; name="Error", stack="")

An unclassified driver failure — the catch-all of the taxonomy, and what a JS
exception raised inside [`evaluate`](@ref) becomes. Any driver error name this
package does not recognise arrives here too, so a future Playwright release
cannot produce an error that escapes [`PlaywrightError`](@ref).

```julia
try
    evaluate(page, "() => { throw new Error('boom') }")
catch e
    e isa DriverError    # true
    occursin("boom", e.message)
end
```
""" DriverError

@doc """
    TimeoutError(message; name="Error", stack="")

An operation exceeded its timeout: a selector that never appeared, a navigation
that never settled, a retrying assertion's underlying wait.

Distinguishing this from [`DriverError`](@ref) is the point of the taxonomy — a
selector that is merely late is a different problem from a page that threw.

```julia
try
    click!(locator(page, "#never"); timeout = 1_000)
catch e
    e isa TimeoutError && @info "still not there after a second"
end
```

The timeout that ran out is the one resolved by the
[`set_default_timeout!`](@ref) cascade. To retry on a timeout rather than
raise, see [`retry_until`](@ref)'s `on_timeout` option.
""" TimeoutError

@doc """
    TargetClosedError(message; name="Error", stack="")

The page, context or browser the call targeted was closed underneath it.

This is a *lifecycle* error rather than a failure of the call: the usual cause
is a `close` in a `finally` racing work still in flight, or acting on a page
whose context has already gone.

```julia
close!(page)
try
    title(page)
catch e
    e isa TargetClosedError    # true
end
```

See [`PlaywrightError`](@ref) for the rest of the taxonomy.
""" TargetClosedError

@doc """
    AssertionFailure(message; name="Error", stack="")

A retrying assertion never matched within its timeout. The message carries both
the expected and the received value, which is the difference between this and a
bare [`TimeoutError`](@ref) — an assertion that fails should say what it saw.

Raised by [`expect`](@ref):

```julia
try
    expect(locator(page, "h1"); to_have_text = "Wrong", timeout = 1_000)
catch e
    e isa AssertionFailure
    @info e.message    # names both the expected and the received text
end
```

[`retry_until`](@ref) with `on_timeout = :false` is the way to get a `Bool`
instead of this, so a check can sit inside `@test`.
""" AssertionFailure

Base.showerror(io::IO, e::PlaywrightError) = print(io, nameof(typeof(e)), ": ", e.message)

"""
    driver_error(detail, log=nothing, details=nothing) -> PlaywrightError

Build the right `PlaywrightError` subtype from a protocol error reply. `detail`
is the inner `{message, name, stack}` payload; `log` is the reply's top-level
call log (actionability retries, selector waits), appended to the message the
way upstream clients do; `details` is the reply's top-level `errorDetails`,
which `frame.expect` uses to report what it actually received.

An unrecognised `name` yields a [`DriverError`](@ref) rather than an error of
its own — the driver is free to introduce names this package has not seen.
"""
function driver_error(detail::AbstractDict, log = nothing, details = nothing)
    message = get(detail, "message", "unknown driver error")
    if log !== nothing && !isempty(log)
        message *= "\nCall log:\n" * join(log, "\n")
    end
    name = get(detail, "name", "Error")
    stack = get(detail, "stack", "")
    T = if name == "TimeoutError"
        TimeoutError
    elseif name == "TargetClosedError"
        TargetClosedError
    elseif name == "ExpectError"
        # A failed assertion, which api/expect.jl re-raises with the expected
        # and received values spelled out. Left as an ExpectFailure here rather
        # than an AssertionFailure because only the caller knows what was
        # expected — this end only knows what came back.
        ExpectFailure
    else
        DriverError
    end
    T === ExpectFailure && return ExpectFailure(message, name, stack, details)
    return T(message; name, stack)
end

"""
    ExpectFailure

Internal: a raw `frame.expect` rejection, before the caller has turned it into
an [`AssertionFailure`](@ref). Carries the driver's `errorDetails`, which is
where the *received* value lives — the call log has it only as prose.

Users never see this; `expect` catches it and re-raises an `AssertionFailure`
whose message names both values. It is a `PlaywrightError` so that an escape
through some path `expect` does not cover still satisfies the taxonomy.
"""
struct ExpectFailure <: PlaywrightError
    message::String
    name::String
    stack::String
    details::Any
end

"Received value from an `expect` rejection, decoded, or `nothing` if absent."
function received_value(e::ExpectFailure)
    e.details isa AbstractDict || return nothing
    received = get(e.details, "received", nothing)
    received isa AbstractDict || return nothing
    haskey(received, "value") || return nothing
    return from_serialized(received["value"])
end

"The driver's own explanation, when it gave one (e.g. \"element(s) not found\")."
function custom_error_message(e::ExpectFailure)
    e.details isa AbstractDict || return nothing
    return get(e.details, "customErrorMessage", nothing)
end

"Whether the assertion ran out of time rather than failing outright."
timed_out(e::ExpectFailure) =
    e.details isa AbstractDict && get(e.details, "timedOut", false) === true
