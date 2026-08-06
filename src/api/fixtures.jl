# Test fixtures: the per-page setup/teardown a suite would otherwise hand-roll.
#
# B4 in SPEC-M4.md — every suite that has run in CI has written some version of
# "page errors + console errors + a screenshot into an artifacts dir", and got
# it subtly wrong in the same way each time: the dump throws on a page that has
# already gone, and the caller's real failure is lost behind it.
#
# The rule these two obey, and the reason they are written together: **a
# teardown-path function never throws.** It runs while a more important error
# is already in flight. Its job is to add evidence, never to replace the
# failure it was called to explain.

"""
    report_diagnostics(page::Page, dir::AbstractString) -> Vector{String}

Dump everything known about `page` into `dir`, returning the paths actually
written.

Three files, when they can be produced:

| File | From |
|---|---|
| `screenshot.png` | [`screenshot`](@ref) |
| `console.log` | [`console_messages`](@ref) |
| `errors.log` | [`page_errors`](@ref) |

```julia
files = report_diagnostics(page, "artifacts/failure-42")
@info "diagnostics" files
```

!!! note "It never throws"
    This is called from `finally` blocks, on pages that may already be closed —
    the exact situation where a second exception would bury the first. Anything
    that fails is reported with `@warn` and left out of the returned list, so
    a partial dump is still a dump. The return value is what to check if you
    need to know what was captured.

Public in its own right, not only as [`with_page`](@ref)'s helper: a suite with
its own fixture shape should not have to adopt one to get the dump.
"""
function report_diagnostics(page::Page, dir::AbstractString)
    written = String[]
    try
        mkpath(dir)
    catch e
        @warn "could not create the diagnostics directory" dir exception = e
        return written
    end

    # `screenshot` is the one that still throws on a closed page (D4, open
    # question 2): it returns bytes, so it has no natural empty answer. It is
    # caught here rather than made silent there, which keeps the silence in
    # one place and out of the ordinary API.
    capture(written, joinpath(dir, "screenshot.png"), "screenshot") do
        screenshot(page)
    end

    # These two are already no-throw on a dead target (T3), so what is being
    # guarded here is the write, not the read.
    capture(written, joinpath(dir, "console.log"), "console log") do
        messages = console_messages(page)
        isempty(messages) ? nothing :
        codeunits(join(("[$(m.type)] $(m.text)" for m in messages), "\n") * "\n")
    end

    capture(written, joinpath(dir, "errors.log"), "page errors") do
        errors = page_errors(page)
        isempty(errors) ? nothing :
        codeunits(
            join(("$(e.name): $(e.message)\n$(e.stack)" for e in errors), "\n\n") * "\n",
        )
    end

    return written
end

# Run `produce`, write what it returns to `dest`, and record it — or warn and
# carry on. `nothing` means "there was nothing to write", which is not a
# failure and leaves no empty file behind.
function capture(produce::Function, written::Vector{String}, dest::String, what::String)
    try
        content = produce()
        content === nothing && return nothing
        write(dest, content)
        push!(written, dest)
    catch e
        @warn "could not capture $what" path = dest exception = e
    end
    return nothing
end

const ARTIFACTS_ON_VALUES = (:failure, :always)

"""
    with_page(f, browser_or_context, url=nothing; artifacts=nothing,
              artifacts_on=:failure, kw...)

Open a page, optionally navigate it to `url`, run `f(page)`, and always close
the page again. Returns whatever `f` returned.

```julia
with_page(browser, "https://example.com") do page
    click!(locator(page, "#submit"))
end
```

Given `artifacts`, a directory path, [`report_diagnostics`](@ref) runs *before*
the page closes — which is the only time it can still see anything:

```julia
with_page(browser, url; artifacts = "artifacts/checkout") do page
    expect(page; to_have_title = "Checkout")
end
```

`artifacts_on` decides when that happens:

| Value | Dumps |
|---|---|
| `:failure` (default) | only when `f` throws |
| `:always` | on every run |

`:failure` is the default because a screenshot per passing test is a lot of
bytes for nothing on a large suite. `:always` exists because a passing-but-wrong
run is exactly when symmetric evidence helps, and a caller who wants it should
not have to reimplement the fixture. Any other value is an `ArgumentError`
listing the two, and `artifacts_on` without `artifacts` is an `ArgumentError`
too — it can only be a mistake about where the files were meant to go.

Remaining keywords go to [`goto!`](@ref), so `wait_until` and `timeout` work as
usual.

!!! note "Your exception always wins"
    If `f` throws, that exception propagates **unchanged** — same type, same
    message — after the diagnostics are written. A failure *in* the diagnostics
    is a `@warn`, never an exception. The helper adds evidence; it never
    replaces the failure.
"""
function with_page(
    f,
    target::Union{Browser,BrowserContext},
    url::Union{AbstractString,Nothing} = nothing;
    artifacts::Union{AbstractString,Nothing} = nothing,
    artifacts_on::Symbol = :failure,
    kw...,
)
    artifacts_on in ARTIFACTS_ON_VALUES || throw(
        ArgumentError(
            "`artifacts_on = $(repr(artifacts_on))` is not valid. Valid values: " *
            join([repr(v) for v in ARTIFACTS_ON_VALUES], ", "),
        ),
    )
    # Passing one without the other can only be a mistake about where the
    # files were meant to go, so it is refused rather than quietly ignored.
    artifacts === nothing &&
        artifacts_on !== :failure &&
        throw(
            ArgumentError(
                "`artifacts_on = $(repr(artifacts_on))` needs `artifacts` to " *
                "say which directory to write to.",
            ),
        )

    page = new_page(target)
    threw = false
    try
        url === nothing || goto!(page, url; kw...)
        return f(page)
    catch
        threw = true
        rethrow()
    finally
        # Before the close, because afterwards there is nothing left to see.
        if artifacts !== nothing && (artifacts_on === :always || threw)
            # Teardown: this must not replace the caller's exception.
            try
                report_diagnostics(page, artifacts)
            catch e
                @warn "could not write diagnostics" dir = artifacts exception = e
            end
        end
        try
            close!(page)
        catch e
            @warn "could not close the page" exception = e
        end
    end
end
