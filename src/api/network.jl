# Request and Response: what the browser asked for, and what came back.
#
# Both carry nearly everything in their initializer, which is already in
# memory by the time the event that delivered them arrives. The accessors read
# it directly. Only `body`, `response` and the two raw-header calls go to the
# wire, and each of those says so in its docstring — a round trip inside a
# routing handler is a cost worth being able to see at the call site.

# --- Headers ---------------------------------------------------------
#
# Three functions, because there are genuinely three questions: what is the
# value of this header, what did the wire literally carry, and what did the
# browser actually send once it had added its own. Collapsing them into one
# would mean picking a lossy answer and calling it the answer.

"""
    headers(req_or_resp) -> Dict{String,String}

The headers, lower-cased and flattened — the common case, and free (it reads
the initializer, no round trip).

Duplicate header names are joined with `", "`, following HTTP's own rule for
combining repeated fields. That is lossy for `Set-Cookie`, which is why
[`headers_array`](@ref) exists.

```julia
headers(response)["content-type"]     # "application/json"
```

For what the browser really put on the wire — including the headers Playwright
did not add — see [`raw_headers`](@ref), which does cost a round trip.
"""
function headers(obj::Union{Request,Response})
    out = Dict{String,String}()
    for (name, value) in headers_array(obj)
        key = lowercase(name)
        out[key] = haskey(out, key) ? out[key] * ", " * value : value
    end
    return out
end

"""
    headers_array(req_or_resp) -> Vector{Pair{String,String}}

The headers in wire order, duplicates preserved, names exactly as they came.
Free — it reads the initializer.

This is the one to use for `Set-Cookie`, which is the header that duplicates
in practice and the one [`headers`](@ref) flattens.

```julia
[v for (k, v) in headers_array(response) if lowercase(k) == "set-cookie"]
```
"""
headers_array(obj::Union{Request,Response}) = name_value_pairs(obj.initializer["headers"])

"""
    raw_headers(req_or_resp) -> Vector{Pair{String,String}}

The headers as actually sent or received, in wire order.

**This costs a protocol round trip**, unlike [`headers`](@ref) and
[`headers_array`](@ref), which read what is already in memory. It is worth it
for exactly one question: what the browser *really* sent, as opposed to what it
was asked to send. A routing test that mocks a request and then wants to know
whether the browser added `accept-encoding` on its own has no other way to ask.

The request form is only available once the request has actually been sent, so
inside a route handler — before `continue!` — it raises rather than inventing
an answer.
"""
raw_headers(req::Request) = name_value_pairs(_request_raw_request_headers(req))
raw_headers(resp::Response) = name_value_pairs(_response_raw_response_headers(resp))

"""
The protocol's NameValue array as Julia pairs, in wire order. The mirror of
`name_value_array`, which goes the other way.
"""
name_value_pairs(raw) = [String(h["name"]) => String(h["value"]) for h in raw]

# --- Request ---------------------------------------------------------------

"""
    url(req::Request) -> String

The requested URL, including the query string.
"""
url(req::Request) = req.initializer["url"]::String

"""
    method(req::Request) -> String

The HTTP method, upper-cased as the wire carries it: `"GET"`, `"POST"`, …
"""
method(req::Request) = req.initializer["method"]::String

"""
    resource_type(req::Request) -> String

What the browser thinks it is fetching: `"document"`, `"stylesheet"`,
`"script"`, `"image"`, `"xhr"`, `"fetch"`, `"font"`, … .

Useful as a routing filter — aborting every `"image"` is the standard way to
make a test suite stop downloading pictures it never looks at.

The values come from the browser, not from this package, and Chromium and
Firefox do not always agree on the rarer ones. Match on the common cases and
prefer the URL for anything precise.
"""
resource_type(req::Request) = req.initializer["resourceType"]::String

"""
    is_navigation_request(req::Request) -> Bool

Whether this request is a navigation — the document itself, rather than
something the document asked for afterwards.
"""
is_navigation_request(req::Request) = req.initializer["isNavigationRequest"]::Bool

"""
    frame(req::Request) -> Union{Frame,Nothing}

The frame that issued the request, or `nothing` for a request that no frame
owns — a service worker's, for instance.
"""
frame(req::Request) = from_channel(req.connection, get(req.initializer, "frame", nothing))

"""
    redirected_from(req::Request) -> Union{Request,Nothing}

The request that redirected to this one, or `nothing` when there was no
redirect. Walk it repeatedly to recover a whole redirect chain, newest first.

```julia
chain = [req]
while (previous = redirected_from(chain[end])) !== nothing
    push!(chain, previous)
end
```
"""
redirected_from(req::Request) =
    from_channel(req.connection, get(req.initializer, "redirectedFrom", nothing))

"""
    post_data(req::Request) -> Union{Vector{UInt8},Nothing}

The request body as bytes, or `nothing` for a request that carries none.

Bytes, because that is what a request body is — a form upload is not text.
[`post_data_string`](@ref) decodes UTF-8 and [`json`](@ref) parses; three
names for three return types rather than one name that changes its mind.
"""
function post_data(req::Request)
    raw = get(req.initializer, "postData", nothing)
    raw === nothing && return nothing
    return base64decode(raw)
end

"""
    post_data_string(req::Request) -> Union{String,Nothing}

The request body decoded as UTF-8, or `nothing` when there is none. Raises if
the body is not valid UTF-8 — use [`post_data`](@ref) for bodies that are not
text.
"""
function post_data_string(req::Request)
    bytes = post_data(req)
    bytes === nothing && return nothing
    return String(bytes)
end

"""
    response(req::Request) -> Union{Response,Nothing}

The response to this request, or `nothing` if there was none — the request
failed, or was aborted by a route.

**Costs a round trip**, and blocks until the response is available.
"""
response(req::Request) = _request_response(req)

# --- Response --------------------------------------------------------------

"""
    url(resp::Response) -> String

The URL this response came from. Not necessarily the URL that was requested:
after a redirect it is the final one.
"""
url(resp::Response) = resp.initializer["url"]::String

"""
    status(resp::Response) -> Int

The HTTP status code.
"""
status(resp::Response) = Int(resp.initializer["status"])

"""
    status_text(resp::Response) -> String

The status line's text — `"Not Found"`, `"OK"`. Servers are free to send
anything here, and HTTP/2 sends nothing at all, so it can be `""`. Assert on
[`status`](@ref) instead.
"""
status_text(resp::Response) = resp.initializer["statusText"]::String

"""
    ok(resp::Response) -> Bool

Whether the status is in the 2xx range, or 0 — which is what a `file://` or
`data:` response reports.
"""
function ok(resp::Response)
    code = status(resp)
    return code == 0 || (200 <= code < 300)
end

"""
    request(resp::Response) -> Request

The request this response answers.
"""
request(resp::Response) =
    from_channel(resp.connection, resp.initializer["request"])::Request

"""
    body(resp::Response) -> Vector{UInt8}

The response body as bytes. **Costs a round trip**, and blocks until the body
has finished arriving.

See [`text`](@ref) for UTF-8 and [`json`](@ref) for parsed JSON.
"""
body(resp::Response) = _response_body(resp)

"""
    text(resp::Response) -> String

The response body decoded as UTF-8. **Costs a round trip** — it is
[`body`](@ref) plus a decode.
"""
text(resp::Response) = String(body(resp))

"""
    json(resp::Response)
    json(req::Request)

The body parsed as JSON. **The response form costs a round trip**; the request
form does not, since a request body is already in the initializer.

Raises if the body is not valid JSON, which is the useful behaviour: a test
that meant to receive JSON and received an HTML error page should say so.
"""
json(resp::Response) = JSON.parse(text(resp))

function json(req::Request)
    s = post_data_string(req)
    s === nothing && throw(ArgumentError("this request has no body to parse as JSON"))
    return JSON.parse(s)
end

# --- Failure ---------------------------------------------------------------

"""
    RequestFailure

Why a request failed, as delivered by the `:requestfailed` event.

`error_text` is the browser's own string — `"net::ERR_CONNECTION_REFUSED"` on
Chromium, `"NS_ERROR_CONNECTION_REFUSED"` on Firefox. The engines do not agree
on the spelling, so match loosely or match on the request instead.

A route that was aborted also arrives here: an abort *is* a failure, from the
page's point of view, which is the point of aborting.
"""
struct RequestFailure
    request::Request
    error_text::String
end

"The failing request."
request(f::RequestFailure) = f.request

"The browser's own description of the failure. Engine-specific — see [`RequestFailure`](@ref)."
error_text(f::RequestFailure) = f.error_text

Base.show(io::IO, f::RequestFailure) =
    print(io, "RequestFailure(", repr(url(f.request)), ", ", repr(f.error_text), ")")

# --- expect_request / expect_response --------------------------------
#
# Sugar over expect_event with a matcher-derived predicate. They exist because
# the predicate spelling is the part users get wrong, and because these two are
# most of real network-event use.

"""
    expect_request(f, target, matcher; timeout=nothing) -> Request

Run `f()` and return the first request on `target` whose URL satisfies
`matcher` — a glob, a `Regex` or a `url -> Bool` predicate, the same union
[`route!`](@ref) takes.

The subscription is attached before `f` runs, so a request the body fires
immediately is still caught.

```julia
request = expect_request(ctx, "**/api/todos") do
    click!(locator(page, "#load"))
end
method(request)      # "GET"
```

`target` may be a [`BrowserContext`](@ref) or a [`Page`](@ref). The page form
watches the page's *context* and keeps only that page's traffic, so with
two pages open each sees its own.
"""
function expect_request(
    f::Function,
    target::Union{Page,BrowserContext},
    matcher;
    timeout = nothing,
)
    return expect_event(
        f,
        target,
        :request;
        timeout,
        predicate = req -> matches(matcher, url(req)),
    )
end

"""
    expect_response(f, target, matcher; timeout=nothing) -> Response

Run `f()` and return the first response on `target` whose URL satisfies
`matcher`. The response form of [`expect_request`](@ref), and the same matcher
union.

```julia
response = expect_response(ctx, "**/api/todos") do
    click!(locator(page, "#load"))
end
status(response)     # 200
json(response)
```

The body is not fetched until you ask for it — [`body`](@ref), [`text`](@ref)
and [`json`](@ref) each cost a round trip and block until it has arrived.
"""
function expect_response(
    f::Function,
    target::Union{Page,BrowserContext},
    matcher;
    timeout = nothing,
)
    return expect_event(
        f,
        target,
        :response;
        timeout,
        predicate = resp -> matches(matcher, url(resp)),
    )
end
