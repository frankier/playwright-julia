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
using p7zip_jll: p7zip

export playwright, install,
       launch, new_page, goto, title, locator,
       click, text_content, screenshot,
       PlaywrightError

include("driver.jl")
include("transport.jl")

"""
    playwright(f) -> result of `f`

Start the Playwright driver, call `f(pw)` with the root `PlaywrightAPI`
object (fields `chromium` and `firefox`), and guarantee driver shutdown
when the block exits — normally or by exception.
"""
function playwright end

end # module
