# Locators

A [`Locator`](@ref) is a **query, not an element**. It holds a frame, a
selector string and a strictness flag, and nothing else — no reference to a
node in the browser. Every action re-resolves the selector at the moment it
runs.

```julia
loc = locator(page, "#name")     # nothing has happened yet; no round trip
set_value!(loc, "Ada")                 # now the selector is resolved, and acted on
```

That is the whole design, and everything below follows from it. A locator
built before a re-render still works afterwards, because there was never a node
to go stale.

## Selectors

The selector string is passed to Playwright, which understands more than CSS:

| Form | Matches |
|---|---|
| `"#name"`, `".row td"` | CSS, the default |
| `"text=Submit"` | by visible text |
| `"xpath=//div[@role='main']"` | XPath |
| `"#outer >> .inner"` | chained: `.inner` within `#outer` |

## Strictness

By default a locator is **strict**: acting on a selector that matches more than
one element raises rather than silently picking the first.

```julia
click!(locator(page, "li"))                    # raises if there are three <li>s
click!(locator(page, "li"; strict = false))    # clicks the first
```

Strictness is checked **on action**, but it is *resolved* on construction: the
locator carries the answer, so a default changed afterwards does not reach back
into locators that already exist.

A suite that works with lists throughout no longer has to repeat the keyword.
[`set_default_strict!`](@ref) cascades frame → page → context, exactly as
[`set_default_timeout!`](@ref) does, and an explicit `strict =` still wins:

```julia
set_default_strict!(ctx, false)     # this suite works with lists
rows = locator(page, "tr")          # ...so this needs no keyword
one = locator(page, "#submit"; strict = true)   # and this overrides it
```

## Several matches

A locator that may match many is countable, indexable and iterable:

```julia
rows = locator(page, "tr"; strict = false)

count(rows)             # 3 — a protocol round trip
nth(rows, 2)            # the second row, 1-based; `rows[2]` is the same
first(rows)             # free
last(rows)              # costs a `count` to find the end

for row in rows
    println(text_content(row))
end
```

Each of these gives back a **single-element locator**, which is strict by
construction — `nth` has already resolved the ambiguity that strictness exists
to catch.

!!! warning "A `Locator` is deliberately not an `AbstractArray`"
    Indexing is a network call and the length is not stable between two calls.
    Claiming the array interface would promise more than a selector can
    deliver. Iteration samples the match set **once**, with a `count` round
    trip, when the loop starts — a page that adds or removes matching elements
    mid-loop can leave later iterations resolving elsewhere, or nowhere.

!!! note "These names are public but invisible to `checkdocs`"
    `count`, `length`, `first`, `last`, `iterate` and `getindex` extend their
    `Base` counterparts rather than taking new names, so they work unqualified
    and do **not** appear in `names(Playwright)`. The documentation gate is
    `checkdocs = :exports`, so it cannot see them: they are public surface
    standing outside the check that guarantees public surface is documented.

    That hole is real and accepted rather than unnoticed. Extending `Base` is
    the correct Julia design for the iteration and indexing protocol, and
    exporting these names would shadow `Base` for the whole session — a
    concretely worse trade, as the package found when `fill` became
    [`set_value!`](@ref) rather than an exported `fill`. The
    [API reference](@ref "Base extensions") lists them explicitly so that
    being outside the gate does not also mean being undocumented.

## Reading

| Call | Returns |
|---|---|
| [`text_content`](@ref) | `textContent` — raw, including hidden nodes |
| [`inner_text`](@ref) | `innerText` — rendered, hidden text excluded |
| [`inner_html`](@ref) | `innerHTML` — markup |
| [`input_value`](@ref) | an input's live value |
| [`get_attribute`](@ref) | one attribute, or `nothing` |
| [`is_visible`](@ref), [`is_checked`](@ref), [`is_enabled`](@ref) | state |

**Every one of these reads once and returns.** None of them waits. That makes
them the wrong tool for "has it appeared yet", and the right tool for "what is
there now, having already established that it is settled".

```julia
# Wrong: reads too early, fails, and the failure looks like a bug in the page
@test text_content(locator(page, "#status")) == "ready"

# Right: waits for it, then the read is safe
expect(locator(page, "#status"); to_have_text = "ready")
```

See [Assertions](@ref).

## Acting

```julia
click!(locator(page, "#greet"))
set_value!(locator(page, "#name"), "Ada")
```

[`click!`](@ref) waits for the element to be **actionable** first: attached,
visible, stable, able to receive events, and not disabled. That wait is why a
click on a button that is enabled a moment later needs no `sleep` in front of
it.

[`set_value!`](@ref) clears the field and fires an `input` event, which is what makes
it different from assigning `.value` through `evaluate` — the page's listeners
actually run.

For controls ordinary interaction cannot drive exactly — a range input, say —
combine [`evaluate`](@ref) with [`dispatch_event!`](@ref):

```julia
slider = locator(page, "#volume")
evaluate(slider, "(el, v) => el.value = v", 7)
dispatch_event!(slider, "input")            # let the listeners react
```

## Locators inside iframes

An iframe is a separate document, and a page-level locator cannot see into one.
Scope in with [`frame_locator`](@ref):

```julia
inner = frame_locator(page, "iframe#checkout")
click!(locator(inner, "button[type=submit]"))
```

`frame_locator` chains, for an iframe inside an iframe. The two directions
between an element and a frame are [`content_frame`](@ref) — the frame an
`<iframe>` element contains — and [`owner_frame`](@ref) — the frame an element
lives in.

To inspect the frame tree rather than act inside it, use [`frames`](@ref),
[`parent_frame`](@ref), [`url`](@ref) and [`frame_name`](@ref).

## Handles, and when to want one

[`element_handle`](@ref) resolves a locator *now* and gives back an
[`ElementHandle`](@ref) — a real reference to one element, which goes stale
when the page re-renders.

Prefer the locator. The one good reason to want a handle is to pass an element
into JavaScript as an argument:

```julia
handle = element_handle(locator(page, "#chart"))
try
    evaluate(page, "el => el.getBoundingClientRect().width", handle)
finally
    dispose!(handle)
end
```

[`element_handle`](@ref) does not wait; [`wait_for_selector`](@ref) is the form
that does. See [Waiting](@ref).

## Reading a locator back

[`frame`](@ref), [`selector`](@ref) and [`is_strict`](@ref) return the three
things a locator holds, which is occasionally useful when writing a helper that
takes one.

```julia
selector(nth(locator(page, "li"; strict = false), 3))   # "li >> nth=2"
```
