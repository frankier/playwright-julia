# Assertions

[`expect`](@ref) is the assertion you should reach for by default. It retries
the condition in the browser until it holds or the timeout runs out, and
returns its target so calls chain.

```julia
expect(locator(page, "h1"); to_have_text = "Hello")
```

The difference from an ordinary `@test` is not stylistic. `@test
text_content(loc) == "Hello"` reads the DOM once, at whatever moment the
previous line happened to finish, and fails if the page was a few milliseconds
behind. The same assertion written with `expect` passes as soon as the text
arrives, and only fails if it never does.

## Matchers

Pass one or more as keyword arguments:

```julia
expect(locator(page, "h1");    to_have_text = "Hello")
expect(locator(page, "li"; strict = false); to_have_count = 3)
expect(locator(page, "#box");  to_have_value = r"^se")
expect(locator(page, "#link"); to_have_attribute = "href" => "/somewhere")
expect(locator(page, "#gone"); to_be_visible = false)
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

Several matchers in one call are checked one after another and the first
failure raises. `timeout` applies to **each** matcher, since each is its own
retrying check.

## Negation

Wrap any expectation in [`Not`](@ref):

```julia
expect(locator(page, "h1"); to_have_text = Not("Goodbye"))
```

For the boolean matchers, `= false` says the same thing more readably —
`to_be_visible = false` rather than `to_be_visible = Not(true)`.

## Asserting about the document

Hand `expect` a [`Page`](@ref) or a [`Frame`](@ref) and it asserts about the
document instead:

```julia
expect(page; to_have_title = "Checkout")
expect(page; to_have_url = r"/checkout\$")
```

Matchers are partitioned by target, so `to_have_text` on a `Page` — or
`to_have_title` on a `Locator` — raises an `ArgumentError` naming the matcher
that *does* work. That is worth more than it sounds: a driver-side failure from
a mismatched matcher looks exactly like a real assertion failure, and would
cost an afternoon.

## Failures name both values

```
to_have_text failed on locator("h1")
  expected: "Goodbye"
  received: "Hello"
  (gave up after 5000ms of retrying)
```

The received value is in the message, so a red CI run does not need to be
reproduced locally to find out what was actually on the page. The exception
type is [`AssertionFailure`](@ref).

## Inside a `@testset`

`expect` raises rather than returning a `Bool`, which is what makes retrying
possible — there is no value to return until the condition settles. Inside a
testset it therefore registers as an `Error` rather than a `Fail`.

That is usually fine, and the message is the same either way. When the
distinction matters — a summary that should read "1 failed" rather than
"1 errored" — [`retry_until`](@ref) with `on_timeout = :false` gives you a
`Bool` to put inside `@test`:

```julia
@test retry_until(page; on_timeout = :false) do
    length(console_messages(page)) >= 3
end
```

## When `expect` does not fit

`retry_until` is the escape hatch for conditions no matcher expresses — see
[Waiting](@ref), which covers it in full. Prefer `expect` where it fits: it
re-checks inside the browser, so it neither round-trips per attempt nor misses
a state that flickers between polls.

## A worked example

From `examples/http_jl.jl`, which asserts about a page that mutates itself 300
milliseconds after a click:

```julia
# Nothing has been greeted yet. `to_have_count = 0` is a real assertion about
# absence, not a missing element swallowed.
expect(locator(page, "li.greeting"; strict = false); to_have_count = 0)

fill(locator(page, "#name"), "Ada")
expect(locator(page, "#name"); to_have_value = "Ada")
click(locator(page, "#greet"))

# The 300ms delay is handled by expect's retry, not by a sleep on this side.
expect(locator(page, "li.greeting"); to_have_text = "Hello, Ada!")
expect(locator(page, "li.greeting"; strict = false); to_have_count = 1)

# Once it has settled, a plain read is the natural thing to `@test`.
@test text_content(locator(page, "li.greeting")) == "Hello, Ada!"
```

The last two lines are the pattern worth taking away: **`expect` to settle,
`@test` to check**. Reads never wait, assertions always do, and using each for
its own job removes the temptation to sleep.
