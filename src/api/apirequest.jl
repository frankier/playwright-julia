# APIRequestContext, exactly as far as fulfil-from-upstream needs.
#
# The line is drawn at *routing needs it*: intercept a request, perform it for
# real, hand the response back to the page with something changed. A general
# HTTP client for Julia is not this package's job while HTTP.jl exists, so
# storageState, multipart uploads, fetchLog and `playwright.request` as a
# standalone entry point are all deliberately absent.
#
# It costs three commands and a struct because every BrowserContext's
# initializer already carries a `requestContext` (browserContext.yml:20) — no
# launch-time plumbing, nothing to construct.

"""
    APIResponse

A response fetched by [`Playwright.fetch`](@ref) — outside the page, over the
browser's own network stack, with its cookies and proxy settings.

Not a `ChannelOwner`, because that is not what the protocol models (`api.yml`):
it is an object identified by a `fetch_uid`. It is `mutable` for one reason —
Julia attaches finalizers only to mutable objects, and a leaked response has to
be disposed on finalization. Nothing mutates it but disposal.

[`url`](@ref), [`status`](@ref), [`status_text`](@ref) and
[`headers`](@ref) read its fields and cost nothing; [`body`](@ref),
[`text`](@ref) and [`json`](@ref) fetch the body and cost a round trip.

!!! warning "It holds a driver-side buffer"
    The driver keeps the body until the response is disposed. Inside a route
    handler that happens for you when the handler returns. A response fetched
    outside one is disposed on finalization, and [`dispose!`](@ref) is there
    for the explicit case.
"""
mutable struct APIResponse
    const context::APIRequestContext
    const fetch_uid::String
    const url::String
    const status::Int
    const status_text::String
    const headers::Vector{Pair{String,String}}
    disposed::Bool

    function APIResponse(context::APIRequestContext, raw::AbstractDict)
        r = new(
            context,
            String(raw["fetchUid"]),
            String(raw["url"]),
            Int(raw["status"]),
            String(get(raw, "statusText", "")),
            name_value_pairs(get(raw, "headers", Any[])),
            false,
        )
        # The second half of disposal. The first half is handle_route disposing
        # what a handler fetched. This catches a response fetched outside one and
        # dropped, which the driver would otherwise buffer for the life of the
        # context.
        finalizer(dispose!, r)
        return r
    end
end

url(r::APIResponse) = r.url
status(r::APIResponse) = r.status
status_text(r::APIResponse) = r.status_text
headers_array(r::APIResponse) = r.headers

function headers(r::APIResponse)
    out = Dict{String,String}()
    for (name, value) in r.headers
        key = lowercase(name)
        out[key] = haskey(out, key) ? out[key] * ", " * value : value
    end
    return out
end

ok(r::APIResponse) = r.status == 0 || (200 <= r.status < 300)

"""
    fetch_uid(r::APIResponse) -> String

The driver-side identifier for the fetched body. This is what
`fulfill!(route; response = r)` sends, and what [`dispose!`](@ref) releases.
"""
fetch_uid(r::APIResponse) = r.fetch_uid

# The hook fulfill! calls (defined in routing.jl for anything else).
fetch_response_uid(r::APIResponse) = r.fetch_uid

"""
    body(r::APIResponse) -> Vector{UInt8}
    text(r::APIResponse) -> String
    json(r::APIResponse)

The fetched body, as bytes, as UTF-8, or parsed. **Each costs a round trip**;
none of them is cached, so bind the result rather than calling twice.

Raises if the response has already been disposed — the driver no longer has the
bytes, and saying so beats returning something empty.
"""
function body(r::APIResponse)
    r.disposed && throw(
        DriverError(
            "this APIResponse has been disposed; its body is no longer available. " *
            "Inside a route handler the response is disposed when the handler " *
            "returns, so read the body before then.",
        ),
    )
    bytes = _api_request_context_fetch_response_body(r.context; fetchUid = r.fetch_uid)
    bytes === nothing && throw(DriverError("this APIResponse has no body"))
    return bytes
end

text(r::APIResponse) = String(body(r))
json(r::APIResponse) = JSON.parse(text(r))

"""
    dispose!(r::APIResponse)

Release the driver-side buffer holding this response's body.

Rarely needed by hand: a response fetched inside a route handler is disposed
when the handler returns, and a leaked one is disposed on finalization. It is
here for the case where a response is held deliberately and you want the memory
back at a known moment. Idempotent enough — disposing twice is not an error.
"""
function dispose!(r::APIResponse)
    r.disposed && return nothing
    r.disposed = true
    try
        _api_request_context_dispose_api_response(r.context; fetchUid = r.fetch_uid)
    catch
        # Already gone driver-side, or the connection has closed. Neither is
        # worth raising from a cleanup call, and this runs from a finalizer.
    end
    return nothing
end

"Whether `dispose!` has released this response's driver-side buffer."
is_disposed(r::APIResponse) = r.disposed

"The APIRequestContext that a BrowserContext carries in its initializer."
request_context(ctx::BrowserContext) =
    from_channel(ctx.connection, ctx.initializer["requestContext"])::APIRequestContext


"""
    Playwright.fetch(ctx::BrowserContext, url; kw...) -> APIResponse
    Playwright.fetch(route::Route; kw...) -> APIResponse

Perform an HTTP request over the browser's own network stack — its cookies, its
proxy — without a page being involved.

**Unexported, and called qualified: `Playwright.fetch(…)`**. `Base.fetch`
on a `Task` and `Distributed.fetch` both exist, so exporting this name would
make `using Playwright` alongside either of them ambiguous, and extending
`Base.fetch` would tie together two unrelated ideas. The qualification also
reads well where it matters — inside a route handler it says which call goes
over the network, next to a `fulfill!` that goes over none.

The `Route` form with no URL is Playwright's `route.fetch()`: perform *this*
intercepted request upstream, unmodified, and hand back what the server said.
That is the half of "intercept, forward, modify" that this exists for:

```julia
with_route(ctx, "**/api/items", function (route)
    upstream = Playwright.fetch(route)
    fulfill!(route; response = upstream, status = 500)   # real body, forced status
end) do
    goto!(page, url)
end
```

| Keyword | Meaning |
|---|---|
| `method` | `"GET"`, `"POST"`, … ; defaults to the route's own, or `"GET"` |
| `headers` | a `Dict`; defaults to the route's own on the `Route` form |
| `data` | a `String` or `Vector{UInt8}` body |
| `json` | a Julia value, serialized, with `content-type: application/json` |
| `timeout` | milliseconds; defaults to the owner's timeout cascade |
| `max_redirects` | how many redirects to follow |
| `fail_on_status_code` | raise on 4xx/5xx rather than returning the response |

`data` and `json` are mutually exclusive, and passing both is an
`ArgumentError` here rather than a driver error later.

The result holds a driver-side buffer until it is disposed — see
[`APIResponse`](@ref).
"""
function fetch(
    ctx::BrowserContext,
    url::AbstractString;
    method::Union{AbstractString,Nothing} = nothing,
    headers::Union{AbstractDict,Nothing} = nothing,
    data = nothing,
    json = nothing,
    timeout::MaybeTimeout = nothing,
    max_redirects::Union{Integer,Nothing} = nothing,
    fail_on_status_code::Union{Bool,Nothing} = nothing,
)
    return do_fetch(
        request_context(ctx),
        String(url),
        method,
        headers,
        data,
        json,
        resolve_timeout(ctx, timeout),
        max_redirects,
        fail_on_status_code,
    )
end

function fetch(
    route::Route;
    url::Union{AbstractString,Nothing} = nothing,
    method::Union{AbstractString,Nothing} = nothing,
    headers::Union{AbstractDict,Nothing} = nothing,
    data = nothing,
    json = nothing,
    timeout::MaybeTimeout = nothing,
    max_redirects::Union{Integer,Nothing} = nothing,
    fail_on_status_code::Union{Bool,Nothing} = nothing,
)
    req = request(route)
    ctx = owning_context(route)
    ctx === nothing && (ctx = owning_context(req))
    ctx === nothing &&
        throw(DriverError("this route's context has gone; it cannot be fetched upstream"))
    # Default to the intercepted request's own shape, which is what makes
    # `Playwright.fetch(route)` mean "this request, for real".
    body_default = data === nothing && json === nothing ? post_data(req) : data
    return do_fetch(
        request_context(ctx),
        url === nothing ? Playwright.url(req) : String(url),
        method === nothing ? Playwright.method(req) : method,
        headers === nothing ? Dict(headers_array(req)) : headers,
        body_default,
        json,
        resolve_timeout(ctx, timeout),
        max_redirects,
        fail_on_status_code,
    )
end

function do_fetch(
    context::APIRequestContext,
    url,
    method,
    headers,
    data,
    json,
    timeout,
    max_redirects,
    fail_on_status_code,
)
    data === nothing ||
        json === nothing ||
        throw(
            ArgumentError(
                "Playwright.fetch takes `data` or `json`, not both — they are two " *
                "spellings of the same request body.",
            ),
        )

    post_bytes = nothing
    json_text = nothing
    header_dict = headers === nothing ? nothing : Dict{String,String}()
    if headers !== nothing
        for (k, v) in headers
            header_dict[String(k)] = string(v)
        end
    end

    if json !== nothing
        json_text = JSON.json(json)
        header_dict = header_dict === nothing ? Dict{String,String}() : header_dict
        haskey(header_dict, "content-type") ||
            (header_dict["content-type"] = "application/json")
    elseif data isa AbstractString
        post_bytes = Vector{UInt8}(codeunits(String(data)))
    elseif data isa AbstractVector{UInt8}
        post_bytes = Vector{UInt8}(data)
    elseif data !== nothing
        throw(
            ArgumentError(
                "Playwright.fetch's `data` must be a String or a Vector{UInt8}, got " *
                "$(typeof(data)). For a Julia value serialized as JSON use `json =`.",
            ),
        )
    end

    raw_result = _api_request_context_fetch(
        context;
        url = url,
        timeout = timeout,
        method = method,
        headers = header_dict === nothing ? nothing : name_value_array(header_dict),
        postData = post_bytes,
        jsonData = json_text,
        maxRedirects = max_redirects,
        failOnStatusCode = fail_on_status_code,
    )
    response = APIResponse(context, raw_result)
    track_fetch!(response)
    return response
end

# --- Responses fetched inside a route handler ------------------------------
#
# The dispatcher runs handlers one at a time on its own task, so "the responses
# this handler fetched" is exactly "the responses fetched on this task since
# the handler started". handle_route opens and closes the scope; do_fetch adds
# to whichever scope is open, and to none when a fetch happens outside one.

const FETCH_SCOPES = IdDict{Task,Vector{APIResponse}}()
const FETCH_SCOPES_LOCK = ReentrantLock()

function track_fetch!(r::APIResponse)
    lock(FETCH_SCOPES_LOCK) do
        scope = get(FETCH_SCOPES, current_task(), nothing)
        scope === nothing || push!(scope, r)
    end
    return nothing
end

"Run `body` with a fetch scope open, disposing everything fetched inside it."
function with_fetch_scope(body)
    task = current_task()
    lock(FETCH_SCOPES_LOCK) do
        FETCH_SCOPES[task] = APIResponse[]
    end
    try
        return body()
    finally
        fetched = lock(FETCH_SCOPES_LOCK) do
            pop!(FETCH_SCOPES, task, APIResponse[])
        end
        for r in fetched
            dispose!(r)
        end
    end
end
