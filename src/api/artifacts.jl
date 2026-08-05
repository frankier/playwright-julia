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

The blocking is the useful part: [`path`](@ref) tells you where the driver
*will* put the file, but a video is not finished until its page closes. Use
[`delete`](@ref) for an artifact a passing test does not need to keep, and see
[`Artifact`](@ref) for the three verbs together.
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

```julia
recording = video(page)
close(page)
if test_passed
    delete(recording)                       # nothing to look at
else
    save_as(recording, "artifacts/run.webm")
end
```

This deletes the *driver's* copy; a file already copied out with
[`save_as`](@ref) is yours and is untouched. See [`Artifact`](@ref).
"""
function delete(a::Artifact)
    _artifact_delete(a)
    return nothing
end

# --- Tracing (A1, D1) ------------------------------------------------------
#
# The stop path is not a guess. Probed against the live 1.61.1 driver before
# any of this was written (T1, tasks/m4-probe.md): `tracingStopChunk` with
# mode="archive" returns a real Artifact whose `saveAs` writes a valid zip, on
# Chromium and Firefox alike, with or without `tracesDir` set at launch. The
# alternative the protocol also offers — mode="entries" plus `localUtils.zip`
# — is therefore not needed, and neither is a Julia zip dependency.

"The context's Tracing channel, which lives in its initializer, not a command."
tracing_channel(ctx::BrowserContext) =
    from_channel(ctx.connection, ctx.initializer["tracing"])::Tracing

"""
    start_tracing(ctx::BrowserContext; screenshots=true, snapshots=true,
                  sources=false, name=nothing, title=nothing)

Begin recording a Playwright trace on `ctx` — the full record of what the
browser did, viewable afterwards in Playwright's own trace viewer. Pair with
[`stop_tracing`](@ref), or use [`with_tracing`](@ref) to guarantee the pairing
even when the block throws, which is the run worth tracing.

```julia
start_tracing(ctx; title = "checkout")
try
    goto(page, url)
    click(locator(page, "#submit"))
finally
    stop_tracing(ctx; path = "artifacts/trace.zip")
end
```

| Option | Records |
|---|---|
| `screenshots` | a screencast, so the trace viewer has a filmstrip |
| `snapshots` | DOM snapshots, so actions can be inspected before/after |
| `name`, `title` | naming for the trace and the chunk |

Two protocol calls, not one: the recording is configured, then a *chunk* is
opened. `stop_tracing` closes the chunk, and a stop with no chunk open has
nothing to archive.

!!! note "`sources` is not available on this path"
    Upstream clients embed calling source files by passing `includeSources` to
    `localUtils.zip`, which they use because they assemble the zip themselves.
    This package lets the driver assemble it (`tracingStopChunk(mode="archive")`
    — see D1), and the 1.61.1 `tracingStart` protocol carries no `sources`
    flag. Passing `sources = true` therefore raises an `ArgumentError` rather
    than being silently dropped: a flag that quietly does nothing is worse than
    one that is not offered.
"""
function start_tracing(
    ctx::BrowserContext;
    screenshots::Bool = true,
    snapshots::Bool = true,
    sources::Bool = false,
    name::Union{AbstractString,Nothing} = nothing,
    title::Union{AbstractString,Nothing} = nothing,
)
    sources && throw(
        ArgumentError(
            "`sources = true` is not supported: Playwright 1.61.1's " *
            "tracingStart has no sources flag, and this package lets the " *
            "driver assemble the zip rather than calling localUtils.zip " *
            "with includeSources. Omit it, or open the trace without sources.",
        ),
    )
    tracing = tracing_channel(ctx)
    _tracing_tracing_start(tracing; screenshots, snapshots, name)
    _tracing_tracing_start_chunk(tracing; name, title)
    return nothing
end

"""
    stop_tracing(ctx::BrowserContext; path) -> path

Stop the recording started by [`start_tracing`](@ref) and write the trace zip
to `path`, returning `path`. Parent directories are created as needed.

```julia
start_tracing(ctx)
goto(page, url)
stop_tracing(ctx; path = "artifacts/trace.zip")
```

Each stop consumes the chunk `start_tracing` opened, so tracing a second run
means calling `start_tracing` again. [`with_tracing`](@ref) does both halves
for you. Open the result with:

```
npx playwright@1.61.1 show-trace artifacts/trace.zip
```

The zip is assembled by the driver, not by Julia — this package has no zip
dependency and does not parse the trace. It is an opaque artifact for the
upstream viewer.
"""
function stop_tracing(ctx::BrowserContext; path::AbstractString)
    tracing = tracing_channel(ctx)
    result = _tracing_tracing_stop_chunk(tracing; mode = "archive")
    artifact = result.artifact
    artifact === nothing && throw(
        DriverError(
            "tracing stopped without producing an artifact, so there is " *
            "nothing to write to $path";
            name = "Error",
        ),
    )
    save_as(artifact, path)
    _tracing_tracing_stop(tracing)
    return path
end

"""
    with_tracing(f, ctx::BrowserContext; path, screenshots=true, snapshots=true,
                 sources=false, name=nothing, title=nothing)

Record a Playwright trace around `f()` and write it to `path`.

The zip is written **however the block exits** — that is the point, since the
run worth tracing is the one that threw:

```julia
with_tracing(ctx; path = "artifacts/trace.zip") do
    goto(page, url)
    click(locator(page, "#submit"))
end
```

Returns whatever `f()` returned. Open the trace with
`npx playwright show-trace artifacts/trace.zip`.

Options other than `path` are passed straight to [`start_tracing`](@ref); the
zip is written by [`stop_tracing`](@ref). For a whole test wrapped in a trace
*and* a screenshot on failure, see [`with_page`](@ref).

!!! note "A failed save never replaces your exception"
    Saving the trace happens on the teardown path, while a more important
    error may already be in flight. If it fails it is reported with `@warn`
    and the block's own exception — or its return value — is what reaches the
    caller. A helper that adds evidence must never destroy the thing it was
    called to explain.
"""
function with_tracing(f, ctx::BrowserContext; path::AbstractString, kw...)
    start_tracing(ctx; kw...)
    try
        return f()
    finally
        # Teardown: a failure to save the trace must not replace the caller's
        # exception with a less interesting one.
        try
            stop_tracing(ctx; path)
        catch e
            @warn "could not save trace" path exception = e
        end
    end
end

# --- Video (A2, D6) --------------------------------------------------------

"""
    video(page::Page) -> Union{Artifact,Nothing}

The video being recorded for `page`, or `nothing` if its context was not
created with `record_video`.

Recording is switched on per **context**, not per page, because that is what
the protocol offers:

```julia
ctx = new_context(browser; record_video = (dir = "artifacts/video",))
page = new_page(ctx)
goto(page, url)

close(page)                          # ...the file is finished by this
@test isfile(path(video(page)))
```

!!! warning "The file does not exist until the page or context closes"
    This is an upstream sharp edge, not a Playwright.jl one. The video is
    still being written while the page is open, so `path(video(page))` called
    too early **blocks** until the recording is finalized — and a naive test
    that asserts `isfile` before closing sees nothing and looks like a bug in
    this package. Close the page first, as above.

The result is an ordinary [`Artifact`](@ref), so [`path`](@ref),
[`save_as`](@ref) and [`delete`](@ref) all work on it — `save_as` being the way
to move it somewhere of your choosing rather than the driver's temporary
directory.
"""
function video(page::Page)
    raw = get(page.initializer, "video", nothing)
    raw === nothing && return nothing
    return from_channel(page.connection, raw)::Artifact
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
