# Navigation and page-level capture.

"""
    goto(page::Page, url; timeout=30_000, wait_until="load") -> Union{Response,Nothing}

Navigate `page` to `url` and wait for the navigation to finish. `wait_until`
is one of `"load"`, `"domcontentloaded"`, `"networkidle"` or `"commit"`.
"""
function goto(
    page::Page,
    url::AbstractString;
    timeout::Real = 30_000,
    wait_until::AbstractString = "load",
)
    return _frame_goto(main_frame(page); url, timeout, waitUntil = wait_until)
end

"""
    title(page::Page) -> String

Title of the document currently loaded in `page`.
"""
title(page::Page) = _frame_title(main_frame(page))

"""
    screenshot(page::Page; path=nothing, timeout=30_000) -> Vector{UInt8}

Capture a PNG screenshot of `page`, returning its bytes and writing them to
`path` when given.
"""
function screenshot(
    page::Page;
    path::Union{AbstractString,Nothing} = nothing,
    timeout::Real = 30_000,
)
    bytes = _page_screenshot(page; timeout, type = "png")
    path === nothing || write(path, bytes)
    return bytes
end
