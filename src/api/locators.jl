# Locators: creating them, indexing and iterating over their matches, and the
# actions and queries that run against the element they resolve to.
#
# Every action re-resolves the selector in the browser, so each one is a
# protocol call carrying the selector, the strictness flag and a timeout.

"""
    locator(page::Page, selector; strict=true) -> Locator
    locator(frame::Frame, selector; strict=true) -> Locator

Lazy handle for `selector` (CSS, `text=`, `xpath=`, …). The selector is
re-resolved in the browser on every action.

With `strict=true` (the default, matching Playwright) acting on a selector that
matches more than one element raises a [`PlaywrightError`](@ref) rather than
silently picking one. Pass `strict=false` when you mean to work with several
matches, and reach for [`count`](@ref), [`nth`](@ref) or iteration.

```julia
sliders = locator(page, "input[type=range]"; strict=false)
count(sliders)      # 2
```
"""
locator(frame::Frame, selector::AbstractString; strict::Bool = true) =
    Locator(frame, String(selector), strict)

locator(page::Page, selector::AbstractString; strict::Bool = true) =
    locator(main_frame(page), selector; strict)

# --- Working with multiple matches ---------------------------------------

"""
    count(loc::Locator) -> Int

Number of elements `loc` currently matches. This is a protocol round-trip, and
the answer is a snapshot: a page that mutates the DOM can invalidate it
immediately.
"""
Base.count(loc::Locator) = Int(_frame_query_count(loc.frame; selector = loc.selector))

"""
    nth(loc::Locator, i) -> Locator

The `i`-th match of `loc`, 1-based (converted to Playwright's 0-based `nth=`
on the wire). The result is itself strict: it matches exactly one element by
construction, whatever `loc`'s own strictness.

Out-of-range indices are not detected here — like any locator, `nth` resolves
when it is acted upon, and acting on a non-existent match raises then.
"""
nth(loc::Locator, i::Integer) = Locator(loc.frame, "$(loc.selector) >> nth=$(i - 1)", true)

"""
    iterate(loc::Locator)

Locators are iterable, yielding one single-element `Locator` per match:

```julia
for slider in locator(page, "input[type=range]"; strict=false)
    fill(slider, "7")
end
```

**The match set is sampled once**, by a `count` call when iteration starts. A
page that adds or removes matching elements mid-loop can leave later
iterations resolving to different elements, or to none at all. That is
inherent to Playwright's lazy-selector model rather than a defect here: a
`Locator` is a query, not a snapshot of nodes.

Iterating a strict locator is allowed and simply yields at most one element —
strictness is checked on action, and `nth` has already resolved the ambiguity.
"""
function Base.iterate(loc::Locator, state = (1, count(loc)))
    i, total = state
    i > total && return nothing
    return nth(loc, i), (i + 1, total)
end

# `length` is `count`, i.e. a round-trip. Locators are deliberately NOT
# AbstractArrays: indexing is a network call and the length is not stable, so
# claiming the array interface would promise more than a selector can deliver.
# `map`, `filter` and `collect` still work via the iteration protocol.
Base.length(loc::Locator) = count(loc)
Base.eltype(::Type{Locator}) = Locator
Base.getindex(loc::Locator, i::Integer) = nth(loc, i)
Base.firstindex(::Locator) = 1
Base.lastindex(loc::Locator) = count(loc)

"""
    first(loc::Locator) -> Locator
    last(loc::Locator) -> Locator

The first or last match. Unlike Playwright's `.first()`/`.last()`, `last`
costs a `count` round-trip to find out where the end is.
"""
Base.first(loc::Locator) = nth(loc, 1)
Base.last(loc::Locator) = nth(loc, count(loc))

# --- Content and state ----------------------------------------------------

"""
    text_content(loc::Locator; timeout=30_000) -> Union{String,Nothing}

The `textContent` of the matched element (`nothing` for elements without one).
Includes text that is not rendered; see [`inner_text`](@ref) for what a user
would actually see.
"""
text_content(loc::Locator; timeout::Real = 30_000) =
    _frame_text_content(loc.frame; selector = loc.selector, strict = loc.strict, timeout)

"""
    inner_text(loc::Locator; timeout=30_000) -> String

The `innerText` of the matched element: the *rendered* text, so hidden
elements and collapsed whitespace are excluded. Contrast
[`text_content`](@ref), which returns the raw text including hidden nodes.
"""
inner_text(loc::Locator; timeout::Real = 30_000) =
    _frame_inner_text(loc.frame; selector = loc.selector, strict = loc.strict, timeout)

"""
    inner_html(loc::Locator; timeout=30_000) -> String

The `innerHTML` of the matched element.
"""
inner_html(loc::Locator; timeout::Real = 30_000) =
    _frame_inner_html(loc.frame; selector = loc.selector, strict = loc.strict, timeout)

"""
    get_attribute(loc::Locator, name; timeout=30_000) -> Union{String,Nothing}

The matched element's `name` attribute, or `nothing` when it has none.
"""
get_attribute(loc::Locator, name::AbstractString; timeout::Real = 30_000) =
    _frame_get_attribute(
        loc.frame;
        selector = loc.selector,
        strict = loc.strict,
        name,
        timeout,
    )

"""
    is_visible(loc::Locator) -> Bool

Whether the matched element is visible. Returns `false` rather than raising
when nothing matches, so it is safe to ask about elements that may not exist.
"""
is_visible(loc::Locator) =
    _frame_is_visible(loc.frame; selector = loc.selector, strict = loc.strict)

"""
    is_checked(loc::Locator; timeout=30_000) -> Bool

Whether the matched checkbox or radio input is checked.
"""
is_checked(loc::Locator; timeout::Real = 30_000) =
    _frame_is_checked(loc.frame; selector = loc.selector, strict = loc.strict, timeout)

"""
    is_enabled(loc::Locator; timeout=30_000) -> Bool

Whether the matched element is enabled (not `disabled`).
"""
is_enabled(loc::Locator; timeout::Real = 30_000) =
    _frame_is_enabled(loc.frame; selector = loc.selector, strict = loc.strict, timeout)

"""
    input_value(loc::Locator; timeout=30_000) -> String

Current value of the matched input, textarea or select element.
"""
input_value(loc::Locator; timeout::Real = 30_000) =
    _frame_input_value(loc.frame; selector = loc.selector, strict = loc.strict, timeout)

# --- Actions --------------------------------------------------------------

"""
    click(loc::Locator; timeout=30_000)

Click the matched element, waiting for it to be actionable first.
"""
click(loc::Locator; timeout::Real = 30_000) =
    _frame_click(loc.frame; selector = loc.selector, strict = loc.strict, timeout)

"""
    fill(loc::Locator, value; timeout=30_000)

Set the matched input/textarea's value to `value` (extends `Base.fill`).
"""
Base.fill(loc::Locator, value::AbstractString; timeout::Real = 30_000) = _frame_fill(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    timeout,
    value = String(value),
)

"""
    dispatch_event(loc::Locator, type, event_init=missing; timeout=30_000)

Dispatch a DOM event of `type` (`"input"`, `"change"`, `"click"`, …) on the
matched element. `event_init` is serialized with the same mapping as
[`evaluate`](@ref) arguments and becomes the event's initializer.

Unlike [`click`](@ref) this is a synthetic event, not a real user gesture: no
actionability checks run and the element is not scrolled into view. That makes
it the tool for driving controls that ordinary interaction cannot hit
precisely — setting an `input[type=range]` to an exact value, for example:

```julia
eval_on_selector(page, "#volume", "(el, v) => el.value = v", 7)
dispatch_event(locator(page, "#volume"), "input")   # let listeners react
```
"""
dispatch_event(
    loc::Locator,
    type::AbstractString,
    event_init = missing;
    timeout::Real = 30_000,
) = _frame_dispatch_event(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    type,
    eventInit = serialized_argument(event_init),
    timeout,
)
