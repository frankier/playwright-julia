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
    driver_error(detail, log=nothing) -> PlaywrightError

Build the right `PlaywrightError` subtype from a protocol error reply. `detail`
is the inner `{message, name, stack}` payload; `log` is the reply's top-level
call log (actionability retries, selector waits), appended to the message the
way upstream clients do.

An unrecognised `name` yields a [`DriverError`](@ref) rather than an error of
its own — the driver is free to introduce names this package has not seen.
"""
function driver_error(detail::AbstractDict, log = nothing)
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
    else
        DriverError
    end
    return T(message; name, stack)
end
