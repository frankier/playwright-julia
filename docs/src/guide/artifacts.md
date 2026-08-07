# Artifacts

What to reach for when a suite goes red in CI and the assertion message is not
enough.

The problem this solves is specific: the run that failed happened on a machine
you cannot see, in a browser that no longer exists, and it will probably pass
when you run it again. Evidence has to be collected *at the time*, by the
failing run itself.

| Call | Produces |
|---|---|
| [`with_page`](@ref) | all of the below, on failure |
| [`with_tracing`](@ref) | a trace zip, written however the block exits |
| [`start_tracing!`](@ref) / [`stop_tracing!`](@ref) | the same, unpaired |
| [`screenshot`](@ref) | PNG bytes, and a file if you pass `path` |
| [`video`](@ref) | a `.webm` per page, with `record_video` on the context |
| [`pdf`](@ref) | PDF bytes — **Chromium only** |
| [`report_diagnostics`](@ref) | `screenshot.png`, `console.log`, `errors.log` |

## The fixture

[`with_page`](@ref) is the per-test form, and the one to start with:

```julia
with_page(browser, url; artifacts = "artifacts/checkout") do page
    expect(page; to_have_title = "Checkout")
    click!(locator(page, "#submit"))
    expect(locator(page, "#receipt"); to_be_visible = true)
end
```

It opens a page, navigates, always closes it, and — when the body throws —
dumps diagnostics **before** closing, because afterwards there is nothing left
to look at.

**Your exception propagates unchanged.** A failure while collecting the
evidence is a `@warn`, never a replacement for the failure being diagnosed. A
helper that adds evidence must not destroy the thing it was called to explain.

`artifacts_on = :always` captures on success too; the default `:failure` keeps
a large suite from writing a screenshot per passing test.

## Tracing

A trace is the full record of what the browser did — actions, DOM snapshots
before and after each one, console output, network — viewable afterwards in
Playwright's own viewer.

```julia
with_tracing(ctx; path = "artifacts/trace.zip", screenshots = true) do
    goto!(page, url)
    click!(locator(page, "#submit"))     # if this throws, the zip is still written
end
```

"However the block exits" is the point: the run worth tracing is the one that
threw.

Open the result with the upstream viewer. This package neither builds nor
parses a trace — the zip is assembled by the driver and is an opaque artifact
for the viewer:

```console
$ npx playwright@1.61.1 show-trace artifacts/trace.zip
```

The unpaired form is [`start_tracing!`](@ref) and [`stop_tracing!`](@ref). Each
stop consumes the chunk the start opened, so tracing a second run means
starting again.

!!! note "`sources = true` is not available"
    Upstream clients embed calling source files by passing `includeSources`
    when they assemble the zip themselves. This package lets the driver
    assemble it, and the driver's `tracingStart` carries no `sources` flag.
    Passing `sources = true` raises rather than being silently dropped — a flag
    that quietly does nothing is worse than one that is not offered.

## Video

Video is recorded per page, and switched on at the **context**:

```julia
ctx = new_context(browser; record_video = (dir = "artifacts/video",))
page = new_page(ctx)
goto!(page, url)
```

!!! warning "The video does not exist until the page closes"
    The driver knows the eventual path immediately, but the file is not
    finished until its page or context closes. [`path`](@ref) is what waits:

    ```julia
    recording = video(page)
    close!(page)
    @test isfile(path(recording))
    ```

## Screenshots and PDFs

The artifact family follows one rule: **if you name a destination you get the
destination back; if you want bytes you call the function that says bytes.**

```julia
screenshot(page; path = "artifacts/checkout.png")   # -> the path
bytes = screenshot_bytes(page)                      # -> Vector{UInt8}
```

[`screenshot`](@ref) requires `path` and returns it;
[`screenshot_bytes`](@ref) touches no filesystem, so a screenshot can still be
attached to a report without writing one. Splitting them keeps both
type-stable — the alternative, returning `Union{String,Vector{UInt8}}`
depending on whether a keyword was passed, is not.

[`pdf`](@ref) and [`pdf_bytes`](@ref) are the same shape, and both are
**Chromium only** — off Chromium they raise an `ArgumentError` naming the
engine, decided client-side with no round trip.

## Diagnostics

[`report_diagnostics`](@ref) writes the three things you want at once —
`screenshot.png`, `console.log` and `errors.log`:

```julia
try
    click!(locator(page, "#submit"))
catch
    report_diagnostics(page, "artifacts/failure")
    rethrow()
end
```

It is what `with_page` calls for you.

## The `Artifact` type

Traces and videos come back as an [`Artifact`](@ref) — a file the driver is
producing. Three verbs:

| Call | Does |
|---|---|
| [`path`](@ref) | blocks until it is completely written, returns where it is |
| [`save_as!`](@ref) | copies it somewhere of your choosing, creating directories |
| [`delete_file!`](@ref) | removes the driver's copy |

```julia
recording = video(page)
close!(page)
if test_passed
    delete_file!(recording)                          # nothing to look at
else
    save_as!(recording, "artifacts/run.webm")   # your copy; delete_file! cannot touch it
end
```

The driver writes these into a temporary directory that lives as long as the
browser, so a passing test that keeps everything is a slow leak.

## Keep them out of git

Traces, videos, screenshots and PDFs are binaries, regenerated on every run.
Add the directory you write them to your `.gitignore` — this repository ignores
`artifacts/`.
