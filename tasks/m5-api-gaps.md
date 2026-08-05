# API gaps found while writing the M5 documentation

`SPEC-M5.md` Assumption 2 and SC 16: writing ~90 docstrings is the best API
review this package will get, because a docstring that has to apologise for its
subject is a design report. **Nothing here has been fixed.** Every item is a
change to the public surface, and M5 is a documentation milestone — fixing them
would be an API milestone wearing M5's clothes, and several of them are
breaking.

Recorded 2026-08-05, while writing T9's docstrings and T4–T6's examples.
Ordered by how likely a user is to trip over it.

---

## 1. `fill` is not exported, and neither are `count`, `first`, `last`, `close`

`fill(loc, value)` extends `Base.fill`, so it works unqualified — but only
because `Base` is in scope, not because Playwright.jl exported it. The same is
true of `count`, `first`, `last`, `length`, `iterate` and `close`.

Three consequences, in increasing order of seriousness:

- **It is invisible to `names(Playwright)`**, so `checkdocs = :exports` — the
  gate T10 turns on — cannot see these docstrings at all. The most-used verb in
  the package (`fill`) is outside the gate that is supposed to guarantee the
  package is documented.
- **It cannot be listed in `api.md` the same way as its neighbours.** The API
  reference has to reach for `Base.fill` while everything around it is a bare
  name.
- **A reader cannot tell.** Writing the HTTP.jl example I wrote
  `Playwright.fill(...)`, got a method error, and only then worked out that the
  unqualified call was the right one. The docstring now says so explicitly,
  which is a docstring compensating for a surprise.

Why it is the way it is: extending a `Base` function and then exporting the name
would make `using Playwright` shadow `Base.fill` for the whole session, which is
worse. There is no good answer inside Julia's export model — but "the docs
explain the workaround" is not the answer either.

## 2. `is_visible` takes no `timeout`; `is_checked` and `is_enabled` do

```julia
is_visible(loc::Locator)                              # locators.jl:207
is_checked(loc::Locator; timeout = nothing)           # locators.jl:223
is_enabled(loc::Locator; timeout = nothing)           # locators.jl:242
```

Three sibling predicates, documented side by side, one of which silently has a
different signature. The reason is real — `is_visible` returns `false` for a
missing element rather than waiting, which is what makes it safe to ask about
things that may not exist — but the reason is invisible at the call site, and a
`timeout` passed to it is a `MethodError` rather than a no-op.

## 3. The artifact family disagrees about what it returns

| Call | Returns |
|---|---|
| `screenshot(page; path = …)` | the **bytes**, and writes the file as a side effect |
| `pdf(page; path = …)` | the **bytes**, same |
| `stop_tracing(ctx; path = …)` | the **path** |
| `save_as(artifact, path)` | the **path** |

Two conventions in one family of four. Worse, `path` is a keyword in three of
them and positional in `save_as`. Writing them up meant writing "returns its
bytes" and "returns `path`, so it composes" two paragraphs apart and hoping the
reader notices.

## 4. `name` is a very generic export for a very specific thing

`name(frame)` is an iframe's HTML `name` attribute. `browser_name(x)` is the
engine. A user who types `name(browser)` gets a `MethodError`, and a user who
has `using Playwright` in a script has taken the name `name` for something quite
narrow. `frame_name` would cost nothing and collide with nothing.

## 5. `retry_until` puts its target second, everything else puts it first

```julia
retry_until(f; timeout)               # no target
retry_until(f, target; timeout)       # target second
expect(loc; …)                        # target first
click(loc; …)                         # target first
```

The `f`-first order is forced by do-block syntax, so this is not obviously
fixable — but it does mean the one function whose whole job is "wait for
something on this object" is the one that takes the object in an unusual place.

## 6. Two ways to get an element, differing only in whether they wait

`element_handle(loc)` resolves now and returns `nothing` if there is no match.
`wait_for_selector(page, sel)` waits and raises. Both return an
`ElementHandle`. The difference is entirely in the documentation — nothing in
either name says "this one waits". `element_handle(loc; timeout)` returning the
waiting behaviour, or a `wait` keyword, would collapse two concepts into one.

## 7. Strictness has no cascade, but timeouts do

`set_default_timeout!` cascades frame → page → context, so a suite sets it once.
Strictness is a per-`locator` keyword with no equivalent, so a suite that works
with lists writes `strict = false` on every single call — the Oxygen and Genie
examples say it four times between them. `set_default_strict!` would follow a
pattern the package already has.

## 8. `evaluate` means three different things depending on argument 1

`evaluate(page, expr)` runs in the page. `evaluate(loc, expr)` passes the
matched element as the first argument to `expr`. `evaluate(handle, expr)` does
the same for a handle. The middle one is the surprise: the expression's
signature changes from `() => …` to `(el) => …` based on the type of an
argument that is not the expression. It is Playwright's own design, inherited
faithfully, and it is still the thing most likely to produce a confusing
`undefined`.

## 9. `sources = true` raises rather than being unavailable

`start_tracing(ctx; sources = true)` throws `ArgumentError`. That is the right
call — better than silently ignoring it — but it means the signature advertises
a parameter that has exactly one legal value. A keyword that can only be `false`
is a keyword that should not be in the signature.

---

## Not gaps, though they looked like it

- **`retry_until`'s `on_timeout = :false`** reads oddly next to `:throw`, but it
  is what lets a check sit inside `@test` and produce a `Fail` instead of an
  `Error`. It earns its strangeness.
- **`expect` raising rather than returning `Bool`** is what makes it retry.
  Deliberate, documented, and correct.
- **`with_page`, `with_tracing`, `with_events` all taking `f` first** is
  Julia's do-block convention and needs no defence.
