# Diagnostics pulled from a page: console messages and uncaught page errors.
#
# These are pull-based getters, not subscriptions: the driver
# buffers messages and errors per page, and these read the buffer. There is no
# background task, no callback, and no ordering guarantee beyond the driver's
# own. That is enough for the thing they exist for — explaining a test failure
# after it has happened.

"""
    SourceLocation

Where a console message came from: the script `url` and the 1-based `line` and
`column` within it.
"""
struct SourceLocation
    url::String
    line::Int
    column::Int
end

"""
    ConsoleMessage

One buffered console message. `type` is the console method that produced it
(`"log"`, `"info"`, `"warning"`, `"error"`, `"debug"`, …), `text` is the
rendered message, `location` is where it came from and `timestamp` is
milliseconds since the epoch.

Read them off a page with [`console_messages`](@ref):

```julia
for msg in console_messages(page)
    println(msg.type, " @ ", msg.location.url, ":", msg.location.line, " — ", msg.text)
end
```
"""
struct ConsoleMessage
    type::String
    text::String
    location::SourceLocation
    timestamp::Float64
end

"""
    PageError

One uncaught JavaScript error, with the error's `message`, its `name`
(usually `"Error"`) and its `stack`.

Read them off a page with [`page_errors`](@ref). This is a *page's* error —
something the JavaScript threw — and so is unrelated to
[`PlaywrightError`](@ref), which is what this package's own calls raise.

```julia
isempty(page_errors(page)) || @warn "the page threw" page_errors(page)
```
"""
struct PageError
    message::String
    name::String
    stack::String
end

Base.show(io::IO, m::ConsoleMessage) = print(io, "ConsoleMessage($(m.type)): $(m.text)")
Base.show(io::IO, e::PageError) = print(io, "PageError: $(e.message)")

function source_location(raw)
    raw isa AbstractDict || return SourceLocation("", 0, 0)
    return SourceLocation(
        get(raw, "url", ""),
        Int(get(raw, "lineNumber", 0)),
        Int(get(raw, "columnNumber", 0)),
    )
end

# The postmortem readers never throw on a dead target.
#
# These run in `finally` blocks, which is exactly when the page may already be
# gone — and a throw there replaces the caller's real failure with a less
# interesting one. "The page is closed" is not news to someone who is
# already handling an error, so the answer is "nothing to report" rather than a
# second exception.
#
# Two guards, because a closed page fails in two different ways:
#
#   * Already disposed when the call starts. These readers do not hop through
#     `main_frame`, so they get no guard from it — and the driver has nothing
#     left to answer with, so a message sent anyway would wait forever. The
#     liveness check therefore happens *before* the send.
#   * Closed under the call. The message went out to a live page and the reply
#     came back as a TargetClosedError. Nothing can prevent that race; it is
#     caught.
#
# The silence is bounded twice over: only this error type, only these readers.
# Any other failure still propagates, so a genuine bug is not hidden — and
# `screenshot` is deliberately not in the list (open question 2).
function postmortem_read(f::Function, page::Page, empty::T) where {T}
    lookup_object(page.connection, page.guid) === nothing && return empty
    return try
        f()
    catch e
        e isa TargetClosedError || rethrow()
        empty
    end
end

"""
    console_messages(page::Page) -> Vector{ConsoleMessage}

Every console message the page has produced since it opened, or since
[`clear_console_messages!`](@ref) was last called.

```julia
for msg in console_messages(page)
    msg.type == "error" && @warn "console error" msg.text
end
```

Returns an empty vector — rather than raising [`TargetClosedError`](@ref) — if
the page or its context has already closed. This is a postmortem reader,
typically called from a `finally` block while a more important error is in
flight. Throwing there would mask that error, and "the page is gone" tells a
caller who is already handling a failure nothing it can use. Any *other* error
still propagates.
"""
function console_messages(page::Page)
    raw = postmortem_read(page, Any[]) do
        _page_console_messages(page)
    end
    return ConsoleMessage[
        ConsoleMessage(
            get(m, "type", ""),
            get(m, "text", ""),
            source_location(get(m, "location", nothing)),
            Float64(get(m, "timestamp", 0)),
        ) for m in raw
    ]
end

"""
    page_errors(page::Page) -> Vector{PageError}

Every uncaught JavaScript error the page has raised since it opened, or since
[`clear_page_errors!`](@ref) was last called. Worth dumping when a test fails
for a reason the assertion alone does not explain:

```julia
for err in page_errors(page)
    @warn "page error" err.message err.stack
end
```

Like [`console_messages`](@ref), returns an empty vector rather than raising
when the page or its context has already closed — see that docstring for why.
"""
function page_errors(page::Page)
    raw = postmortem_read(page, Any[]) do
        _page_page_errors(page)
    end
    return PageError[page_error(r) for r in raw]
end

# A SerializedError carries either a real Error object or, when the page threw
# a non-Error value (`throw "boom"`), just the thrown value.
function page_error(raw::AbstractDict)
    detail = get(raw, "error", nothing)
    if detail isa AbstractDict
        return PageError(
            get(detail, "message", ""),
            get(detail, "name", "Error"),
            get(detail, "stack", ""),
        )
    end
    thrown = get(raw, "value", nothing)
    thrown === nothing && return PageError("unknown page error", "Error", "")
    return PageError(string(from_serialized(thrown)), "Error", "")
end

"""
    clear_console_messages!(page::Page)

Drop the page's buffered console messages, so a later
[`console_messages`](@ref) only reports what happened next. Useful for
per-test isolation on a shared page, where the previous test's noise would
otherwise be reported as this one's.

```julia
clear_console_messages!(page)
click!(locator(page, "#go"))
@test isempty(filter(m -> m.type == "error", console_messages(page)))
```
"""
clear_console_messages!(page::Page) = _page_clear_console_messages(page)

"""
    clear_page_errors!(page::Page)

Drop the page's buffered uncaught errors, so a later [`page_errors`](@ref)
only reports what happened next. The console equivalent is
[`clear_console_messages!`](@ref).

```julia
clear_page_errors!(page)
click!(locator(page, "#go"))
@test isempty(page_errors(page))
```
"""
clear_page_errors!(page::Page) = _page_clear_page_errors(page)
