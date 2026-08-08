# Driver-side waiting: wait_for_selector and wait_for_function.
#
# Both exist so a test never has to poll from Julia. The driver already knows
# when the DOM changed and when a predicate flipped; a Julia-side `sleep` loop
# can only guess, and guesses either too slowly (a stall on every check) or too
# eagerly (a flake). Everything here is one protocol call that the driver holds
# open until the condition is met or the timeout runs out.

"The `state` values `waitForSelector` accepts (frame.yml:736)."
const SELECTOR_STATES = ("attached", "detached", "visible", "hidden")

# `:visible` and `"visible"` mean the same thing; anything else is a typo worth
# catching here rather than as an opaque driver error a round-trip later.
function selector_state(state)
    state === nothing && return nothing
    s = String(state)
    s in SELECTOR_STATES || throw(
        ArgumentError(
            "invalid selector state `:$s`. Valid states: " *
            join((":$v" for v in SELECTOR_STATES), ", "),
        ),
    )
    return s
end

"""
    wait_for_selector(target, selector; state=nothing, strict=true, timeout=nothing)
    wait_for_selector(loc::Locator; state=nothing, timeout=nothing)

Wait until `selector` reaches `state` in `target` (a [`Page`](@ref) or
[`Frame`](@ref)), and return the matching [`ElementHandle`](@ref).

`state` is one of:

| State | Waits for the element to be |
|---|---|
| `:attached` | present in the DOM (the driver's default) |
| `:detached` | absent from the DOM |
| `:visible` | present *and* non-empty with no `visibility: hidden` |
| `:hidden` | absent, or present but not visible |

`:detached` and `:hidden` return `nothing` — there is no element to hand back.

`timeout` is in milliseconds and defaults to the [`set_default_timeout!`](@ref)
cascade. A selector that never arrives raises [`TimeoutError`](@ref), which is
what makes "the element is late" distinguishable from "the page threw".

```julia
el = wait_for_selector(page, "#late"; state=:visible)
text_content(locator(page, "#late"))
```

Passing a [`Locator`](@ref) instead uses its own selector and strictness:

```julia
wait_for_selector(locator(page, "#late"); state=:visible)
```
"""
function wait_for_selector(
    frame::Frame,
    selector::AbstractString;
    state = nothing,
    strict::Bool = true,
    timeout::MaybeTimeout = nothing,
)
    return _frame_wait_for_selector(
        frame;
        selector = String(selector),
        strict,
        state = selector_state(state),
        timeout = resolve_timeout(frame, timeout),
    )
end

wait_for_selector(page::Page, selector::AbstractString; kwargs...) =
    wait_for_selector(main_frame(page), selector; kwargs...)

wait_for_selector(loc::Locator; state = nothing, timeout::MaybeTimeout = nothing) =
    wait_for_selector(loc.frame, loc.selector; state, strict = loc.strict, timeout)

"""
    wait_for_function(target, expression, arg=missing; polling=:raf, timeout=nothing, is_function=nothing)

Wait until `expression` returns a truthy value in `target` (a [`Page`](@ref),
[`Frame`](@ref) or [`Locator`](@ref)), and return a `JSHandle` for that value.

`arg` is passed to the expression when it is a function, serialized with the
same mapping as [`evaluate`](@ref).

`polling` is `:raf` (the default — re-check on every animation frame, which is
right for anything the browser paints) or a number of milliseconds for a fixed
interval, which is better for a condition that is not tied to rendering.

`timeout` defaults to the [`set_default_timeout!`](@ref) cascade. A predicate
that never becomes true raises [`TimeoutError`](@ref). A predicate that *throws*
raises [`DriverError`](@ref) — the distinction between a condition that has not
happened yet and one that can never happen.

```julia
wait_for_function(page, "() => window.ready")
wait_for_function(page, "n => document.querySelectorAll('li').length > n", 3)
```
"""
function wait_for_function(
    frame::Frame,
    expression::AbstractString,
    arg = missing;
    polling = :raf,
    timeout::MaybeTimeout = nothing,
    is_function::Union{Bool,Nothing} = nothing,
)
    return _frame_wait_for_function(
        frame;
        expression = String(expression),
        arg = serialized_argument(arg),
        isFunction = is_function,
        pollingInterval = polling_interval(polling),
        timeout = resolve_timeout(frame, timeout),
    )
end

wait_for_function(page::Page, expression::AbstractString, arg = missing; kwargs...) =
    wait_for_function(main_frame(page), expression, arg; kwargs...)

wait_for_function(loc::Locator, expression::AbstractString, arg = missing; kwargs...) =
    wait_for_function(loc.frame, expression, arg; kwargs...)

# The protocol has no "raf" literal: omitting pollingInterval *is* raf
# ("When present, polls on interval. Otherwise, polls on raf." — frame.yml:722).
polling_interval(polling::Nothing) = nothing
polling_interval(polling::Real) = polling
function polling_interval(polling::Symbol)
    polling === :raf && return nothing
    throw(
        ArgumentError(
            "invalid polling `:$polling`. Use `:raf` or an interval in milliseconds.",
        ),
    )
end
