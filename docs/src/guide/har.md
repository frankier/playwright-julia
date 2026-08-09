# HAR: recording and replaying the network

A HAR archive is a recording of everything a page asked for and everything it
got back. Playwright.jl can write one, then serve a later run from it. That
gives a test the thing that is otherwise hardest to arrange: a real backend's
answers, with no backend running.

```julia
# Record once, with the server up.
with_har_recording(ctx; path = "api.har") do
    goto!(page, "http://localhost:8000/app")
    click!(locator(page, "#load"))
end

# Replay for ever after, with the server down.
with_har(ctx, "api.har") do
    goto!(page, "http://localhost:8000/app")
    expect(locator(page, "li"; strict = false); to_have_count = 2)
end
```

The two halves are independent. This package replays an archive from any
Playwright client, and `playwright-python` replays one written here. So when
something goes wrong, work out which half you are in.

## Replaying

[`route_from_har`](@ref) registers a [`route!`](@ref) handler that answers from
the archive. Do not treat that as an implementation detail. It returns a
[`RouteRegistration`](@ref), and [`unroute!`](@ref) is what closes the archive and
removes the temporary directory that held an unpacked `.zip`.

```julia
reg = route_from_har(ctx, "api.har"; url = "**/api/**")
# ...
unroute!(ctx, reg)
```

Prefer [`with_har`](@ref), which does the second line for you even when the
body throws.

### `url` decides what the archive is responsible for

Without `url`, every request goes to the archive, the document included. Use that
for a page that has to render with the server switched off.

With `url`, the archive answers only matching requests and everything else
reaches the network as usual. Use that when the archive stands in for one API and
the rest of the site is live.

The matcher is the same vocabulary [`route!`](@ref) takes: a glob string, a
`Regex`, or a predicate.

### `not_found` decides what a miss means

| `not_found` | A request the archive does not have |
|---|---|
| `:abort` (default) | fails, and a warning names the URL and the archive |
| `:fallback` | reaches the real network |

The default is `:abort` because the alternative is worse. A test that quietly
reaches a live backend for the one request the archive lacked passes for the
wrong reason, then fails on a CI runner with no network.

!!! warning "A file that is not a HAR opens successfully"
    The driver does not check the archive when it opens it, so a typo'd,
    truncated or half-written file opens cleanly and then misses *every* lookup.
    Under `:abort` that looks like a page whose every request fails for no
    visible reason. That is why the warning names the archive as well as the URL.
    If every request misses, suspect the file before the matcher.

### Redirects and broken archives

The driver follows a recorded redirect chain itself, and detects its own cycles.
A sub-resource redirect never reaches your code. A genuinely broken archive — a
redirect cycle, say — raises a [`DriverError`](@ref) carrying the driver's own
message rather than a paraphrase of it.

### `.har.zip`

An archive recorded with `content = :attach` is a `.zip`: the HAR plus the
response bodies as separate files. Pass the `.zip` path, and the driver unpacks
it into a temporary directory. That directory belongs to the registration, and
`unroute!` removes it, so a replay leaves nothing behind.

## Recording

[`start_har_recording!`](@ref) and [`stop_har_recording!`](@ref) are a pair, and
they match [`start_tracing!`](@ref) rather than taking a [`new_context`](@ref)
keyword, because that is the shape the protocol has.
[`with_har_recording`](@ref) is the block form, and it stops the recording even
when the body throws.

```julia
with_har_recording(ctx; path = "api.har", url = "**/api/**") do
    goto!(page, url)
    click!(locator(page, "#load"))
end
```

Two keywords are worth knowing:

| Keyword | Values | What it changes |
|---|---|---|
| `content` | `:embed`, `:attach`, `:omit` | whether bodies are inline, in a `.zip` beside the HAR, or dropped |
| `mode` | `:full`, `:minimal` | whether timings, sizes and headers are recorded or only what replay needs |

Both are `Symbol`s, and this package checks both before anything reaches the
wire. A typo raises an `ArgumentError` naming the accepted values, rather than a
driver error later.

Stopping the recording writes the archive. If the driver captured nothing it
produces no artifact, and you get a [`DriverError`](@ref) naming the path it did
*not* write — rather than a missing file that surfaces later.

## Refreshing an archive

`update = true` on [`route_from_har`](@ref) reverses the direction. Matching
requests reach the real network, and releasing the registration rewrites the
archive with what came back.

```julia
# The server is up; the archive is brought up to date.
with_har(ctx, "api.har"; url = "**/api/**", update = true) do
    goto!(page, url)
    click!(locator(page, "#load"))
end
```

This is how an archive stops being a lie about an API that has moved on. Run the
same test with `update = true` against a live backend, commit the diff, then go
back to replaying.

## Which half is wrong?

When a replay does not do what the recording did, the useful first question is
whether the archive contains what you think.

- **Every request misses.** Suspect the file, not the matcher — see the warning
  above.
- **The document loads but the API does not.** Either the replay's `url` matcher
  is narrower than the recording's, or the URLs differ by a query string the glob
  does not cover.
- **The replay reaches the network.** `not_found = :fallback` is doing exactly
  what it says. Switch to `:abort` while diagnosing, so a miss is loud.

A HAR is a text file, or a zip containing one. Read it. That is usually faster
than guessing.
