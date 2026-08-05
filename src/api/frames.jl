# Frames: enumerating them, and scoping locators and evaluation into iframes.
#
# The frame tree is not held as a separate structure — it is read back out of
# the frame objects the connection already tracks, each of which carries a
# parentFrame reference in its initializer. Detachment is handled in
# connection.jl, which drops a frame from the registry on frameDetached.

"""
    FrameLocator

Lazy handle for an iframe, created by [`frame_locator`](@ref). Like a
[`Locator`](@ref) it resolves when used, not when created, so it can be built
before the frame exists.

Use [`locator`](@ref) to address elements inside it, or
[`content_frame`](@ref) to get the `Frame` itself.
"""
struct FrameLocator
    frame::Frame
    selector::String
end

"""
    frames(page::Page) -> Vector{Frame}

Every [`Frame`](@ref) in `page`: the main frame first, then its descendants in
breadth-first order. Frames detached at runtime drop out of this list.

```julia
length(frames(page))                  # 2 for a page with one iframe
[url(f) for f in frames(page)]
```

This is for *inspecting* the frame tree. To act on elements inside an iframe,
scope into it with [`frame_locator`](@ref) instead — that does not care where
the frame sits in this list.
"""
function frames(page::Page)
    conn = page.connection
    root = main_frame(page)
    children = Dict{String,Vector{Frame}}()
    lock(conn.lock) do
        for object in values(conn.objects)
            object isa Frame || continue
            parent = get(object.initializer, "parentFrame", nothing)
            parent === nothing && continue
            push!(get!(Vector{Frame}, children, parent["guid"]), object)
        end
    end

    ordered = Frame[root]
    i = 1
    while i <= length(ordered)
        # Sorted by guid so the order is stable across runs; the protocol makes
        # no promise about sibling order.
        for child in sort!(get(children, ordered[i].guid, Frame[]); by = f -> f.guid)
            push!(ordered, child)
        end
        i += 1
    end
    return ordered
end

"""
    parent_frame(frame::Frame) -> Union{Frame,Nothing}

The [`Frame`](@ref) containing `frame`, or `nothing` for a page's main frame —
which is how you tell the main frame apart from the rest.

```julia
main = only(filter(f -> parent_frame(f) === nothing, frames(page)))
```

The downward direction is [`frames`](@ref); from an element, it is
[`owner_frame`](@ref).
"""
parent_frame(frame::Frame) =
    from_channel(frame.connection, get(frame.initializer, "parentFrame", nothing))

"""
    url(frame::Frame) -> String

The URL currently loaded in `frame`, kept up to date as it navigates. For a
page, ask its main frame — or assert on it, which waits:

```julia
url(main_frame(page))
expect(page; to_have_url = r"/checkout\$")   # the assertion form
```

See [`expect`](@ref), and [`title`](@ref) for the document's title.
"""
url(frame::Frame) = get(frame.initializer, "url", "")::String

"""
    name(frame::Frame) -> String

The frame's `name` attribute, or `""` when it has none — an unnamed frame and a
frame named `""` are indistinguishable here.

```julia
findfirst(f -> name(f) == "checkout", frames(page))
```

Names are a convenience for finding a known frame; [`frame_locator`](@ref) is
the way to actually work inside one. Note this is unrelated to
[`browser_name`](@ref).
"""
name(frame::Frame) = get(frame.initializer, "name", "")::String

"""
    frame_locator(page::Page, selector) -> FrameLocator
    frame_locator(frame::Frame, selector) -> FrameLocator
    frame_locator(fl::FrameLocator, selector) -> FrameLocator

Scope into the iframe matched by `selector`. Elements inside it are addressed
by chaining a [`locator`](@ref):

```julia
inner = frame_locator(page, "iframe#child")
click(locator(inner, "button"))
evaluate(content_frame(inner), "document.title")
```

Nothing is resolved until the resulting locator is used, so this can be built
before the iframe has loaded. The `FrameLocator` form scopes into an iframe
nested inside another iframe.
"""
frame_locator(frame::Frame, selector::AbstractString) =
    FrameLocator(frame, String(selector))

frame_locator(page::Page, selector::AbstractString) =
    frame_locator(main_frame(page), selector)

frame_locator(fl::FrameLocator, selector::AbstractString) =
    FrameLocator(fl.frame, enter_frame(fl.selector, selector))

# Crossing into a frame is expressed in the selector itself, which is what
# keeps a frame-scoped Locator an ordinary Locator.
enter_frame(frame_selector, selector) =
    "$frame_selector >> internal:control=enter-frame >> $selector"

"""
    locator(fl::FrameLocator, selector; strict=true) -> Locator

Address an element inside the iframe `fl` refers to. The frame boundary is
crossed by the selector itself, so the result is an ordinary [`Locator`](@ref)
that resolves the whole chain on every action.
"""
locator(fl::FrameLocator, selector::AbstractString; strict::Bool = true) =
    Locator(fl.frame, enter_frame(fl.selector, selector), strict)

"""
    content_frame(fl::FrameLocator) -> Frame
    content_frame(loc::Locator) -> Frame

The frame an iframe element contains, so it can be evaluated in or enumerated
directly:

```julia
evaluate(content_frame(frame_locator(page, "iframe")), "document.title")
```

Raises a [`PlaywrightError`](@ref) when the selector matches nothing, or
matches an element that is not a frame.
"""
content_frame(fl::FrameLocator) = resolve_content_frame(fl.frame, fl.selector, true)
content_frame(loc::Locator) = resolve_content_frame(loc.frame, loc.selector, loc.strict)

function resolve_content_frame(frame::Frame, selector::AbstractString, strict::Bool)
    handle = _frame_query_selector(frame; selector, strict)
    handle === nothing &&
        throw(PlaywrightError("no element matches the selector \"$selector\""))
    content = _element_handle_content_frame(handle)
    content === nothing && throw(
        PlaywrightError(
            "the element matching \"$selector\" is not a frame, so it has no content frame",
        ),
    )
    return content::Frame
end

"""
    owner_frame(loc::Locator) -> Union{Frame,Nothing}

The frame that *contains* the element `loc` matches — the inverse of
[`content_frame`](@ref), which returns the frame an element contains. `nothing`
when the locator matches no element.

```julia
inner = locator(frame_locator(page, "#embed"), "h1")
owner_frame(inner) === main_frame(page)    # false: it lives in the iframe
```

Both of these resolve the locator immediately, so neither waits; see
[`wait_for_selector`](@ref) for an element that is not there yet.
"""
function owner_frame(loc::Locator)
    handle = _frame_query_selector(loc.frame; selector = loc.selector, strict = loc.strict)
    handle === nothing &&
        throw(PlaywrightError("no element matches the selector \"$(loc.selector)\""))
    return _element_handle_owner_frame(handle)
end
