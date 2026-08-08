# HAR: recording and replaying the network

A HAR archive is a recording of everything a page asked for and everything it
got back. Playwright.jl can write one and serve a later run from it, which
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

The two halves are independent — an archive recorded by any Playwright can be
replayed here, and one recorded here can be replayed by `playwright-python` —
so it is worth knowing which half you are in when something goes wrong.

## Replaying

[`route_from_har`](@ref) registers a [`route!`](@ref) handler that answers from
the archive. That is not an implementation detail you can ignore: what it
returns is a [`RouteRegistration`](@ref), and [`unroute!`](@ref) is what closes
the archive and releases the temporary directory a `.zip` was unpacked into.

```julia
reg = route_from_har(ctx, "api.har"; url = "**/api/**")
# ...
unroute!(ctx, reg)
```

Prefer [`with_har`](@ref), which does the second line for you even when the
body throws.

### `url` decides what the archive is responsible for

Without `url`, every request goes to the archive — including the document
itself, which is what you want for a page that has to render with the server
switched off. With `url`, only matching requests are looked up and everything
else goes to the network as usual, which is what you want when the archive is
standing in for one API and the rest of the site is live.

The matcher is the same vocabulary [`route!`](@ref) takes: a glob string, a
`Regex`, or a predicate.

### `not_found` decides what a miss means

| `not_found` | A request the archive does not have |
|---|---|
| `:abort` (default) | fails, and a warning names the URL and the archive |
| `:fallback` | reaches the real network |

The default is `:abort` because the alternative is worse: a test that quietly
reaches a live backend for the one request the archive was missing passes for
the wrong reason and fails on the CI runner with no network.

!!! warning "A file that is not a HAR opens successfully"
    The driver does not validate the archive when it opens it, so a typo'd,
    truncated or half-written file opens cleanly and then misses *every*
    lookup. Under `:abort` that presents as a page whose every request fails
    for no visible reason — which is why the warning names the archive as well
    as the URL. If every request is missing, suspect the file before the
    matcher.

### Redirects and broken archives

A redirect chain recorded in the archive is followed by the driver itself,
including its own cycle detection; a sub-resource redirect never reaches your
code. A genuinely broken archive — a redirect cycle, say — raises a
[`DriverError`](@ref) carrying the driver's own message rather than a
paraphrase of it.

### `.har.zip`

An archive recorded with `content = :attach` is a `.zip`: the HAR plus the
response bodies as separate files. Pass the `.zip` path and it is unpacked into
a temporary directory for you. That directory belongs to the registration —
`unroute!` removes it — so a replay does not leave one behind per run.

## Recording

[`start_har_recording!`](@ref) and [`stop_har_recording!`](@ref) are a pair,
matching [`start_tracing!`](@ref) rather than being a
[`new_context`](@ref) keyword, because that is the shape the protocol has.
[`with_har_recording`](@ref) is the block form and stops the recording even
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

Both are `Symbol`s and both are validated before anything reaches the wire, so
a typo is an `ArgumentError` naming the accepted values rather than a driver
error later.

The archive is written when the recording stops. If the driver produces no
artifact — nothing was captured — you get a [`DriverError`](@ref) naming the
path that was *not* written, rather than a missing file discovered by whatever
reads it next.

## Refreshing an archive

`update = true` on [`route_from_har`](@ref) inverts the direction: matching
requests go to the real network and the archive is rewritten with what comes
back, when the registration is released.

```julia
# The server is up; the archive is brought up to date.
with_har(ctx, "api.har"; url = "**/api/**", update = true) do
    goto!(page, url)
    click!(locator(page, "#load"))
end
```

This is how an archive stops being a lie about an API that has moved on: run
the same test with `update = true` against a live backend, commit the diff, and
go back to replaying.

## Which half is wrong?

When a replay does not do what the recording did, the useful first question is
whether the archive contains what you think.

- **Every request misses.** Suspect the file, not the matcher — see the warning
  above.
- **The document loads but the API does not.** The `url` matcher on the replay
  is narrower than the one on the recording, or the URLs differ by a query
  string the glob does not cover.
- **The replay reaches the network.** `not_found = :fallback` is doing exactly
  what it says. Switch to `:abort` while diagnosing, so a miss is loud.

A HAR is a text file (or a zip containing one). Reading it is allowed, and is
usually faster than guessing.
