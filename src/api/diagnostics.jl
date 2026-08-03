# Diagnostics pulled from a page: console messages and uncaught page errors.
#
# These are pull-based getters (SPEC-M2.md D6), not subscriptions: the driver
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

"""
    console_messages(page::Page) -> Vector{ConsoleMessage}

Every console message the page has produced since it opened, or since
[`clear_console_messages`](@ref) was last called.

```julia
for msg in console_messages(page)
    msg.type == "error" && @warn "console error" msg.text
end
```
"""
function console_messages(page::Page)
    raw = _page_console_messages(page)
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
[`clear_page_errors`](@ref) was last called. Worth dumping when a test fails
for a reason the assertion alone does not explain:

```julia
for err in page_errors(page)
    @warn "page error" err.message err.stack
end
```
"""
function page_errors(page::Page)
    return PageError[page_error(raw) for raw in _page_page_errors(page)]
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
    clear_console_messages(page::Page)

Drop the page's buffered console messages, so a later
[`console_messages`](@ref) only reports what happened next. Useful for
per-test isolation on a shared page.
"""
clear_console_messages(page::Page) = _page_clear_console_messages(page)

"""
    clear_page_errors(page::Page)

Drop the page's buffered uncaught errors; see [`clear_console_messages`](@ref).
"""
clear_page_errors(page::Page) = _page_clear_page_errors(page)
