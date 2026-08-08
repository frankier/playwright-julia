# Downloads (SPEC-M7.md D10, D11).
#
# A `download` event carries three things — a url, a suggested filename and an
# Artifact — and only the artifact survives if the event yields a bare
# Artifact. `suggestedFilename` is the single most-used download field: it is
# what the server named the file, and nothing else on the wire knows it.
#
# Everything here is shaped by the probe (tasks/m7-probe.md), which found two
# things that are not guessable:
#
#   * a download refused by `accept_downloads = false` STILL delivers the
#     event, with a correct url and suggested filename. The refusal surfaces
#     only when the artifact is asked for something.
#   * `acceptDownloads = "internal-browser-default"` emits no event at all, so
#     `nothing` on the Julia side must OMIT the parameter rather than map to
#     that value. Getting this wrong costs a silent timeout.

"""
    Download

A file the page downloaded. Wraps the [`Artifact`](@ref) the driver produced,
plus the two things the event knows and the artifact does not: where it came
from and what the server called it.

```julia
dl = expect_download(page) do
    click!(locator(page, "#report"))
end
suggested_filename(dl)                       # "report-2026.csv"
save_as!(dl; path = "artifacts/report.csv")
```

| Call | Answers |
|---|---|
| [`url`](@ref) | where it was downloaded from |
| [`suggested_filename`](@ref) | what the server named it |
| [`path`](@ref) | where it is on disk, **blocking** until complete |
| [`save_as!`](@ref) | copy it somewhere of your choosing |
| [`delete_file!`](@ref) | drop the driver's copy |
| [`cancel!`](@ref) | abandon a download in progress |
| [`failure`](@ref) | `nothing`, or why it failed |
| [`artifact`](@ref) | the underlying `Artifact`, for anything not covered |

!!! warning "`failure` is the only non-throwing success check"
    A download the browser refused still arrives as a `Download` with a
    correct `url` and `suggested_filename` — the refusal is not visible until
    you ask for the file. [`path`](@ref) and [`save_as!`](@ref) **raise** a
    [`DriverError`](@ref) on a failed download; only [`failure`](@ref) answers
    without throwing.

    So `isnothing(path(dl))` is not the way to ask whether a download
    succeeded — it raises instead of returning `nothing`, and nothing in the
    name warns you. `isnothing(failure(dl))` is.
"""
struct Download
    artifact::Artifact
    url::String
    suggested_filename::String
    page::Page
end

"""
    suggested_filename(dl::Download) -> String

The filename the server suggested, from `Content-Disposition` or the URL. This
is what a browser would have called the file, and it lives only on the download
event — the [`Artifact`](@ref) underneath does not know it.
"""
suggested_filename(dl::Download) = dl.suggested_filename

"""
    artifact(dl::Download) -> Artifact

The [`Artifact`](@ref) underneath a download.

The escape hatch: anything `Download` does not wrap stays reachable through it,
so the wrapper is non-lossy by construction rather than by promise.
"""
artifact(dl::Download) = dl.artifact

"The page the download came from."
page(dl::Download) = dl.page

url(dl::Download) = dl.url

# The three artifact verbs, forwarded. D6 landed first precisely so `path` is
# already a keyword here rather than becoming one later.
path(dl::Download) = path(dl.artifact)
save_as!(dl::Download; path::AbstractString) = save_as!(dl.artifact; path)
delete_file!(dl::Download) = delete_file!(dl.artifact)

"""
    cancel!(dl::Download)

Abandon a download that is still in progress. A download that has already
finished is unaffected, and cancelling twice is not an error.

After cancelling, [`failure`](@ref) reports the cancellation rather than
`nothing`.
"""
function cancel!(dl::Download)
    _artifact_cancel(dl.artifact)
    return nothing
end

"""
    failure(dl::Download) -> Union{String,Nothing}

Why the download failed, or `nothing` if it succeeded.

**This is the only way to ask that does not throw.** A download refused by
`accept_downloads = false` still arrives as a perfectly ordinary `Download`;
the refusal appears here, as the driver's own sentence, while [`path`](@ref)
and [`save_as!`](@ref) raise a [`DriverError`](@ref) carrying the same text.

```julia
dl = expect_download(page) do
    click!(locator(page, "#report"))
end
if isnothing(failure(dl))
    save_as!(dl; path = "artifacts/report.csv")
else
    @warn "download refused" reason = failure(dl)
end
```

Blocks until the download has finished one way or the other.
"""
failure(dl::Download) = _artifact_failure(dl.artifact)

# The event payload. `page` comes from the owner rather than the params: the
# download event is declared on Page, so the owner *is* the page.
function download_payload(owner, params)
    art = from_channel(owner.connection, params["artifact"])::Artifact
    return Download(
        art,
        String(get(params, "url", "")),
        String(get(params, "suggestedFilename", "")),
        owner::Page,
    )
end

"""
    expect_download(f, page::Page; timeout=nothing) -> Download

Run `f()` and return the first download `page` starts.

The subscription is attached before `f` runs, so a download triggered
immediately is still caught.

```julia
dl = expect_download(page) do
    click!(locator(page, "#export"))
end
save_as!(dl; path = joinpath(dir, suggested_filename(dl)))
```

`timeout` is in milliseconds and defaults to the
[`set_default_timeout!`](@ref) cascade; [`TimeoutError`](@ref) is raised if no
download starts.

!!! note "A refused download is still a download"
    This returns normally even when the browser refused the download — see
    [`failure`](@ref). It raises only when *no* download event arrives at all.
"""
expect_download(f::Function, page::Page; timeout = nothing) =
    expect_event(f, page, :download; timeout)

# --- accept_downloads (D10, probed) -----------------------------------------

"""
Map the Julia `accept_downloads` keyword onto the protocol's enum.

`nothing` omits the parameter, and that is load-bearing rather than tidy. The
enum's third value, `"internal-browser-default"`, hands the download to the
browser's own machinery and Playwright then emits **no event at all** — the
page appears to do nothing and the caller waits out a full timeout with no
diagnostic. It is the value a "default" keyword is most likely to be mapped
onto by someone being helpful, so the mapping refuses to produce it.

Omitting the parameter already means accept. On both engines, an unset
`acceptDownloads` downloads normally.
"""
accept_downloads_option(::Nothing) = nothing
accept_downloads_option(accept::Bool) = accept ? "accept" : "deny"
