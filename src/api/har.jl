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
also what closes the archive.
"""
function route_from_har(
    target::Union{Page,BrowserContext},
    har::AbstractString;
    url = nothing,
    not_found::Symbol = :abort,
)
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
"""
function open_maybe_zipped(utils, archive::AbstractString)
    endswith(lowercase(archive), ".zip") || return (open_archive(utils, archive), nothing)

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
