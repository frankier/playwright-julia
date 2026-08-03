"""
    Playwright

Drive real browsers (Chromium & Firefox) from Julia through the official
Playwright automation engine. See the README for a quick start:

```julia
using Playwright

playwright() do pw
    browser = launch(pw.chromium; headless=true)
    page = new_page(browser)
    goto(page, "https://example.com")
    println(title(page))
    close(browser)
end
```
"""
module Playwright

using JSON
using Scratch
using Downloads
using Base64
using Dates
using p7zip_jll: p7zip

export playwright,
    install,
    launch,
    new_page,
    goto,
    title,
    locator,
    click,
    text_content,
    input_value,
    screenshot,
    evaluate,
    evaluate_handle,
    eval_on_selector,
    eval_on_selector_all,
    dispose,
    nth,
    inner_text,
    inner_html,
    get_attribute,
    is_visible,
    is_checked,
    is_enabled,
    dispatch_event,
    PlaywrightError

include("driver.jl")
include("transport.jl")
include("connection.jl")
include("generated/channels.jl")
include("serializers.jl")
include("objects.jl")
include("api/lifecycle.jl")
include("api/navigation.jl")
include("api/locators.jl")
include("api/frames.jl")
include("api/evaluate.jl")
include("api/diagnostics.jl")

end # module
