# Locators: creating them, indexing and iterating over their matches, and the
# actions and queries that run against the element they resolve to.
#
# Every action re-resolves the selector in the browser, so each one is a
# protocol call carrying the selector, the strictness flag and a timeout.

"""
    locator(page::Page, selector; strict=nothing) -> Locator
    locator(frame::Frame, selector; strict=nothing) -> Locator

Lazy handle for `selector` (CSS, `text=`, `xpath=`, …). The selector is
re-resolved in the browser on every action.

Under strictness — `true` unless something says otherwise, matching Playwright
— acting on a selector that matches more than one element raises a
[`PlaywrightError`](@ref) rather than silently picking one. Pass
`strict=false` when you mean to work with several matches, and reach for
[`count`](@ref), [`nth`](@ref) or iteration.

```julia
sliders = locator(page, "input[type=range]"; strict=false)
count(sliders)      # 2
```

Omitting `strict` resolves the cascade — frame, then page, then context, then
`true` — so a suite that works with lists throughout can say it once with
[`set_default_strict!`](@ref) instead of on every call. Strictness is resolved
**here**, at construction: the `Locator` carries the answer, so changing a
default afterwards does not reach back into locators that already exist.
"""
locator(frame::Frame, selector::AbstractString; strict::Union{Bool,Nothing} = nothing) =
    Locator(frame, String(selector), resolve_strict(frame, strict))

locator(page::Page, selector::AbstractString; strict::Union{Bool,Nothing} = nothing) =
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

```julia
rows = locator(page, "tr"; strict = false)
text_content(nth(rows, 2))    # the second row; `rows[2]` is the same thing
```

See [`locator`](@ref) for strictness, and [`first`](@ref) / [`last`](@ref) for
the two common cases.

Out-of-range indices are not detected here — like any locator, `nth` resolves
when it is acted upon, and acting on a non-existent match raises then.
"""
nth(loc::Locator, i::Integer) = Locator(loc.frame, "$(loc.selector) >> nth=$(i - 1)", true)

"""
    iterate(loc::Locator)

Locators are iterable, yielding one single-element `Locator` per match:

```julia
for slider in locator(page, "input[type=range]"; strict=false)
    set_value!(slider, "7")
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

The first match, as a single-element locator. Free — it is
[`nth`](@ref)`(loc, 1)` and needs no round-trip to work that out.

```julia
first(locator(page, "li"; strict = false))
```
"""
Base.first(loc::Locator) = nth(loc, 1)

"""
    last(loc::Locator) -> Locator

The last match, as a single-element locator.

Unlike Playwright's `.last()`, this costs a [`count`](@ref) round-trip to find
out where the end is — the selector suffix it builds needs a concrete index.

```julia
last(locator(page, "li"; strict = false))
```
"""
Base.last(loc::Locator) = nth(loc, count(loc))

# --- Content and state ----------------------------------------------------

"""
    text_content(loc::Locator; timeout=nothing) -> Union{String,Nothing}

The `textContent` of the matched element (`nothing` for elements without one).
Includes text that is not rendered; see [`inner_text`](@ref) for what a user
would actually see.

This reads once and returns. To *assert* on text, reach for
[`expect`](@ref) instead — it retries, so it passes as soon as late-arriving
text arrives rather than failing on the first look.

```julia
text_content(locator(page, "#status"))              # a read
expect(locator(page, "#status"); to_have_text = "ready")   # an assertion
```
"""
text_content(loc::Locator; timeout::MaybeTimeout = nothing) = _frame_text_content(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    timeout = resolve_timeout(loc, timeout),
)

"""
    inner_text(loc::Locator; timeout=nothing) -> String

The `innerText` of the matched element: the *rendered* text, so hidden
elements and collapsed whitespace are excluded. Contrast
[`text_content`](@ref), which returns the raw text including hidden nodes.

```julia
# <p>visible <span style="display:none">hidden</span></p>
inner_text(locator(page, "p"))     # "visible"
text_content(locator(page, "p"))   # "visible hidden"
```
"""
inner_text(loc::Locator; timeout::MaybeTimeout = nothing) = _frame_inner_text(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    timeout = resolve_timeout(loc, timeout),
)

"""
    inner_html(loc::Locator; timeout=nothing) -> String

The `innerHTML` of the matched element — its markup, not its text. For text
use [`inner_text`](@ref) or [`text_content`](@ref).

```julia
inner_html(locator(page, "#log"))   # "<li class=\"greeting\">Hello</li>"
```
"""
inner_html(loc::Locator; timeout::MaybeTimeout = nothing) = _frame_inner_html(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    timeout = resolve_timeout(loc, timeout),
)

"""
    get_attribute(loc::Locator, name; timeout=nothing) -> Union{String,Nothing}

The matched element's `name` attribute, or `nothing` when it has none. An
attribute present but empty gives `""`, which is not the same answer.

```julia
get_attribute(locator(page, "#link"), "href")     # "/somewhere"
get_attribute(locator(page, "#link"), "nope")     # nothing
```

To assert on an attribute rather than read it, use
`expect(loc; to_have_attribute = "href" => "/somewhere")` — see
[`expect`](@ref) — which retries while this does not.
"""
get_attribute(loc::Locator, name::AbstractString; timeout::MaybeTimeout = nothing) =
    _frame_get_attribute(
        loc.frame;
        selector = loc.selector,
        strict = loc.strict,
        name,
        timeout = resolve_timeout(loc, timeout),
    )

"""
    is_visible(loc::Locator) -> Bool

Whether the matched element is visible. Returns `false` rather than raising
when nothing matches, so it is safe to ask about elements that may not exist.

It answers about *now*, with no waiting, which makes it the wrong tool for
"has it appeared yet" — that is [`expect`](@ref)'s job.

```julia
is_visible(locator(page, "#banner"))                   # false, maybe not yet
expect(locator(page, "#banner"); to_be_visible = true) # waits for it
```

!!! note "No `timeout`, unlike its siblings"
    [`is_checked`](@ref) and [`is_enabled`](@ref) take a `timeout`; this does
    not, and the difference is deliberate rather than an oversight. **The
    missing keyword is the signal.** Returning `false` for an element that is
    not there is precisely what makes `is_visible` safe to ask about things
    that may never exist, and a `timeout` would advertise a wait it does not
    perform. A keyword that had to be ignored would be worse than one that is
    absent.
"""
is_visible(loc::Locator) =
    _frame_is_visible(loc.frame; selector = loc.selector, strict = loc.strict)

"""
    is_checked(loc::Locator; timeout=nothing) -> Bool

Whether the matched checkbox or radio input is checked.

```julia
click!(locator(page, "#accept"))
is_checked(locator(page, "#accept"))   # true
```

As with [`is_visible`](@ref), this reads rather than waits; for an assertion
use `expect(loc; to_be_checked = true)` — see [`expect`](@ref).
"""
is_checked(loc::Locator; timeout::MaybeTimeout = nothing) = _frame_is_checked(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    timeout = resolve_timeout(loc, timeout),
)

"""
    is_enabled(loc::Locator; timeout=nothing) -> Bool

Whether the matched element is enabled (not `disabled`).

```julia
is_enabled(locator(page, "button#submit"))   # false while the form is invalid
```

For an assertion that waits for a button to become enabled, use
`expect(loc; to_be_enabled = true)` — see [`expect`](@ref).
"""
is_enabled(loc::Locator; timeout::MaybeTimeout = nothing) = _frame_is_enabled(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    timeout = resolve_timeout(loc, timeout),
)

"""
    input_value(loc::Locator; timeout=nothing) -> String

Current value of the matched input, textarea or select element. This is the
live value, which is not the same as the `value` *attribute* the HTML was
served with — see [`get_attribute`](@ref) for that one.

```julia
set_value!(locator(page, "#name"), "Ada")
input_value(locator(page, "#name"))   # "Ada"
```

The assertion form is `expect(loc; to_have_value = "Ada")` — see
[`expect`](@ref).
"""
input_value(loc::Locator; timeout::MaybeTimeout = nothing) = _frame_input_value(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    timeout = resolve_timeout(loc, timeout),
)

# --- Actions --------------------------------------------------------------

"""
    click!(loc::Locator; timeout=nothing)

Click the matched element, waiting for it to be actionable first: attached,
visible, stable, able to receive events and not disabled. That wait is why a
click at the right moment needs no `sleep` before it.

```julia
click!(locator(page, "#greet"))
expect(locator(page, "li.greeting"); to_have_text = "Hello!")
```

`timeout` covers the whole wait and defaults to the
[`set_default_timeout!`](@ref) cascade; a click that never becomes actionable
raises [`TimeoutError`](@ref). For a synthetic event with none of those checks,
see [`dispatch_event!`](@ref).
"""
click!(loc::Locator; timeout::MaybeTimeout = nothing) = _frame_click(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    timeout = resolve_timeout(loc, timeout),
)

"""
    set_value!(loc::Locator, value; timeout=nothing)

Set the matched input/textarea's value to `value`. This is Playwright's
`fill` — the name differs because a bang is the Julia signal that the call
changes what the page can see, and `fill!` would have been ambiguous with the
`Base.fill!` every `using Playwright` already has in scope.

This clears the field first and fires an `input` event, which is what makes it
different from assigning `.value` through [`evaluate`](@ref) — the page's
listeners actually run.

```julia
set_value!(locator(page, "#name"), "Ada")
expect(locator(page, "#name"); to_have_value = "Ada")
```

Elements that refuse to be filled — a `range` input, say — want
[`evaluate`](@ref) plus [`dispatch_event!`](@ref) instead.
"""
set_value!(loc::Locator, value::AbstractString; timeout::MaybeTimeout = nothing) =
    _frame_fill(
        loc.frame;
        selector = loc.selector,
        strict = loc.strict,
        timeout = resolve_timeout(loc, timeout),
        value = String(value),
    )

"""
    dispatch_event!(loc::Locator, type, event_init=missing; timeout=nothing)

Dispatch a DOM event of `type` (`"input"`, `"change"`, `"click"`, …) on the
matched element. `event_init` is serialized with the same mapping as
[`evaluate`](@ref) arguments and becomes the event's initializer.

Unlike [`click!`](@ref) this is a synthetic event, not a real user gesture: no
actionability checks run and the element is not scrolled into view. That makes
it the tool for driving controls that ordinary interaction cannot hit
precisely — setting an `input[type=range]` to an exact value, for example:

```julia
eval_on_selector(page, "#volume", "(el, v) => el.value = v", 7)
dispatch_event!(locator(page, "#volume"), "input")   # let listeners react
```
"""
dispatch_event!(
    loc::Locator,
    type::AbstractString,
    event_init = missing;
    timeout::MaybeTimeout = nothing,
) = _frame_dispatch_event(
    loc.frame;
    selector = loc.selector,
    strict = loc.strict,
    type,
    eventInit = serialized_argument(event_init),
    timeout = resolve_timeout(loc, timeout),
)

# --- Evaluating against a locator's element (T7) --------------------------
#
# Before this, driving a range input meant reaching into `loc.frame` and
# `loc.selector` by hand — the `fill_range!` helper in SPEC-M2.md did exactly
# that. A Locator already knows its selector and its strictness, so making it
# an evaluate target removes the reason to look inside one.

"""
    evaluate(loc::Locator, expression, arg=missing; is_function=nothing) -> Any

Evaluate `expression` with the element `loc` matches as its first argument, and
return the result converted to Julia.

The locator's own selector and `strict` flag are used, so a strict locator
matching several elements raises here just as it would for [`click!`](@ref).
This is the precise tool for controls that ordinary interaction cannot drive
exactly — pair it with [`dispatch_event!`](@ref) so the page's listeners still
run:

```julia
slider = locator(page, "#volume")
evaluate(slider, "(el, v) => el.value = v", 7)
dispatch_event!(slider, "input")
```

Raises a [`PlaywrightError`](@ref) when nothing matches. See
[`evaluate_all`](@ref) for the every-match form.
"""
evaluate(loc::Locator, expression::AbstractString, arg = missing; kwargs...) =
    eval_on_selector(
        loc.frame,
        loc.selector,
        expression,
        arg;
        strict = loc.strict,
        kwargs...,
    )

"""
    evaluate_all(loc::Locator, expression, arg=missing; is_function=nothing) -> Any

Evaluate `expression` with an array of **all** the elements `loc` matches as
its first argument.

Unlike [`evaluate`](@ref) this never raises for a locator that matches nothing
— the array is simply empty — and it ignores `strict`, because "all of them" is
not an ambiguity that strictness has anything to decide.

```julia
evaluate_all(locator(page, "input"; strict=false), "els => els.length")
```
"""
evaluate_all(loc::Locator, expression::AbstractString, arg = missing; kwargs...) =
    eval_on_selector_all(loc.frame, loc.selector, expression, arg; kwargs...)

"""
    element_handle(loc::Locator) -> Union{ElementHandle,Nothing}

Resolve `loc` now and return an [`ElementHandle`](@ref) for the match, or
`nothing` if there is none.

```julia
handle = element_handle(locator(page, "#chart"))
evaluate(page, "el => el.getBoundingClientRect().width", handle)
dispose!(handle)
```

This is a snapshot, and that is the whole difference from a locator: the handle
keeps pointing at *that* element, so it goes stale if the page re-renders,
whereas a locator re-resolves on every use. Prefer the locator unless you
specifically need to hold on to one element — for instance to pass it into
[`evaluate`](@ref) as an argument. Handles should be [`dispose!`](@ref)d when
you are done with them.

To wait for an element that is not there yet, use
[`wait_for_selector`](@ref) instead — this does not wait.

!!! note "Two calls, differing only in whether they wait"
    That `element_handle` resolves now and `wait_for_selector` waits is the
    one distinction between them, and it lives in the documentation rather
    than in either name. The pair is kept because it mirrors Playwright's own
    two calls: a reader arriving from `playwright-python` or the Node client
    expects both to exist with exactly these meanings. Collapsing them into
    one function with a `wait` keyword would read better in isolation and
    surprise the people most likely to open this package.
"""
element_handle(loc::Locator) =
    _frame_query_selector(loc.frame; selector = loc.selector, strict = loc.strict)

# --- Public accessors -----------------------------------------------------
#
# These were readable as fields all along; blessing them as functions is what
# lets the field access stop being part of the public surface, and gives the
# three of them somewhere to be documented.

"""
    frame(loc::Locator) -> Frame

The [`Frame`](@ref) `loc` resolves against. Every locator belongs to exactly
one frame — the main frame when it was built from a [`Page`](@ref).

```julia
frame(locator(page, "h1")) === main_frame(page)   # true
```
"""
frame(loc::Locator) = loc.frame

"""
    selector(loc::Locator) -> String

The selector string `loc` was built with, including any `>> nth=` suffix added
by [`nth`](@ref) or iteration.

```julia
selector(nth(locator(page, "li"; strict = false), 3))   # "li >> nth=2"
```
"""
selector(loc::Locator) = loc.selector

"""
    is_strict(loc::Locator) -> Bool

Whether `loc` raises when its selector matches more than one element. See
[`locator`](@ref) for what strictness costs and buys.

```julia
is_strict(locator(page, "li"))                   # true, the default
is_strict(locator(page, "li"; strict = false))   # false
```
"""
is_strict(loc::Locator) = loc.strict
