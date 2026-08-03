# Locators: creating them, and the actions and queries that run against the
# element they resolve to.
#
# Every action re-resolves the selector in the browser, so each one is a
# protocol call carrying the selector, the strictness flag and a timeout.

"""
    locator(page::Page, selector) -> Locator

Lazy handle for `selector` (CSS, `text=`, `xpath=`, …). The selector is
re-resolved in the browser on every action and must match exactly one
element when acted upon.
"""
locator(page::Page, selector::AbstractString) = Locator(main_frame(page), String(selector))

"""
    text_content(loc::Locator; timeout=30_000) -> Union{String,Nothing}

The `textContent` of the matched element (`nothing` for elements without one).
"""
text_content(loc::Locator; timeout::Real = 30_000) =
    _frame_text_content(loc.frame; selector = loc.selector, strict = true, timeout)

"""
    click(loc::Locator; timeout=30_000)

Click the matched element, waiting for it to be actionable first.
"""
click(loc::Locator; timeout::Real = 30_000) =
    _frame_click(loc.frame; selector = loc.selector, strict = true, timeout)

"""
    fill(loc::Locator, value; timeout=30_000)

Set the matched input/textarea's value to `value` (extends `Base.fill`).
"""
Base.fill(loc::Locator, value::AbstractString; timeout::Real = 30_000) = _frame_fill(
    loc.frame;
    selector = loc.selector,
    strict = true,
    timeout,
    value = String(value),
)

"""
    input_value(loc::Locator; timeout=30_000) -> String

Current value of the matched input, textarea or select element.
"""
input_value(loc::Locator; timeout::Real = 30_000) =
    _frame_input_value(loc.frame; selector = loc.selector, strict = true, timeout)
