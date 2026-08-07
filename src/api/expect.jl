# Retrying assertions, driver-side (D3).
#
# `frame.expect` re-checks the condition in the browser until it holds or the
# timeout runs out, so a value that is merely late passes without the test
# sleeping for it. That is the whole point: `sleep(1); @test text_content(x) ==
# "y"` is either slower than it needs to be or flaky, and usually both.
#
# The expression strings below and the shape of a failure were probed against
# the live 1.61.1 driver before any of this was written — see T6 in
# tasks/plan.md. Two findings shape the code:
#
#   * A failed assertion arrives as an *error reply*, not a result with
#     `matches: false`. There is nothing to inspect on success, so the API is
#     built around catching rather than around reading a return value.
#   * The received value is in the reply's top-level `errorDetails`, which is
#     the only structured route to it; the call log carries it as prose only.

"""
    Not(expected)

Negate a single [`expect`](@ref) matcher:

```julia
expect(loc; to_have_text = Not("Goodbye"))     # any text but that
```

A wrapper rather than a call-wide `negate` keyword, because one `expect` call
can carry several matchers and each is a separate check — with a single flag
there would be no way to say "has count 3, but *not* this text".

It is an ordinary value, and holds the expectation it negates:

```jldoctest
julia> n = Not("Goodbye")
Not("Goodbye")

julia> n.expected
"Goodbye"

julia> Not(r"^se")
Not(r"^se")
```

For the boolean matchers, `= false` says the same thing more readably:
`to_be_visible = false` rather than `to_be_visible = Not(true)`.
"""
struct Not{T}
    expected::T
end

Base.show(io::IO, n::Not) = print(io, "Not(", repr(n.expected), ")")

# Peel a Not off, returning (expected, isNot).
negated(x::Not) = (x.expected, true)
negated(x) = (x, false)

"""
An `ExpectedTextValue` (playwright.yml:240). A `String` matches exactly; a
`Regex` is sent as a pattern and flags so the *driver* does the matching, which
keeps the retry loop in the browser rather than shipping text back per attempt.
"""
expected_text(s::AbstractString) = Dict{String,Any}("string" => String(s))
expected_text(r::Regex) = Dict{String,Any}(
    "regexSource" => r.pattern,
    "regexFlags" => join(c for (bit, c) in REGEX_FLAGS if r.compile_options & bit != 0),
)
expected_text(x) = expected_text(string(x))

# keyword => (wire expression, how to fill the params, how to describe it)
#
# Closed on purpose. A bogus expression fails on the wire with exactly the same
# generic "Expect failed" as a real mismatch (probed), so a typo'd matcher name
# has to be caught here or it will masquerade as a failing assertion.
const MATCHERS = Dict{Symbol,Any}(
    :to_have_text => (
        expression = "to.have.text",
        params = v -> (; expectedText = [expected_text(v)]),
    ),
    :to_contain_text => (
        expression = "to.have.text",
        params = v -> (;
            expectedText = [merge(expected_text(v), Dict("matchSubstring" => true))]
        ),
    ),
    :to_have_value => (
        expression = "to.have.value",
        params = v -> (; expectedText = [expected_text(v)]),
    ),
    :to_have_count =>
        (expression = "to.have.count", params = v -> (; expectedNumber = Float64(v))),
    :to_be_visible => (expression = "to.be.visible", params = _ -> (;)),
    :to_be_hidden => (expression = "to.be.hidden", params = _ -> (;)),
    :to_be_enabled => (expression = "to.be.enabled", params = _ -> (;)),
    :to_be_disabled => (expression = "to.be.disabled", params = _ -> (;)),
    :to_be_checked => (expression = "to.be.checked", params = _ -> (;)),
    :to_have_attribute => (
        expression = "to.have.attribute.value",
        params = v -> (;
            expressionArg = String(first(v)),
            expectedText = [expected_text(last(v))],
        ),
    ),
)

# Document-level matchers (D2). Same protocol command, same table shape — the
# only difference is what they run against.
#
# The selector for these is the **empty string**, which is the one thing here
# that could not be guessed: probed on both engines (T1, tasks/m4-probe.md),
# `":root"` and `"html"` both fail, and they fail with the same generic "Expect
# failed" a real mismatch gives. Hence a closed table here too.
const DOCUMENT_MATCHERS = Dict{Symbol,Any}(
    :to_have_title => (
        expression = "to.have.title",
        params = v -> (; expectedText = [expected_text(v)]),
    ),
    :to_have_url => (
        expression = "to.have.url",
        params = v -> (; expectedText = [expected_text(v)]),
    ),
)

const DOCUMENT_SELECTOR = ""

matcher_names(table) = join(sort!([":$k" for k in keys(table)]), ", ")

# Matchers are partitioned by target, and a matcher used on the wrong one is an
# ArgumentError naming the target that *would* work. Sent to the driver it
# would come back as the same generic failure a real mismatch produces, so the
# mistake has to be caught here or it masquerades as a failing assertion.
function lookup_matcher(
    table,
    other,
    name::Symbol,
    this_target::String,
    other_target::String,
)
    spec = get(table, name, nothing)
    spec === nothing || return spec
    if haskey(other, name)
        throw(
            ArgumentError(
                "`$name` asserts about $other_target, not $this_target. " *
                "Available for $this_target: " *
                matcher_names(table),
            ),
        )
    end
    throw(
        ArgumentError(
            "unknown matcher `$name`. Available for $this_target: " * matcher_names(table),
        ),
    )
end

# The boolean matchers take `true`/`false` rather than a value, and `false`
# simply inverts the check — `to_be_visible = false` is `to.be.visible` negated,
# which is what a reader expects it to mean.
const BOOLEAN_MATCHERS =
    (:to_be_visible, :to_be_hidden, :to_be_enabled, :to_be_disabled, :to_be_checked)

"""
    expect(loc::Locator; timeout=nothing, matchers...) -> loc

Assert something about `loc`, retrying in the browser until it holds or
`timeout` runs out. Returns `loc` on success, so assertions chain; raises
[`AssertionFailure`](@ref) on failure, with a message naming both what was
expected and what was actually there.

This is what replaces `sleep`-then-assert. The condition is re-checked
driver-side, so an element that arrives late passes as soon as it arrives
rather than after a fixed wait:

```julia
expect(locator(page, "#late"); to_have_text = "late arrival")
expect(locator(page, "li"; strict=false); to_have_count = 3)
expect(locator(page, "#box"); to_have_value = r"^se")
expect(locator(page, "#link"); to_have_attribute = "href" => "/somewhere")
```

| Matcher | Expects |
|---|---|
| `to_have_text` | exact text — a `String` or a `Regex` |
| `to_contain_text` | text containing the given substring or match |
| `to_have_value` | an input's value |
| `to_have_count` | how many elements the locator matches |
| `to_have_attribute` | `name => value` |
| `to_be_visible`, `to_be_hidden` | `true`/`false` |
| `to_be_enabled`, `to_be_disabled` | `true`/`false` |
| `to_be_checked` | `true`/`false` |

Wrap any expectation in [`Not`](@ref) to negate it; for the boolean matchers,
`= false` does the same thing more readably.

Several matchers in one call are checked one after another, and the first
failure raises. `timeout` is in milliseconds and defaults to the
[`set_default_timeout!`](@ref) cascade — and applies to *each* matcher, since
each is its own retrying check.

For a condition this cannot express, [`retry_until`](@ref) is the escape hatch.
"""
function expect(loc::Locator; timeout::MaybeTimeout = nothing, matchers...)
    isempty(matchers) && throw(
        ArgumentError(
            "expect needs at least one matcher, e.g. " *
            "`expect(loc; to_have_text = \"…\")`. Available: " *
            join(sort!([":$k" for k in keys(MATCHERS)]), ", "),
        ),
    )
    ms = resolve_timeout(loc, timeout)
    for (name, raw) in pairs(matchers)
        spec = lookup_matcher(
            MATCHERS,
            DOCUMENT_MATCHERS,
            name,
            "a Locator",
            "the whole page or frame",
        )
        expected, is_not = negated(raw)
        # `to_be_visible = false` reads as "assert it is not visible".
        if name in BOOLEAN_MATCHERS
            expected isa Bool ||
                throw(ArgumentError("`$name` takes true or false, got $(repr(expected))"))
            is_not = is_not ⊻ !expected
        end
        run_expect(
            loc.frame,
            loc.selector,
            "locator($(repr(loc.selector)))",
            name,
            spec,
            expected,
            is_not,
            ms,
        )
    end
    return loc
end

"""
    expect(page::Page; timeout=nothing, matchers...) -> page
    expect(frame::Frame; timeout=nothing, matchers...) -> frame

Assert something about the *document* rather than about an element, retrying in
the browser until it holds or `timeout` runs out. Returns its target, so
assertions chain; raises [`AssertionFailure`](@ref) on failure, carrying the
value that was actually there.

```julia
expect(page; to_have_title = "M4")
expect(page; to_have_url = r"m4\\.html\$")
```

| Matcher | Expects |
|---|---|
| `to_have_title` | the document title — a `String` or a `Regex` |
| `to_have_url` | the current URL — a `String` or a `Regex` |

`expect(page; …)` delegates to the page's main frame; pass a `Frame` directly
to assert about an iframe's document instead.

Matchers are partitioned by target: the element matchers
(`to_have_text`, `to_be_visible`, …) belong to
[`expect(::Locator)`](@ref) and passing one here is an `ArgumentError` naming
the target that would work. That check is local on purpose — sent to the
driver, a matcher against the wrong target fails with the same generic
message a real mismatch produces.
"""
expect(page::Page; kw...) = (expect(main_frame(page); kw...); page)

function expect(frame::Frame; timeout::MaybeTimeout = nothing, matchers...)
    isempty(matchers) && throw(
        ArgumentError(
            "expect needs at least one matcher, e.g. " *
            "`expect(page; to_have_title = \"…\")`. Available: " *
            matcher_names(DOCUMENT_MATCHERS),
        ),
    )
    ms = resolve_timeout(frame, timeout)
    for (name, raw) in pairs(matchers)
        spec = lookup_matcher(
            DOCUMENT_MATCHERS,
            MATCHERS,
            name,
            "the whole page or frame",
            "a Locator",
        )
        expected, is_not = negated(raw)
        run_expect(frame, DOCUMENT_SELECTOR, "the page", name, spec, expected, is_not, ms)
    end
    return frame
end

# Every assertion is one `frame.expect` against a frame and a selector — an
# element matcher supplies the locator's, a document matcher the empty string.
# `described` is what the failure message calls the target, since `locator("")`
# would read like a bug in the package rather than a page-level assertion.
function run_expect(
    frame::Frame,
    selector::AbstractString,
    described::AbstractString,
    name::Symbol,
    spec,
    expected,
    is_not::Bool,
    ms::Int,
)
    try
        _frame_expect(
            frame;
            selector,
            expression = spec.expression,
            isNot = is_not,
            timeout = ms,
            spec.params(expected)...,
        )
    catch e
        e isa ExpectFailure || rethrow()
        throw(assertion_failure(e, described, name, expected, is_not, ms))
    end
    return nothing
end

# SC 7: the message has to carry the expected *and* the received value, or the
# reader is back to re-running the test by hand to find out what was there.
function assertion_failure(
    e::ExpectFailure,
    described::AbstractString,
    name::Symbol,
    expected,
    is_not::Bool,
    ms::Int,
)
    got = received_value(e)
    custom = custom_error_message(e)
    want = is_not ? "not $(repr(expected))" : repr(expected)

    lines = ["$name failed on $described", "  expected: $want"]
    if custom !== nothing
        push!(lines, "  received: $custom")
    else
        push!(lines, "  received: $(repr(got))")
    end
    timed_out(e) && push!(lines, "  (gave up after $(ms)ms of retrying)")
    # The driver's own call log explains what it retried and how often, which
    # is the difference between "never matched" and "never even resolved".
    push!(lines, "")
    push!(lines, e.message)

    return AssertionFailure(join(lines, "\n"); name = "AssertionFailure", stack = e.stack)
end

# The two knobs are closed sets, for the reason MATCHERS is one: a typo'd
# `:allways` must not silently mean "never". Spelled out here so the error
# message and the check cannot drift apart.
#
# A Julia wrinkle worth stating plainly, because it looks like a bug at every
# call site: `:false` is **not** a Symbol. `false` is a boolean literal, so
# `:false` quotes to `false::Bool`, while `:throw` and `:retry` really are
# Symbols. The keyword therefore takes `Union{Symbol,Bool}` and `on_timeout =
# :false` and `on_timeout = false` are the same thing — which is what a reader
# expects them to be anyway. SPEC-M4.md spells it `:false` throughout, so that
# spelling has to work.
const ON_TIMEOUT_VALUES = (:throw, false)
const ON_ERROR_VALUES = (:throw, :retry)

# `repr(false)` is "false", not ":false"; spell the documented form.
show_knob(v::Bool) = ":$v"
show_knob(v::Symbol) = repr(v)

function check_knob(name::Symbol, value, valid::Tuple)
    any(v -> v === value, valid) && return value
    throw(
        ArgumentError(
            "`$name = $(show_knob(value))` is not valid. Valid values: " *
            join([show_knob(v) for v in valid], ", "),
        ),
    )
end

"""
    retry_until(f; timeout=nothing, interval=100, on_timeout=:throw, on_error=:throw)
    retry_until(f, target; …)

Call `f()` every `interval` ms until it returns `true`, or give up after
`timeout` ms.

The escape hatch for conditions [`expect`](@ref) cannot express. Prefer
`expect` where it fits — it retries *inside* the browser, so it neither
round-trips per attempt nor misses a state that flickers between polls:

`target` comes **second** here while every other function in the package takes
it first. That is Julia's constraint rather than a choice: `f` has to be
argument one for `retry_until(target) do … end` to parse as a do-block at all,
and a do-block is how this function is meant to be called.

```julia
retry_until(; timeout = 5_000) do
    length(console_messages(page)) >= 3
end
```

## What happens when it does not hold

| `on_timeout` | Giving up means |
|---|---|
| `:throw` (default) | raise [`AssertionFailure`](@ref) |
| `:false` | return `false` |

`:false` is what makes `retry_until` usable inside `@test`. stdlib `Test`
records a *throwing* assertion as an `Error` — "this test is broken" — and a
false one as a `Fail` — "this assertion did not hold", which is the truth about
a condition that never arrived, and which renders the expression and its value
instead of a stacktrace through package internals:

```julia
@test retry_until(page; on_timeout = :false) do
    HTTP.get(probe_url).status == 200
end
```

!!! note "`:false` is the boolean `false`"
    Unlike `:throw` and `:retry`, `:false` is not a `Symbol` — `false` is a
    boolean literal, so Julia parses `:false` as `false`. Both spellings are
    accepted and mean the same thing; `:false` is written here only because it
    lines up with the other values at the call site.

## What happens when the predicate throws

| `on_error` | An exception from `f` means |
|---|---|
| `:throw` (default) | propagate it immediately |
| `:retry` | treat it as "not yet" and keep going, under the same deadline |

`:throw` is right for a DOM predicate, where a throw is a broken test rather
than a condition that has not happened yet, and swallowing it would hide the
bug until the timeout. `:retry` is right for the common end-to-end shape where
the predicate is an HTTP call against a server that is still warming up.

The silence stays bounded: under `:retry` the *last* exception is attached to
the eventual timeout failure, so a predicate that never stops throwing still
reports why it never stopped.

## Which timeout

Given a `target` — a [`Page`](@ref), [`BrowserContext`](@ref), `Frame` or
[`Locator`](@ref), positionally, as [`expect_event`](@ref) takes one — the
timeout comes from the [`set_default_timeout!`](@ref) cascade, so
`retry_until` follows the same rules as everything else:

```julia
set_default_timeout!(page, 2_000)
retry_until(() -> ready(), page)      # gives up after 2 s
```

Without a target there is nothing to inherit from and `timeout` falls back to
[`DEFAULT_TIMEOUT`](@ref). An explicit `timeout` keyword always wins.
"""
function retry_until(
    f::Function;
    timeout::MaybeTimeout = nothing,
    interval::Real = 100,
    on_timeout::Union{Symbol,Bool} = :throw,
    on_error::Symbol = :throw,
)
    ms = timeout === nothing ? DEFAULT_TIMEOUT : Int(timeout)
    return retry_loop(f, ms, interval, on_timeout, on_error)
end

function retry_until(
    f::Function,
    target::Union{ChannelOwner,Locator};
    timeout::MaybeTimeout = nothing,
    interval::Real = 100,
    on_timeout::Union{Symbol,Bool} = :throw,
    on_error::Symbol = :throw,
)
    return retry_loop(f, resolve_timeout(target, timeout), interval, on_timeout, on_error)
end

function retry_loop(
    f::Function,
    ms::Int,
    interval::Real,
    on_timeout::Union{Symbol,Bool},
    on_error::Symbol,
)
    check_knob(:on_timeout, on_timeout, ON_TIMEOUT_VALUES)
    check_knob(:on_error, on_error, ON_ERROR_VALUES)

    deadline = time() + ms / 1_000
    last_error = nothing
    while true
        held = try
            f() === true
        catch e
            on_error === :retry || rethrow()
            last_error = e
            false
        end
        held && return true

        if time() >= deadline
            on_timeout === false && return false
            throw(
                AssertionFailure(
                    timeout_message(ms, last_error);
                    name = "AssertionFailure",
                ),
            )
        end
        sleep(interval / 1_000)
    end
end

# Under on_error = :retry the exceptions are the only account of why the
# condition never held, so the last one rides along on the failure.
timeout_message(ms::Int, ::Nothing) = "condition never held within $(ms)ms"
timeout_message(ms::Int, e) =
    "condition never held within $(ms)ms; last error from the predicate: " *
    sprint(showerror, e)
