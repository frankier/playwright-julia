# File uploads: setting an input directly, and answering a file chooser.
#
# Two mechanisms, because two things happen in the wild: a plain
# `<input type=file>` you can select and set directly, and a button that opens
# the browser's own file dialog through JS with no reachable input.
#
# The payload validation lives in exactly ONE place -- `upload_payload` -- and
# both mechanisms route through it. FileChooser's `set_files!` is
# `set_input_files!` on the chooser's element rather than a second
# implementation, so there is one thing to test and one place for the rule to
# be wrong.

"""
Turn the user-facing forms into the protocol's `localPaths` / `payloads` pair.

Paths and the in-memory form are mutually exclusive, and this says so at the
call site, before anything reaches the driver — the same treatment `fulfill!`
gives its body sources. The driver's own complaint about the same mistake
arrives later and names the wire spelling rather than the keyword.

Returns `(localPaths, payloads)`, at most one of which is non-`nothing`.
"""
function upload_payload(
    files;
    name::Union{AbstractString,Nothing} = nothing,
    mime_type::Union{AbstractString,Nothing} = nothing,
    buffer::Union{AbstractVector{UInt8},Nothing} = nothing,
)
    in_memory = name !== nothing || mime_type !== nothing || buffer !== nothing

    if files !== nothing && in_memory
        throw(
            ArgumentError(
                "set_input_files! takes file paths or an in-memory file " *
                "(`name`, `mime_type`, `buffer`), not both. Pass paths " *
                "positionally, or pass the keywords with no positional " *
                "argument.",
            ),
        )
    end

    if in_memory
        name === nothing && throw(
            ArgumentError("an in-memory upload needs `name` — the filename the page sees"),
        )
        buffer === nothing &&
            throw(ArgumentError("an in-memory upload needs `buffer` — the file's bytes"))
        # The raw bytes, not a base64 string: `to_wire` recurses through
        # containers and encodes Vector{UInt8} itself, and connection.jl is
        # explicit that wire encoding lives there rather than at call sites.
        payload =
            Dict{String,Any}("name" => String(name), "buffer" => Vector{UInt8}(buffer))
        mime_type === nothing || (payload["mimeType"] = String(mime_type))
        return nothing, [payload]
    end

    # `nothing` clears the selection, which the protocol spells as an empty
    # localPaths rather than by omitting both.
    files === nothing && return String[], nothing

    paths = files isa AbstractString ? [String(files)] : String[String(p) for p in files]
    for p in paths
        isfile(p) || throw(ArgumentError("no such file to upload: $p"))
    end
    return paths, nothing
end

"""
    set_input_files!(loc::Locator, files; timeout=nothing)
    set_input_files!(loc::Locator; name, mime_type, buffer, timeout=nothing)
    set_input_files!(loc::Locator; timeout=nothing)

Set the files on a `<input type=file>`.

```julia
set_input_files!(loc, "test/fixtures/upload.csv")          # one path
set_input_files!(loc, ["a.csv", "b.csv"])                  # several
set_input_files!(loc; name = "x.csv", mime_type = "text/csv", buffer = bytes)
set_input_files!(loc)                                      # clears it
```

Paths and the in-memory form are mutually exclusive. Passing both raises an
`ArgumentError` **before** anything reaches the driver. A path that does not
exist raises too, for the same reason: the driver's version of that complaint
arrives later and is harder to place.

Works on a [`Locator`](@ref) or an [`ElementHandle`](@ref). For a button that
opens the browser's file dialog with no input to select, see
[`expect_file_chooser`](@ref).
"""
function set_input_files!(
    loc::Locator,
    files = nothing;
    name = nothing,
    mime_type = nothing,
    buffer = nothing,
    timeout::MaybeTimeout = nothing,
)
    localPaths, payloads = upload_payload(files; name, mime_type, buffer)
    _frame_set_input_files(
        loc.frame;
        selector = loc.selector,
        strict = loc.strict,
        timeout = resolve_timeout(loc, timeout),
        localPaths,
        payloads,
    )
    return nothing
end

function set_input_files!(
    handle::ElementHandle,
    files = nothing;
    name = nothing,
    mime_type = nothing,
    buffer = nothing,
    timeout::MaybeTimeout = nothing,
)
    localPaths, payloads = upload_payload(files; name, mime_type, buffer)
    _element_handle_set_input_files(
        handle;
        timeout = resolve_timeout(handle, timeout),
        localPaths,
        payloads,
    )
    return nothing
end

# --- The file chooser ------------------------------------------------------

"""
    FileChooser

The browser's own file dialog, caught before it opens.

Covers the case [`set_input_files!`](@ref) cannot: a button that opens a file
dialog through JavaScript, with no `<input type=file>` to select.

```julia
fc = expect_file_chooser(page) do
    click!(locator(page, "#attach"))
end
set_files!(fc, "test/fixtures/upload.csv")
```

[`element`](@ref) is the input behind it and [`is_multiple`](@ref) says whether
it will accept more than one file.
"""
struct FileChooser
    element::ElementHandle
    is_multiple::Bool
    page::Page
end

"""
    element(fc::FileChooser) -> ElementHandle

The `<input type=file>` the chooser belongs to.
"""
element(fc::FileChooser) = fc.element

"""
    is_multiple(fc::FileChooser) -> Bool

Whether the chooser accepts more than one file.

!!! note "`webkitdirectory` is `false`, on both engines"
    A directory picker reports `false`, not `true` — selecting a directory is
    one selection, not many. Chromium and Firefox agree exactly here, so this
    is the value to expect on both.
"""
is_multiple(fc::FileChooser) = fc.is_multiple

"""
    set_files!(fc::FileChooser, files; kwargs...)

Answer the chooser with `files`. Takes exactly what [`set_input_files!`](@ref)
takes, because it *is* [`set_input_files!`](@ref) applied to the chooser's
element — the payload rules live in one place rather than two.
"""
set_files!(fc::FileChooser, files = nothing; kwargs...) =
    set_input_files!(fc.element, files; kwargs...)

function file_chooser_payload(owner, params)
    return FileChooser(
        from_channel(owner.connection, params["element"])::ElementHandle,
        Bool(get(params, "isMultiple", false)),
        owner::Page,
    )
end

"""
    expect_file_chooser(f, page::Page; timeout=nothing) -> FileChooser

Run `f()` and return the first file chooser `page` opens.

```julia
fc = expect_file_chooser(page) do
    click!(locator(page, "#attach"))
end
set_files!(fc, "report.csv")
```

The subscription is attached before `f` runs, so a chooser opened immediately
is still caught. `timeout` defaults to the [`set_default_timeout!`](@ref)
cascade.

Unlike a dialog, an unanswered file chooser does not block the page — it simply
never receives files.
"""
expect_file_chooser(f::Function, page::Page; timeout = nothing) =
    expect_event(f, page, :filechooser; timeout)
