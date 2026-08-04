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
        spec = get(MATCHERS, name, nothing)
        spec === nothing && throw(
            ArgumentError(
                "unknown matcher `$name`. Available: " *
                join(sort!([":$k" for k in keys(MATCHERS)]), ", "),
            ),
        )
        expected, is_not = negated(raw)
        # `to_be_visible = false` reads as "assert it is not visible".
        if name in BOOLEAN_MATCHERS
            expected isa Bool ||
                throw(ArgumentError("`$name` takes true or false, got $(repr(expected))"))
            is_not = is_not ⊻ !expected
        end
        run_expect(loc, name, spec, expected, is_not, ms)
    end
    return loc
end

function run_expect(loc::Locator, name::Symbol, spec, expected, is_not::Bool, ms::Int)
    try
        _frame_expect(
            loc.frame;
            selector = loc.selector,
            expression = spec.expression,
            isNot = is_not,
            timeout = ms,
            spec.params(expected)...,
        )
    catch e
        e isa ExpectFailure || rethrow()
        throw(assertion_failure(e, loc, name, expected, is_not, ms))
    end
    return nothing
end

# SC 7: the message has to carry the expected *and* the received value, or the
# reader is back to re-running the test by hand to find out what was there.
function assertion_failure(
    e::ExpectFailure,
    loc::Locator,
    name::Symbol,
    expected,
    is_not::Bool,
    ms::Int,
)
    got = received_value(e)
    custom = custom_error_message(e)
    want = is_not ? "not $(repr(expected))" : repr(expected)

    lines = ["$name failed on locator($(repr(loc.selector)))", "  expected: $want"]
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

"""
    retry_until(f; timeout=nothing, interval=100) -> true

Call `f()` every `interval` ms until it returns `true`, or raise
[`AssertionFailure`](@ref) when `timeout` ms have passed.

The escape hatch for conditions [`expect`](@ref) cannot express. Prefer
`expect` where it fits — it retries *inside* the browser, so it neither
round-trips per attempt nor misses a state that flickers between polls:

```julia
retry_until(; timeout = 5_000) do
    length(console_messages(page)) >= 3
end
```

An exception from `f` propagates immediately rather than being retried: a
predicate that throws is a broken test, not a condition that has not happened
yet, and swallowing it would hide the bug until the timeout.

`timeout` defaults to [`DEFAULT_TIMEOUT`](@ref); there is no page here to
inherit a setting from.
"""
function retry_until(f::Function; timeout::MaybeTimeout = nothing, interval::Real = 100)
    ms = timeout === nothing ? DEFAULT_TIMEOUT : Int(timeout)
    deadline = time() + ms / 1_000
    while true
        f() === true && return true
        time() < deadline || throw(
            AssertionFailure(
                "condition never held within $(ms)ms";
                name = "AssertionFailure",
            ),
        )
        sleep(interval / 1_000)
    end
end
