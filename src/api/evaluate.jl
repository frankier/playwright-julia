# Running JavaScript in the page: evaluate, JSHandles and their disposal.
#
# Everything here funnels through the SerializedValue codec in serializers.jl:
# arguments go out as a SerializedArgument (a value plus a handles array) and
# results come back as a SerializedValue.

"Anything JavaScript can be evaluated against: a page, a frame, or a handle."
const EvaluateTarget = Union{Page,Frame,JSHandleChannel}

"Wrap a Julia value as a protocol `SerializedArgument`."
function serialized_argument(arg)
    value, handles = to_serialized(arg)
    return Dict{String,Any}("value" => value, "handles" => handles)
end

"""
    evaluate(target, expression, arg=missing; is_function=nothing) -> Any

Evaluate `expression` in `target` (a `Page`, `Frame` or `JSHandle`) and return
the result converted to Julia. `arg` is passed to the expression when it is a
function; it is serialized with the same mapping as the return value.

Whether `expression` is a function is detected by the driver, exactly as it is
for Playwright's other string-based clients, so JavaScript pasted from the
Playwright docs behaves the way it does there. Pass `is_function=true`/`false`
to decide it yourself.

Numbers arrive as `Float64` — JavaScript has a single number type — so
`evaluate(page, "1 + 1")` is `2.0`, which still `== 2`.

```julia
evaluate(page, "1 + 1")                      # 2.0
evaluate(page, "x => x.a * 2", (a = 21,))    # 42.0
evaluate(page, "document.title")             # "Example Domain"
```
"""
evaluate(page::Page, expression::AbstractString, arg = missing; kwargs...) =
    evaluate(main_frame(page), expression, arg; kwargs...)

function evaluate(
    frame::Frame,
    expression::AbstractString,
    arg = missing;
    is_function::Union{Bool,Nothing} = nothing,
)
    value = _frame_evaluate_expression(
        frame;
        expression,
        arg = serialized_argument(arg),
        isFunction = is_function,
    )
    return from_serialized(value)
end

function evaluate(
    handle::JSHandleChannel,
    expression::AbstractString,
    arg = missing;
    is_function::Union{Bool,Nothing} = nothing,
)
    value = _js_handle_evaluate_expression(
        handle;
        expression,
        arg = serialized_argument(arg),
        isFunction = is_function,
    )
    return from_serialized(value)
end

"""
    evaluate_handle(target, expression, arg=missing; is_function=nothing) -> JSHandle
    evaluate_handle(f, target, expression, arg=missing; is_function=nothing)

Evaluate `expression` and keep the result *in the browser*, returning a
`JSHandle` that refers to it. Use this for values that cannot cross the wire
(DOM nodes, functions, objects with cycles you do not want to copy).

Handles hold a browser-side reference and must be released with
[`dispose`](@ref). The block form does it for you, on the way out of the block
whether or not the body threw, and is the recommended way to use handles:

```julia
evaluate_handle(page, "() => window.app") do app
    evaluate(app, "a => a.ready")
end   # disposed here, even if the body throws
```

A handle can be passed straight back in as `arg` to a later `evaluate`.
"""
evaluate_handle(page::Page, expression::AbstractString, arg = missing; kwargs...) =
    evaluate_handle(main_frame(page), expression, arg; kwargs...)

evaluate_handle(
    frame::Frame,
    expression::AbstractString,
    arg = missing;
    is_function::Union{Bool,Nothing} = nothing,
) = _frame_evaluate_expression_handle(
    frame;
    expression,
    arg = serialized_argument(arg),
    isFunction = is_function,
)::JSHandle

evaluate_handle(
    handle::JSHandleChannel,
    expression::AbstractString,
    arg = missing;
    is_function::Union{Bool,Nothing} = nothing,
) = _js_handle_evaluate_expression_handle(
    handle;
    expression,
    arg = serialized_argument(arg),
    isFunction = is_function,
)::JSHandle

function evaluate_handle(
    f::Function,
    target::EvaluateTarget,
    expression::AbstractString,
    arg = missing;
    kwargs...,
)
    handle = evaluate_handle(target, expression, arg; kwargs...)
    try
        return f(handle)
    finally
        dispose(handle)
    end
end

"""
    dispose(handle::JSHandle)

Release a handle's browser-side reference. Handles left undisposed are
reclaimed when their page or context closes, so leaking one costs memory
rather than correctness — but a long-lived page can accumulate them.

Prefer the block form of [`evaluate_handle`](@ref), which disposes for you.
"""
dispose(handle::JSHandleChannel) = _js_handle_dispose(handle)

"""
    eval_on_selector(target, selector, expression, arg=missing; is_function=nothing, strict=true) -> Any

Evaluate `expression` with the element matching `selector` as its first
argument, and return the result converted to Julia. Raises a
[`PlaywrightError`](@ref) when nothing matches.

```julia
eval_on_selector(page, "#name", "el => el.value")
```
"""
eval_on_selector(
    page::Page,
    selector::AbstractString,
    expression::AbstractString,
    arg = missing;
    kwargs...,
) = eval_on_selector(main_frame(page), selector, expression, arg; kwargs...)

function eval_on_selector(
    frame::Frame,
    selector::AbstractString,
    expression::AbstractString,
    arg = missing;
    is_function::Union{Bool,Nothing} = nothing,
    strict::Bool = true,
)
    value = _frame_eval_on_selector(
        frame;
        selector,
        expression,
        arg = serialized_argument(arg),
        isFunction = is_function,
        strict,
    )
    return from_serialized(value)
end

"""
    eval_on_selector_all(target, selector, expression, arg=missing; is_function=nothing) -> Any

Evaluate `expression` with an array of *all* elements matching `selector` as
its first argument. Unlike [`eval_on_selector`](@ref) this never raises for a
selector that matches nothing — the array is simply empty.

```julia
eval_on_selector_all(page, "input", "els => els.length")
```
"""
eval_on_selector_all(
    page::Page,
    selector::AbstractString,
    expression::AbstractString,
    arg = missing;
    kwargs...,
) = eval_on_selector_all(main_frame(page), selector, expression, arg; kwargs...)

function eval_on_selector_all(
    frame::Frame,
    selector::AbstractString,
    expression::AbstractString,
    arg = missing;
    is_function::Union{Bool,Nothing} = nothing,
)
    value = _frame_eval_on_selector_all(
        frame;
        selector,
        expression,
        arg = serialized_argument(arg),
        isFunction = is_function,
    )
    return from_serialized(value)
end
