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
    click(locator(page, "#go"))
catch e
    e isa PlaywrightError || rethrow()
    @warn "click failed" e.message
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
exception raised inside `evaluate` becomes.
""" DriverError

@doc """
    TimeoutError(message; name="Error", stack="")

An operation exceeded its timeout: a selector that never appeared, a navigation
that never settled, a retrying assertion's underlying wait.

Distinguishing this from [`DriverError`](@ref) is the point of the taxonomy — a
selector that is merely late is a different problem from a page that threw.
""" TimeoutError

@doc """
    TargetClosedError(message; name="Error", stack="")

The page, context or browser the call targeted was closed underneath it.
""" TargetClosedError

@doc """
    AssertionFailure(message; name="Error", stack="")

A retrying assertion never matched within its timeout. The message carries both
the expected and the received value.
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
