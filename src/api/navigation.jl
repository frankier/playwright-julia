# Navigation and page-level capture.

"""
    goto(page::Page, url; timeout=nothing, wait_until="load") -> Union{Response,Nothing}

Navigate `page` to `url` and wait for the navigation to finish. `wait_until`
is one of `"load"`, `"domcontentloaded"`, `"networkidle"` or `"commit"`.

`timeout` defaults to the navigation timeout in force for `page` — see
[`set_default_navigation_timeout!`](@ref).
"""
function goto(
    page::Page,
    url::AbstractString;
    timeout::MaybeTimeout = nothing,
    wait_until::AbstractString = "load",
)
    return _frame_goto(
        main_frame(page);
        url,
        timeout = resolve_navigation_timeout(page, timeout),
        waitUntil = wait_until,
    )
end

"""
    title(page::Page) -> String

Title of the document currently loaded in `page`.
"""
title(page::Page) = _frame_title(main_frame(page))

"""
    screenshot(page::Page; path=nothing, timeout=nothing) -> Vector{UInt8}

Capture a PNG screenshot of `page`, returning its bytes and writing them to
`path` when given.

`timeout` defaults to the action timeout in force for `page` — see
[`set_default_timeout!`](@ref).
"""
function screenshot(
    page::Page;
    path::Union{AbstractString,Nothing} = nothing,
    timeout::MaybeTimeout = nothing,
)
    bytes = _page_screenshot(page; timeout = resolve_timeout(page, timeout), type = "png")
    path === nothing || write(path, bytes)
    return bytes
end
