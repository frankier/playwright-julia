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
`.har`. `url` restricts which requests are served — a glob, `Regex` or
predicate, exactly as [`route!`](@ref) takes — and `nothing` serves all of them.

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

    har_id = open_archive(utils, archive)

    return route!(
        target,
        url === nothing ? "**/*" : url,
        route -> serve_from_har(route, utils, har_id, archive, not_found);
        # harOpen is per-registration, not per-request: the driver parses the
        # archive once and hands back an id, and releasing it is unroute!'s job
        # (D3).
        release = () -> _local_utils_har_close(utils; harId = har_id),
    )
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
    elseif action == "noentry"
        not_found === :fallback ? continue!(route) : abort!(route)
    else
        # redirect and error arrive in T5; anything else is the driver telling
        # us the protocol moved.
        throw(
            DriverError(
                "unhandled harLookup action $(repr(action)) for $(url(req)) " *
                "in HAR archive $(archive)";
                name = "Error",
            ),
        )
    end
    return nothing
end
