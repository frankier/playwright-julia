# Artifacts

What to reach for when a suite goes red in CI and the assertion message is not
enough.

The problem is specific. The run that failed happened on a machine you cannot
see, in a browser that no longer exists, and it will probably pass when you run
it again. So the failing run has to collect its own evidence, *at the time*.

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

It opens a page, navigates, and always closes the page. When the body throws it
dumps diagnostics **before** closing, because afterwards there is nothing left to
look at.

**Your exception propagates unchanged.** If collecting the evidence fails, you
get a `@warn` rather than a second exception. A helper that adds evidence must
not destroy the thing it was called to explain.

`artifacts_on = :always` captures on success too. The default `:failure` stops a
large suite writing a screenshot per passing test.

## Tracing

A trace is the full record of what the browser did: actions, DOM snapshots
before and after each one, console output and network. Playwright's own viewer
reads it.

```julia
with_tracing(ctx; path = "artifacts/trace.zip", screenshots = true) do
    goto!(page, url)
    click!(locator(page, "#submit"))     # if this throws, the zip is still written
end
```

"However the block exits" is the point: the run worth tracing is the one that
threw.

Open the result with the upstream viewer. This package neither builds nor parses
a trace. The driver assembles the zip, and it stays opaque to Julia:

```console
$ npx playwright@1.61.1 show-trace artifacts/trace.zip
```

The unpaired form is [`start_tracing!`](@ref) and [`stop_tracing!`](@ref). Each
stop consumes the chunk the start opened, so tracing a second run means
starting again.

!!! note "`sources` is not accepted"
    `playwright-python` takes it, so a reader coming from there will look for
    it. Upstream clients embed calling source files by passing `includeSources`
    when they assemble the zip themselves. This package lets the driver assemble
    it, and the driver's `tracingStart` carries no `sources` flag.

    The keyword is not in the signature, so `sources = true` raises a
    `MethodError`.

## Video

The driver records one video per page, and you switch it on at the **context**:

```julia
ctx = new_context(browser; record_video = (dir = "artifacts/video",))
page = new_page(ctx)
goto!(page, url)
```

!!! warning "The video does not exist until the page closes"
    The driver knows the eventual path immediately, but the file is not complete
    until its page or context closes. [`path`](@ref) is the call that waits:

    ```julia
    recording = video(page)
    close!(page)
    @test isfile(path(recording))
    ```

## Screenshots and PDFs

The artifact family follows one rule. **Name a destination and you get the
destination back. Want bytes, and you call the function that says bytes.**

```julia
screenshot(page; path = "artifacts/checkout.png")   # -> the path
bytes = screenshot_bytes(page)                      # -> Vector{UInt8}
```

[`screenshot`](@ref) requires `path` and returns it. [`screenshot_bytes`](@ref)
touches no filesystem, so you can attach a screenshot to a report without
writing a file. Two functions rather than one keeps both type-stable, which a
single function returning `Union{String,Vector{UInt8}}` would not.

[`pdf`](@ref) and [`pdf_bytes`](@ref) have the same shape, and both are
**Chromium only**. On any other engine they raise an `ArgumentError` naming the
engine, decided client-side with no round trip.

## Diagnostics

[`report_diagnostics`](@ref) writes three files at once: `screenshot.png`,
`console.log` and `errors.log`.

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

Traces and videos come back as an [`Artifact`](@ref), a file the driver is still
writing. Three verbs:

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
    save_as!(recording; path = "artifacts/run.webm")   # your copy; delete_file! cannot touch it
end
```

The driver writes these into a temporary directory that lives as long as the
browser, so a passing test that keeps everything is a slow leak.

## Keep them out of git

Traces, videos, screenshots and PDFs are binaries, regenerated on every run.
Add the directory you write them to your `.gitignore`. This repository ignores
`artifacts/`.
