# URL matchers: Playwright's glob dialect, and the three-way matcher union.
#
# Everything here is pure. No driver, no browser, no connection.
#
# The dialect is not invented. It is a port of `globToRegexPattern` in
# playwright-core 1.61.1 (`lib/coreBundle.js`), read out of the pinned driver
# rather than remembered, because "* does not cross / but ** does" is the kind
# of rule that passes six hand-written tests and fails on the seventh real URL.
#
# Matchers are evaluated *client-side*. The driver only ever receives the
# union of the live registrations' globs, because `setNetworkInterceptionPatterns`
# replaces the whole pattern set and so cannot express per-handler filtering
# once there are two handlers.

# Exactly playwright-core's `escapedChars`. Note what is in it: `?`, `[` and `]`
# are escaped, i.e. they are **literals**, not wildcards. See `glob_to_regex`.
const GLOB_ESCAPED_CHARS =
    Set{Char}(['$', '^', '+', '.', '*', '(', ')', '|', '\\', '?', '{', '}', '[', ']'])

"""
    glob_to_regex(glob::AbstractString) -> Regex

Compile a URL glob in Playwright's dialect to a `Regex` anchored at both ends.

| Token | Matches |
|---|---|
| `*` | any run of characters **except `/`** |
| `**` | any run of characters, `/` included |
| `{a,b}` | either alternative |
| `\\x` | a literal `x`, whatever `x` is |
| anything else | itself, literally |

```jldoctest
julia> using Playwright: glob_to_regex

julia> occursin(glob_to_regex("**/api/*.json"), "https://x.test/v2/api/items.json")
true

julia> occursin(glob_to_regex("**/api/*.json"), "https://x.test/api/deep/items.json")
false
```

The second case is the whole point of the distinction: `*` stopped at the `/`.

!!! warning "`?` is a literal, not a wildcard"
    This surprises people who bring shell-glob habits, and it is deliberate
    upstream: URLs are full of query strings, so `**/items?page=2` matches a
    literal `?`. There is no single-character wildcard in this dialect. Use a
    `Regex` matcher when you need one.

    (`[` and `]` are literals too — the dialect has no character classes.)

A malformed group raises `ArgumentError` rather than compiling to something
that quietly matches the wrong thing: `{` cannot nest, and both braces must be
matched.

See the network guide for the full case table. [`route!`](@ref) is the main
consumer of this.
"""
function glob_to_regex(glob::AbstractString)
    return Regex(glob_to_regex_pattern(glob))
end

"The pattern string behind [`glob_to_regex`](@ref), split out so tests can read it."
function glob_to_regex_pattern(glob::AbstractString)
    chars = collect(glob)
    n = length(chars)
    tokens = String["^"]
    in_group = false
    i = 1
    while i <= n
        c = chars[i]

        # A backslash escapes the next character, always.
        if c == '\\' && i < n
            i += 1
            nxt = chars[i]
            push!(tokens, nxt in GLOB_ESCAPED_CHARS ? string('\\', nxt) : string(nxt))
            i += 1
            continue
        end

        if c == '*'
            # Read before consuming the run: `**` is only "deep" in context.
            char_before = i > 1 ? chars[i-1] : nothing
            star_count = 1
            while i < n && chars[i+1] == '*'
                star_count += 1
                i += 1
            end
            if star_count > 1
                char_after = i < n ? chars[i+1] : nothing
                if char_after == '/'
                    # `/**/` may match zero segments — `a/**/b` matches `a/b`.
                    # That is why the leading-slash case is `((.+/)|)` and not
                    # simply `(.*/)`, which would demand at least the slash.
                    push!(tokens, char_before == '/' ? "((.+/)|)" : "(.*/)")
                    i += 1                     # the `/` is part of the token
                else
                    push!(tokens, "(.*)")
                end
            else
                push!(tokens, "([^/]*)")
            end
            i += 1
            continue
        end

        if c == '{'
            in_group && throw(
                ArgumentError("invalid glob $(repr(glob)): nested `{` is not supported"),
            )
            in_group = true
            push!(tokens, "(")
        elseif c == '}'
            in_group || throw(ArgumentError("invalid glob $(repr(glob)): unmatched `}`"))
            in_group = false
            push!(tokens, ")")
        elseif c == ','
            # A comma only alternates inside a group; elsewhere it is a comma,
            # and commas are legal in URLs.
            push!(tokens, in_group ? "|" : "\\,")
        else
            push!(tokens, c in GLOB_ESCAPED_CHARS ? string('\\', c) : string(c))
        end
        i += 1
    end
    in_group && throw(ArgumentError("invalid glob $(repr(glob)): unmatched `{`"))
    push!(tokens, "\$")
    return join(tokens)
end

# --- Base-URL resolution ---------------------------------------------------

"Schemes Playwright leaves alone rather than resolving against a base URL."
const GLOB_OPAQUE_SCHEMES = ("about:", "data:", "chrome:", "edge:", "file:")

const GLOB_HAS_SCHEME = r"^[a-zA-Z][a-zA-Z0-9+.\-]*://"

"""
    resolve_glob_base(base_url, glob) -> String

Resolve a scheme-less `glob` against `base_url`, the way Playwright does, so
that a `"/api/*"` route registered on a context with
`base_url = "http://127.0.0.1:8000"` intercepts that origin rather than nothing.

Left alone: a glob starting with `*` (it is already origin-agnostic), one with
its own scheme, and the opaque schemes (`about:`, `data:`, …). `base_url` of
`nothing` or `""` is a no-op.

Upstream also normalises dot segments and lower-cases the origin through a real
URL parser. This does neither, because the package depends on no URL library.
It joins origin and path and leaves the rest. The cases it does not cover
resolve to themselves rather than to something subtly different.
"""
function resolve_glob_base(base_url, glob::AbstractString)
    (base_url === nothing || isempty(base_url)) && return String(glob)
    startswith(glob, "*") && return String(glob)
    any(s -> startswith(glob, s), GLOB_OPAQUE_SCHEMES) && return String(glob)
    occursin(GLOB_HAS_SCHEME, glob) && return String(glob)

    base = String(base_url)
    m = match(GLOB_HAS_SCHEME, base)
    m === nothing && return String(glob)

    rest = base[(m.match.offset+length(m.match)+1):end]  # after "scheme://"
    slash = findfirst('/', rest)
    origin = slash === nothing ? base : base[1:(m.match.offset+length(m.match)+slash-1)]
    base_path = slash === nothing ? "/" : rest[slash:end]

    if startswith(glob, "/")
        return origin * glob
    end
    dir = base_path[1:something(findlast('/', base_path), 1)]
    return origin * dir * glob
end

# --- The matcher union ------------------------------------------------

"""
    UrlMatcher

What route registration and the network events accept: an `AbstractString`
glob, a `Regex`, or a `url -> Bool` predicate.
"""
const UrlMatcher = Union{AbstractString,Regex,Function}

"""
    matches(matcher, url; base_url = nothing) -> Bool

Whether `url` satisfies `matcher`. Internal — it is the dispatcher's mechanism,
not something a caller needs, since route registration takes the matcher itself.

A glob is compiled and anchored (see [`glob_to_regex`](@ref)); a `Regex` is an
unanchored `occursin`, matching Playwright, so `r"/api/"` matches mid-URL; a
`Function` is called with the URL string and must return `Bool`.
"""
matches(matcher::AbstractString, url::AbstractString; base_url = nothing) =
    occursin(glob_to_regex(resolve_glob_base(base_url, matcher)), url)

matches(matcher::Regex, url::AbstractString; base_url = nothing) = occursin(matcher, url)

function matches(matcher::Function, url::AbstractString; base_url = nothing)
    result = matcher(url)
    result isa Bool || throw(
        ArgumentError(
            "a predicate matcher must return Bool, got $(typeof(result)). " *
            "It is called with the request URL as a String.",
        ),
    )
    return result
end

"""
    driver_pattern(matcher) -> String

The glob this matcher contributes to the union sent to the driver.

A `Regex` or a predicate cannot be expressed as a driver glob, so either one
widens the union to `"**/*"` — every request is then delivered to the client
and filtered here. That is a real cost, and it is why a glob matcher is worth
preferring when one will do.
"""
driver_pattern(matcher::AbstractString) = String(matcher)
driver_pattern(::Regex) = "**/*"
driver_pattern(::Function) = "**/*"

# --- The shared case table -------------------------------------------------

"""
    GLOB_CASES

The glob dialect's behaviour, as data. Both `test/test_globs.jl` and
`docs/src/guide/network.md` read it, so the tests and the documented case table
cannot disagree.

Each entry is `(glob, url, matches, note)`.
"""
const GLOB_CASES = [
    (
        glob = "**/*.json",
        url = "https://x.test/a/b/items.json",
        matches = true,
        note = "`**` crosses `/`, so any depth matches",
    ),
    (
        glob = "*.json",
        url = "https://x.test/items.json",
        matches = false,
        note = "the glob is anchored: it must match the *whole* URL, scheme included",
    ),
    (
        glob = "**/api/*",
        url = "https://x.test/v2/api/items",
        matches = true,
        note = "`*` matches one segment",
    ),
    (
        glob = "**/api/*",
        url = "https://x.test/v2/api/deep/items",
        matches = false,
        note = "`*` stops at `/` — this is the rule most often got wrong",
    ),
    (
        glob = "**/api/**",
        url = "https://x.test/v2/api/deep/items",
        matches = true,
        note = "`**` does cross `/`",
    ),
    (
        glob = "https://x.test/a/**/z",
        url = "https://x.test/a/z",
        matches = true,
        note = "`/**/` matches zero segments as well as many",
    ),
    (
        glob = "**/*.{png,jpg}",
        url = "https://x.test/img/logo.png",
        matches = true,
        note = "`{a,b}` alternates",
    ),
    (
        glob = "**/*.{png,jpg}",
        url = "https://x.test/img/logo.gif",
        matches = false,
        note = "...and only over what it lists",
    ),
    (
        glob = "**/items?page=2",
        url = "https://x.test/items?page=2",
        matches = true,
        note = "`?` is a **literal**, not a single-character wildcard",
    ),
    (
        glob = "**/items?page=2",
        url = "https://x.test/itemsXpage=2",
        matches = false,
        note = "...so it does not match an arbitrary character",
    ),
    (
        glob = "**/a.b",
        url = "https://x.test/a.b",
        matches = true,
        note = "`.` is escaped, so it is a dot",
    ),
    (
        glob = "**/a.b",
        url = "https://x.test/axb",
        matches = false,
        note = "...and not the regex `.`",
    ),
    (
        glob = "**/x+y",
        url = "https://x.test/x+y",
        matches = true,
        note = "`+` is escaped too — regex metacharacters are literals",
    ),
    (
        glob = "**/c[1]",
        url = "https://x.test/c[1]",
        matches = true,
        note = "`[` and `]` are literals: the dialect has no character classes",
    ),
]
