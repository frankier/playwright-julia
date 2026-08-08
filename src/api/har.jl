# HAR archives: replaying one (Part A) and recording one (Part B).
#
# Replay is not a mechanism of its own — there is no server-side "replay this
# archive" command. It is `harOpen` once, `harLookup` per request, `harClose` at
# the end, and the thing that produces the requests is M6's `route!` (D2). So
# everything here is a route handler and a lifetime, and `unroute!` is what owns
# the lifetime.
#
# Julia never reads a HAR's JSON. The driver parses the archive, resolves its
# redirect chains and guards its own cycles; this file translates four `action`
# values into three settle verbs.

"""
    route_from_har(target, har; url = nothing, not_found = :abort) -> RouteRegistration

Serve `target`'s matching requests from the HAR archive at `har`, so a page can
be driven with no backend running at all.

`target` is a [`Page`](@ref) or [`BrowserContext`](@ref); `har` is a path to a
`.har` or a `.har.zip`. `url` restricts which requests are served — a glob,
`Regex` or predicate, exactly as [`route!`](@ref) takes — and `nothing` serves
all of them.

A `.har.zip` — what Playwright writes when response bodies are attached rather
than embedded — is unzipped by the driver into a temp directory that goes away
with the registration. Your archive is copied, not consumed.

```julia
route_from_har(ctx, "test/fixtures/api.har"; url = "**/api/**")
goto!(page, "https://app.example.com")
```

`not_found` decides what happens to a request the archive has no entry for:
`:abort` (the default) fails it, `:fallback` lets it reach the real network.
The default is `:abort` on purpose (D4) — `:fallback` makes an incomplete
archive pass on a machine where the real server happens to be up, which is the
failure this feature exists to prevent. `:fallback` is offered anyway, because
"archive the API, let the CDN through" is a real configuration.

Returns the [`RouteRegistration`](@ref) that [`unroute!`](@ref) takes, which is
also what closes the archive. Prefer [`with_har`](@ref), which releases the
archive even when the body throws.
"""
function route_from_har(
    target::Union{Page,BrowserContext},
    har::AbstractString;
    url = nothing,
    not_found::Symbol = :abort,
    update::Bool = false,
)
    # `update = true` does not replay. It *records*, into the same file,
    # replacing it — the name says "route" and the behaviour is "trace", which
    # is confusing enough to be worth stating twice (D7). So it is Part B's
    # machinery under Part A's name, and it returns early: none of the replay
    # setup below applies to it.
    update && return record_into_har(target, har; url)

    not_found in (:abort, :fallback) || throw(
        ArgumentError(
            "not_found must be :abort or :fallback, got $(repr(not_found)). " *
            ":abort fails a request the archive has no entry for; :fallback " *
            "lets it reach the real network.",
        ),
    )

    utils = local_utils(target.connection)
    # Absolute, because the driver's working directory is not the caller's and a
    # relative path would resolve against the wrong one.
    archive = abspath(String(har))
    # Looking before asking: harOpen on a missing file raises the driver's
    # ENOENT, which does not name the archive in terms the caller recognises
    # (D5a).
    isfile(archive) ||
        throw(ArgumentError("no HAR archive at $(archive) — nothing to replay from"))

    opened, workdir = open_maybe_zipped(utils, archive)

    return route!(
        target,
        url === nothing ? "**/*" : url,
        route -> serve_from_har(route, utils, opened, archive, not_found);
        # harOpen is per-registration, not per-request: the driver parses the
        # archive once and hands back an id, and releasing it is unroute!'s job
        # (D3). For a .zip there is a second lifetime — the extraction — and it
        # is released here too, which is R5's "two lifetimes, one owner".
        release = () -> begin
            _local_utils_har_close(utils; harId = opened)
            workdir === nothing || rm(workdir; recursive = true, force = true)
        end,
    )
end

"""
    with_har(body, target, har; url = nothing, not_found = :abort)

Serve `target`'s matching requests from the archive at `har` for the duration of
`body`, then close the archive — even when `body` throws.

```julia
with_har(ctx, "test/fixtures/api.har"; url = "**/api/**") do
    goto!(page, "https://app.example.com")
    expect(locator(page, "#total"); to_have_text = "42")
end
```

The block form exists for the same reason [`with_route`](@ref)'s does: the
registration holds driver-side state — an open archive, and for a `.har.zip` a
temp directory — and a body that throws must not leak either. Keywords are
[`route_from_har`](@ref)'s.
"""
function with_har(
    body,
    target::Union{Page,BrowserContext},
    har::AbstractString;
    url = nothing,
    not_found::Symbol = :abort,
    update::Bool = false,
)
    reg = route_from_har(target, har; url, not_found, update)
    try
        return body()
    finally
        unroute!(target, reg)
    end
end

"""
Open `archive`, unzipping it first when it is one, and return
`(harId, workdir)`. `workdir` is `nothing` for a plain `.har` and the temp
directory to delete otherwise.

Playwright writes a `.har.zip` whenever `content = :attach`, because the
response bodies live beside the JSON as separate files.
`LocalUtils.harUnzip` is the driver's own extraction, which is how Assumption 11
can promise no new dependency: the alternative is a zip library in
`Project.toml` to reimplement a call the driver already exposes (D3).

Two things about `harUnzip` were found by probing rather than by reading, and
both are load-bearing:

  - **It deletes the zip it is given.** Replaying an archive must not consume
    it, so the caller's file is copied into the temp directory and the copy is
    what the driver eats.
  - **`resourcesDir` must be the directory holding the extracted `.har`.**
    `harLookup` resolves a content `_file` beside the `.har`; point the
    resources somewhere else and every body comes back as an `ENOENT` at lookup
    time, long after the call that got it wrong.

Whether it *is* a zip is decided by the file's first bytes, not by its name.
A `.har` that is really a zip is not hypothetical — it is what
`harExport(mode = "archive")` produces, and it is exactly the confusion T11 hit.
The extension is a guess; the content is the fact.
"""
function open_maybe_zipped(utils, archive::AbstractString)
    is_zip_file(archive) || return (open_archive(utils, archive), nothing)

    workdir = mktempdir(; prefix = "playwright-jl-har-")
    try
        zip_copy = joinpath(workdir, "archive.har.zip")
        cp(archive, zip_copy)
        har_file = joinpath(workdir, "har.har")
        _local_utils_har_unzip(
            utils;
            zipFile = zip_copy,
            harFile = har_file,
            resourcesDir = workdir,
        )
        return (open_archive(utils, har_file), workdir)
    catch
        # Nothing is registered yet, so nothing will ever release this.
        rm(workdir; recursive = true, force = true)
        rethrow()
    end
end

"""
Open `archive` in the driver and return its `harId`.

`harOpen` reports failure two ways and only one of them is declared: a broken
archive comes back in the `error` field, but a *missing* one raises. Both are
checked, because code that checks only the declared field never sees the common
failure (D5a).
"""
function open_archive(utils, archive::AbstractString)
    result = _local_utils_har_open(utils; file = archive)
    if result.error !== nothing
        throw(
            DriverError("$(result.error) (opening HAR archive $(archive))"; name = "Error"),
        )
    end
    result.harId === nothing && throw(
        DriverError(
            "harOpen returned neither a harId nor an error for HAR archive $(archive)";
            name = "Error",
        ),
    )
    return result.harId::String
end

"""
Answer one intercepted request from the archive.

The four `harLookup` actions map onto M6's three settle verbs (D2):

| `action` | Response |
|---|---|
| `fulfill` | [`fulfill!`](@ref) with the archived response |
| `redirect` | [`continue!`](@ref) at `redirectURL` — navigations only (D5) |
| `error` | a `DriverError`. The archive is broken, not the request |
| `noentry` | `not_found` decides (D4) |
"""
function serve_from_har(route::Route, utils, har_id, archive, not_found::Symbol)
    req = request(route)
    result = _local_utils_har_lookup(
        utils;
        harId = har_id,
        url = url(req),
        method = method(req),
        # Already the protocol's NameValue array — this is the one place the
        # initializer's shape is what the wire wants, so it goes out unchanged.
        headers = req.initializer["headers"],
        postData = post_data(req),
        isNavigationRequest = is_navigation_request(req),
    )

    action = result.action
    if action == "fulfill"
        fulfill!(
            route;
            status = result.status,
            headers = result.headers === nothing ? nothing :
                      Dict(name_value_pairs(result.headers)),
            body = result.body,
        )
    elseif action == "redirect"
        # One branch, no hop counter and no re-lookup (D5). For a sub-resource
        # the driver resolves the chain itself and answers `fulfill` with the
        # final response, so `redirect` only ever arrives for a navigation, and
        # what it asks for is that the navigation be re-issued at the new URL.
        # Cycles are the driver's problem and it already solves them — a guard
        # of ours would sit behind a working one and could only fire on input
        # that guard has already rejected.
        continue!(route; url = result.redirectURL)
    elseif action == "error"
        # The archive is broken, not the request. The driver's own words, which
        # for a cycle are better than any paraphrase of ours.
        throw(
            DriverError(
                "$(something(result.message, "HAR error")) " *
                "(replaying $(url(req)) from HAR archive $(archive))";
                name = "Error",
            ),
        )
    elseif action == "noentry"
        if not_found === :fallback
            # Asked for: "archive the API, let the CDN through". Not warned
            # about, or the warning below stops meaning anything.
            continue!(route)
        else
            # D5a: harOpen succeeds on a file that is not a HAR, so a typo'd or
            # truncated archive opens cleanly and then misses *everything*.
            # Under :abort that is a page whose every request fails with no clue
            # why. Naming both the URL and the archive is what makes "your HAR
            # is not a HAR" distinguishable from "your HAR lacks this entry".
            #
            # Per request, not per registration: each miss is a different URL,
            # and the list of them is the diagnosis.
            @warn "HAR archive has no entry for this request; aborting it. " *
                  "Pass not_found = :fallback to let unarchived requests reach " *
                  "the real network." url = url(req) archive = archive
            abort!(route)
        end
    else
        throw(
            DriverError(
                "unknown harLookup action $(repr(action)) for $(url(req)) " *
                "in HAR archive $(archive) — the protocol moved";
                name = "Error",
            ),
        )
    end
    return nothing
end

# --- Recording (Part B) -----------------------------------------------------
#
# D6: a start!/stop! pair, not a `new_context` keyword. There is no `recordHar`
# in `ContextOptions` — checked against mixins.yml:98 and browser.yml:62 — so
# other bindings' `record_har_path` is client-side sugar that calls `harStart`
# after the context exists. M8 declines the sugar, for three reasons in order of
# weight:
#
#   1. start_tracing!/stop_tracing! already made this decision in M4, for the
#      identical protocol shape: a Tracing command pair producing an Artifact.
#      A second feature on the same object with the opposite spelling would be
#      the package disagreeing with itself.
#   2. The keyword form hides where the file is written — `new_context(…;
#      record_har_path = p)` writes p at *context close*, somewhere else
#      entirely in the source. `stop_har_recording!` returns the path it wrote.
#   3. `new_context` already carries sixteen keywords and RecordHarOptions has
#      five more.

"""
    HarRecording

One live HAR recording, from [`start_har_recording!`](@ref). Hand it to
[`stop_har_recording!`](@ref), which needs nothing else — it holds the context
it was started on, so a recording cannot be stopped against the wrong one.
"""
struct HarRecording
    context::BrowserContext
    har_id::String
    path::String
end

const HAR_CONTENT_VALUES = (:embed, :attach, :omit)
const HAR_MODE_VALUES = (:full, :minimal)

"Validate a Symbol option into the wire's string enum, naming the valid set."
function har_enum(name::AbstractString, value::Symbol, allowed)
    value in allowed || throw(
        ArgumentError(
            "$name must be one of $(join(map(repr, allowed), ", ")), got $(repr(value))",
        ),
    )
    return String(value)
end

"""
    start_har_recording!(ctx; path, content = :embed, mode = :full, url = nothing)
        -> HarRecording

Begin recording `ctx`'s network into a HAR archive, to be written to `path` by
[`stop_har_recording!`](@ref).

```julia
rec = start_har_recording!(ctx; path = "api.har", url = "**/api/**")
goto!(page, url)
stop_har_recording!(rec)
```

Prefer [`with_har_recording`](@ref), which stops the recording even when the
body throws.

| Option | Meaning |
|---|---|
| `content` | `:embed` (bodies inline), `:attach` (bodies beside the JSON, so a `.har.zip`), `:omit` (no bodies) |
| `mode` | `:full`, or `:minimal` for just enough to replay |
| `url` | Record only matching requests — a glob string or a `Regex`; `nothing` records everything |

`content` and `mode` are `Symbol`s validated here into the wire's string enums,
so a typo is an `ArgumentError` naming the valid set rather than a driver error
much later.

Recording is a `start!`/`stop!` pair rather than a [`new_context`](@ref)
keyword (D6), matching [`start_tracing!`](@ref) — the same protocol shape, so
the same spelling. It also keeps the write visible: `stop_har_recording!`
returns the path it wrote, where a context-close keyword would write somewhere
else in the source entirely.
"""
function start_har_recording!(
    ctx::BrowserContext;
    path::AbstractString,
    content::Symbol = :embed,
    mode::Symbol = :full,
    url::Union{AbstractString,Regex,Nothing} = nothing,
)
    options = Dict{String,Any}(
        "content" => har_enum("content", content, HAR_CONTENT_VALUES),
        "mode" => har_enum("mode", mode, HAR_MODE_VALUES),
        "path" => String(path),
    )
    if url isa AbstractString
        options["urlGlob"] = String(url)
    elseif url isa Regex
        # The driver does its own matching, so a Regex crosses as source plus
        # flags rather than as anything Julia-shaped.
        options["urlRegexSource"] = url.pattern
        options["urlRegexFlags"] = regex_flag_string(url)
    end

    har_id = _tracing_har_start(tracing_channel(ctx); options)
    return HarRecording(ctx, har_id, String(path))
end

"The JS-style flag letters of a Regex, for the driver's own RegExp."
function regex_flag_string(re::Regex)
    flags = ""
    (re.compile_options & Base.PCRE.CASELESS) != 0 && (flags *= "i")
    (re.compile_options & Base.PCRE.MULTILINE) != 0 && (flags *= "m")
    (re.compile_options & Base.PCRE.DOTALL) != 0 && (flags *= "s")
    return flags
end

"""
    stop_har_recording!(rec::HarRecording) -> String

Stop `rec` and write its archive, returning the path it was written to.

```julia
path = stop_har_recording!(rec)
route_from_har(other_ctx, path)
```

`harExport` hands back an `Artifact`, exactly as tracing's stop does, so
[`save_as!`](@ref) is already the writer (D8) — including its guard: an export
that produced no artifact raises naming the path that was *not* written, rather
than returning quietly and leaving the caller to find an absent file later.

**`mode = "archive"` always produces a zip**, whatever `content` was — found by
T11, whose replay met `Unexpected token 'P', "PK  "... is not valid JSON`. So a
destination that is not a `.zip` gets the driver's own `harUnzip` on the way to
disk, writing the `.har` and putting any attached bodies beside it, which is
where [`route_from_har`](@ref) looks for them. Ask for a `.zip` path and you get
the archive as exported.
"""
function stop_har_recording!(rec::HarRecording)
    result = _tracing_har_export(
        tracing_channel(rec.context);
        harId = rec.har_id,
        mode = "archive",
    )
    artifact = result.artifact
    artifact === nothing && throw(
        DriverError(
            "the HAR recording stopped without producing an artifact, so there " *
            "is nothing to write to $(rec.path)";
            name = "Error",
        ),
    )

    if endswith(lowercase(rec.path), ".zip")
        save_as!(artifact; path = rec.path)
        return rec.path
    end

    # Not a .zip destination: unzip on the way out, so what lands at `path` is
    # a HAR rather than a zip wearing a .har name.
    staging = mktempdir(; prefix = "playwright-jl-har-export-")
    try
        zipped = joinpath(staging, "export.zip")
        save_as!(artifact; path = zipped)
        destination = dirname(abspath(rec.path))
        isempty(destination) || mkpath(destination)
        _local_utils_har_unzip(
            local_utils(rec.context.connection);
            zipFile = zipped,
            harFile = rec.path,
            # Beside the .har, not under it: harLookup resolves an attached body
            # relative to the archive (D3).
            resourcesDir = destination,
        )
    finally
        rm(staging; recursive = true, force = true)
    end
    return rec.path
end

"""
    with_har_recording(body, ctx; path, content = :embed, mode = :full, url = nothing)

Record `ctx`'s network around `body()` and write the archive to `path`,
returning whatever `body()` returned.

```julia
with_har_recording(ctx; path = "api.har", url = "**/api/**") do
    goto!(page, "https://app.example.com")
    click!(locator(page, "#refresh"))
end
```

The archive is written **however the block exits**, which is the same reason
[`with_tracing`](@ref) exists: a recording abandoned by an exception is a
recording of exactly the run you wanted to look at. Keywords are
[`start_har_recording!`](@ref)'s.
"""
function with_har_recording(
    body,
    ctx::BrowserContext;
    path::AbstractString,
    content::Symbol = :embed,
    mode::Symbol = :full,
    url::Union{AbstractString,Regex,Nothing} = nothing,
)
    rec = start_har_recording!(ctx; path, content, mode, url)
    try
        return body()
    finally
        stop_har_recording!(rec)
    end
end

"""
`route_from_har(…; update = true)`: a recording into the archive, wearing a
replay's name (D7).

Implemented on D6's machinery rather than on replay's, because that is what it
is — `harStart` scoped to the same `url` pattern, and an export written when the
registration is released. Two consequences worth stating rather than
discovering:

  - The returned `RouteRegistration` **intercepts nothing**. Recording happens
    driver-side, and putting a handler in front of the traffic would mean
    recording something round-tripped through Julia rather than the real
    exchange. That is what `route!`'s `intercepts = false` is for.
  - `unroute!` on it stops the recording and writes the file. There is no
    archive open, so there is nothing to `harClose`.

It needs a real backend to record from, which is the opposite of every other
`route_from_har` call — see the smoke tests, where the two do not share a
fixture.
"""
function record_into_har(target::Union{Page,BrowserContext}, har::AbstractString; url)
    # harStart is a Tracing command and Tracing hangs off the context, so a
    # page-scoped recording has nowhere to live. Named here rather than left to
    # surface as a MethodError from tracing_channel two frames down.
    target isa BrowserContext || throw(
        ArgumentError(
            "route_from_har(…; update = true) records, and recording is per " *
            "BrowserContext — pass the context rather than the Page.",
        ),
    )
    # Deliberately *not* the isfile check replay does: recording into a path is
    # how the first archive gets made.
    destination = abspath(String(har))
    matcher = url === nothing ? "**/*" : url
    rec = start_har_recording!(
        target;
        path = destination,
        url = url isa Union{AbstractString,Regex,Nothing} ? url : nothing,
    )
    return route!(
        target,
        matcher,
        _ -> error("an update-mode HAR registration should never be handed a route");
        release = () -> stop_har_recording!(rec),
        intercepts = false,
    )
end

"""
Whether `path` begins with the local-file-header magic of a zip, `PK\\x03\\x04`.

By content rather than by extension, because both directions of this feature
produce a zip under a `.har` name if you let them, and a misjudged extension
surfaces as `Unexpected token 'P', "PK…" is not valid JSON` from inside the
driver's JSON parser.
"""
function is_zip_file(path::AbstractString)
    isfile(path) || return false
    return open(path, "r") do io
        read(io, 4) == UInt8[0x50, 0x4b, 0x03, 0x04]
    end
end
