# Artifact capture: PDF, the Artifact wrapper, tracing and video.
#
# What a test suite needs when it goes red in CI and the assertion message is
# not enough — evidence of what the browser was actually doing. These are the
# outputs a caller can hand to somebody else: a zip for the upstream trace
# viewer, a video file, a PDF.
#
# Everything here writes only to a path the caller supplied. The package never
# chooses a location of its own.

"""
    pdf(page::Page; path=nothing, kwargs...) -> Vector{UInt8}

Render `page` to PDF, returning the bytes and writing them to `path` when
given — the same shape as [`screenshot`](@ref).

```julia
bytes = pdf(page; path = "artifacts/page.pdf", format = "A4")
```

| Option | Meaning |
|---|---|
| `format` | paper size, e.g. `"A4"` or `"Letter"` |
| `width`, `height` | explicit paper size, as CSS lengths; override `format` |
| `landscape` | rotate the paper |
| `margin` | a `NamedTuple` or `Dict` of `top`/`bottom`/`left`/`right` |
| `print_background` | include background graphics, off by default upstream |
| `scale` | render scale, `0.1`–`2.0` |
| `page_ranges` | e.g. `"1-3, 8"` |
| `prefer_css_page_size` | let the page's own `@page` size win |
| `display_header_footer`, `header_template`, `footer_template` | running headers |
| `outline`, `tagged` | PDF outline and accessibility tags |

Options left unset are omitted from the protocol message entirely, so the
driver's own defaults apply.

!!! warning "Chromium only"
    `page.pdf` exists only on Chromium upstream. On any other engine this
    raises an `ArgumentError` naming the engine — decided **client-side** from
    [`browser_name`](@ref), so it costs no round trip and the message says what
    is actually wrong rather than surfacing a driver error about an unknown
    command.
"""
function pdf(
    page::Page;
    path::Union{AbstractString,Nothing} = nothing,
    format::Union{AbstractString,Nothing} = nothing,
    width::Union{AbstractString,Nothing} = nothing,
    height::Union{AbstractString,Nothing} = nothing,
    landscape::Union{Bool,Nothing} = nothing,
    margin = nothing,
    print_background::Union{Bool,Nothing} = nothing,
    scale::Union{Real,Nothing} = nothing,
    page_ranges::Union{AbstractString,Nothing} = nothing,
    prefer_css_page_size::Union{Bool,Nothing} = nothing,
    display_header_footer::Union{Bool,Nothing} = nothing,
    header_template::Union{AbstractString,Nothing} = nothing,
    footer_template::Union{AbstractString,Nothing} = nothing,
    outline::Union{Bool,Nothing} = nothing,
    tagged::Union{Bool,Nothing} = nothing,
)
    # D7: knowable without asking, so ask nobody.
    engine = browser_name(page)
    engine == "chromium" || throw(
        ArgumentError(
            "pdf() is supported on Chromium only, and this page is running on " *
            "$engine. Upstream `page.pdf` has no implementation on $engine; " *
            "capture a screenshot instead, or run this assertion on Chromium.",
        ),
    )

    bytes = _page_pdf(
        page;
        format,
        width,
        height,
        landscape,
        margin = margin === nothing ? nothing : as_object(margin),
        printBackground = print_background,
        scale,
        pageRanges = page_ranges,
        preferCSSPageSize = prefer_css_page_size,
        displayHeaderFooter = display_header_footer,
        headerTemplate = header_template,
        footerTemplate = footer_template,
        outline,
        tagged,
    )
    path === nothing || write(path, bytes)
    return bytes
end
