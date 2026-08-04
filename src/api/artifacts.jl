# Artifact capture: PDF, the Artifact wrapper, tracing and video.
#
# What a test suite needs when it goes red in CI and the assertion message is
# not enough — evidence of what the browser was actually doing. These are the
# outputs a caller can hand to somebody else: a zip for the upstream trace
# viewer, a video file, a PDF.
#
# Everything here writes only to a path the caller supplied. The package never
# chooses a location of its own.

# --- The Artifact surface (A4) --------------------------------------------
#
# A driver-side file that is still being written. Tracing and video both hand
# one back, and the same three verbs serve both.
#
# The distinction that makes this a wrapper rather than three field reads: the
# initializer's `absolutePath` says where the file *will* be, and is there
# before the file is. `pathAfterFinished` is the call that waits for it. Video
# in particular does not finish until the page closes (D6), so reading the
# initializer would hand back a path to a file that does not exist yet.

"""
    save_as(a::Artifact, path::AbstractString) -> path

Copy a driver-side artifact — a trace zip, a video — to `path`, **blocking
until it has finished being written**. Returns `path`, so it composes.

```julia
save_as(video(page), "artifacts/run.webm")
```

Parent directories are created if they do not exist, because the caller
supplying `"artifacts/run.webm"` on a fresh checkout means it.
"""
function save_as(a::Artifact, path::AbstractString)
    dir = dirname(path)
    isempty(dir) || mkpath(dir)
    _artifact_save_as(a; path)
    return path
end

"""
    path(a::Artifact) -> String

Where the artifact lives on disk, **blocking until it is completely written**.

This is not the same as the artifact's declared destination: the driver knows
the eventual path immediately, but the file only becomes complete later — for
video, not until the page or context closes (see [`video`](@ref)). Blocking
here is the point, and is what makes

```julia
close(page)
@test isfile(path(video(page)))
```

a test rather than a race.

The path is on the machine running the driver. That is this machine — the
driver is a child process (`SPEC-M4.md` assumption 7) — so the file is readable
from Julia directly. Use [`save_as`](@ref) to put a copy somewhere of your own
choosing instead.
"""
path(a::Artifact) = _artifact_path_after_finished(a)::String

"""
    delete(a::Artifact)

Delete the artifact's driver-side file. Worth calling for artifacts a passing
test does not need to keep — the driver writes them into a temporary directory
that lives as long as the browser does.
"""
function delete(a::Artifact)
    _artifact_delete(a)
    return nothing
end

# --- PDF (A3) --------------------------------------------------------------

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
