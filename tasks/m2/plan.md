# Implementation Plan: Playwright.jl — Milestone 2 (codegen + API expansion)

Spec: [`SPEC-M2.md`](../SPEC-M2.md). Milestone 1's plan is archived at
[`tasks/m1/plan.md`](m1/plan.md).

## Context

Milestone 1 delivered a working vertical slice: driver bootstrap, transport,
connection/registry, and a hand-written 12-function API. Milestone 2 does two
things at once, and the ordering below exists to keep them from colliding:

1. **Make protocol coverage cheap** — generate a mechanical channel layer from
   Playwright's own protocol spec (`SPEC-M2.md` D1/D2), so adding a command stops
   being a hand-transcription exercise.
2. **Expand the API** until Bonnie.jl's e2e suite is expressible
   ([`bonnie_needs.md`](bonnie_needs.md)) — `evaluate`, frames, non-strict
   locators, `dispatch_event`, launch options, diagnostics.

The risk in combining them is a big-bang rewrite. The mitigation is **T4**: before
any new API is written, the existing milestone-1 surface is migrated onto the
generated layer with *zero* behaviour change, and the milestone-1 smoke suite is
the oracle. If codegen is the wrong shape, that is where it becomes obvious —
cheaply, with a green suite to revert to.

## Architecture Decisions

Recorded in full as D1–D7 (plus D4a/D4b from review) in `SPEC-M2.md`. The ones
that drive this plan's shape:

- **Two layers.** `src/generated/channels.jl` is mechanical and checked in;
  `src/api/*.jl` is hand-written, documented, idiomatic. The generator is never
  loaded at runtime and YAML never becomes a package dependency.
- **The spec is ~19 vendored yml files**, not one `protocol.yml`, and is absent
  from the npm tarball — so T1 (fetch + vendor) is a real task and a prerequisite
  for everything.
- **The `SerializedValue` codec is hand-written and hermetically testable.** It is
  the single largest correctness surface in the milestone and it needs no browser,
  so it runs in parallel with the codegen work rather than behind it.
- **Slices stay vertical.** T5–T9 each close one row of the `bonnie_needs.md`
  table end to end (protocol → API → docstring → smoke test), so partial delivery
  is still useful delivery.

## Dependency Graph

```
T1 vendor protocol spec + gen/ environment
 ├── T2 generator → src/generated/channels.jl (+ --check)        ┐
 │      └── T4 migrate milestone-1 API onto generated layer      │ T2 ∥ T3
 │             ├── T5 evaluate slice (codec ∘ channel layer)     │
 │             │      └── T7 frames slice                        │
 │             ├── T6 locator expansion + dispatch_event ────────┘
 │             ├── T8 launch options + explicit context lifecycle
 │             └── T9 diagnostics (console_messages, page_errors)
 └── T3 SerializedValue codec (hermetic, no browser)
            └── T5

T10 Bonnie-parity shim + docs + format   ← depends on all of T5–T9
```

Parallelizable: **T2 ∥ T3** (different files, no shared state). After T4,
**T5 ∥ T6 ∥ T8 ∥ T9** are independent slices touching different `src/api/` files;
T7 is the only one with an intra-phase dependency (it asserts through `evaluate`
and composes with locators).

Sequential and unavoidable: T1 → T2 → T4 → everything.

## Task List

### Phase 1: Foundation (no browser needed)

#### Task 1: Vendor the protocol spec + generator environment
**Description:** `gen/Project.toml` with YAML.jl and JuliaFormatter (both
version-pinned via `[compat]`, since formatter output must be reproducible);
`gen/fetch_spec.jl` downloads `packages/protocol/spec/*.yml` from
`microsoft/playwright` at tag `v$PLAYWRIGHT_VERSION` — read from `src/driver.jl`,
never re-typed — into `protocol/spec/`. Add `protocol/LICENSE-PLAYWRIGHT` (Apache
2.0) and a `protocol/README.md` saying the directory is vendored, at what version,
and how to refresh it.
**Acceptance criteria:**
- [ ] `julia --project=gen gen/fetch_spec.jl` populates `protocol/spec/` with all
      spec files for the pinned version; re-running is idempotent
- [ ] The fetched set includes `serialized.yml`, `frame.yml`, `page.yml`,
      `browserType.yml`, `browserContext.yml`, `mixins.yml`, `handles.yml`
- [ ] Fetching a version tag that does not exist fails with a clear message, not a
      partial directory
- [ ] Package tests still pass and `Project.toml` is unchanged
**Verification:** run the fetch script; `git status` shows only `protocol/` and
`gen/` additions; `julia --project=. -e 'using Pkg; Pkg.test()'`
**Dependencies:** none. **Files:** `gen/Project.toml`, `gen/fetch_spec.jl`,
`protocol/spec/*.yml`, `protocol/README.md`, `protocol/LICENSE-PLAYWRIGHT`. **Scope: S**

#### Task 2: The generator → `src/generated/channels.jl`
**Description:** `gen/generate.jl` parses the vendored spec and emits one file:
concrete `ChannelOwner` types for every protocol interface plus the
`CHANNEL_TYPES` registry, and one `_<interface>_<command>` function per command
with correctly-named required/optional parameters. Resolve `$mixin` inclusions;
map spec types to Julia (`string`→`AbstractString`, `float`/`int`→`Real`,
`boolean`→`Bool`, `binary`→`Vector{UInt8}`, `json`→`Any`, `Channel`→
`ChannelOwner`, enums→`AbstractString`); anything unrecognised maps to `Any` and
is reported in a summary the generator prints. Results containing channel refs are
resolved via `from_channel`. Output is formatted by the pinned JuliaFormatter and
carries a `# GENERATED` banner naming the source file and version. `--check` exits
non-zero when the checked-in output differs from a fresh generation.
**Acceptance criteria:**
- [ ] `julia --project=gen gen/generate.jl` writes `src/generated/channels.jl`;
      deleting it and regenerating reproduces it byte-for-byte
- [ ] `gen/generate.jl --check` exits 0 on a clean tree, non-zero after a
      one-character edit to the generated file
- [ ] The generated file loads (`using Playwright`) and defines the milestone-1
      types (`Browser`, `Page`, `Frame`, …) plus commands for at least `goto`,
      `title`, `click`, `fill`, `evaluateExpression`, `dispatchEvent`, `queryCount`
- [ ] Every spec type the generator could not map is listed in its output — the
      unmapped set is reviewed, not silently `Any`
- [ ] `src/objects.jl`'s hand-written type list is deleted in favour of the
      generated one, with `Locator`/`PlaywrightAPI` (not protocol objects) staying
      hand-written
**Verification:** `gen/generate.jl && gen/generate.jl --check`; `Pkg.test()` (unit,
hermetic); `test/test_codegen.jl` covers `--check` and generation from a small
hand-written fixture yml, and skips with a clear message when `gen/` is not
instantiated
**Dependencies:** T1. **Files:** `gen/generate.jl`, `src/generated/channels.jl`,
`src/objects.jl`, `src/Playwright.jl`, `test/test_codegen.jl`. **Scope: L**

#### Task 3: `SerializedValue` codec (`src/serializers.jl`)
**Description:** Hand-written, per `SPEC-M2.md` D3. `to_serialized(x)` →
`(value, handles)`; `from_serialized(v)` → Julia. Covers every row of the D3
table, nested arrays/objects, and circular references via the `id`/`ref`
bookkeeping. `JSHandle` arguments are hoisted into the `handles` array and
replaced with `{h: i}`. Unknown tags raise an informative error naming the tag.
**Acceptance criteria:**
- [ ] Round-trip for every D3 row, asserted in both directions
- [ ] Nested `Dict`/`Vector`/`NamedTuple` structures survive a round-trip
- [ ] A self-referential Julia structure serializes with `id`/`ref` rather than
      recursing forever, and a wire value using `ref` deserializes to a structure
      that is `===` at the shared node
- [ ] Numbers always deserialize to `Float64`; `evaluate`-style comparisons
      (`x == 7`) still hold
- [ ] `nothing` → `{v:"null"}`, `missing` → `{v:"undefined"}`, round-tripping
      distinctly
- [ ] An unknown tag raises an error whose message names the tag
**Verification:** `test/test_serializers.jl`, hermetic — no browser, no Node
**Dependencies:** T1 (reads `serialized.yml` for reference only; no code
dependency on T2). **Files:** `src/serializers.jl`, `src/Playwright.jl`,
`test/test_serializers.jl`. **Scope: M**

### Checkpoint A — after Tasks 1–3
- [ ] Hermetic `Pkg.test()` green with no Node, no browser, no `gen/` instantiated
- [ ] `gen/generate.jl --check` green
- [ ] **Human review of the generated code's shape before anything is built on it**
      — this is the cheapest moment to reject D1

### Phase 2: Migration, then vertical slices

#### Task 4: Migrate the milestone-1 API onto the generated layer
**Description:** Pure refactor, no new user-visible behaviour. Split `src/api.jl`
into `src/api/{lifecycle,navigation,locators,frames,evaluate,diagnostics}.jl`
(the last three initially near-empty), and rewrite every existing wrapper to call
the generated `_*` functions instead of building `Dict`s inline. Docstrings and
exported names move verbatim.
**Acceptance criteria:**
- [ ] No hand-built protocol params `Dict` remains in `src/api/`
- [ ] The milestone-1 smoke suite passes **unchanged** on Chromium and Firefox
- [ ] Exported name set is byte-identical to before (asserted by a test listing
      `names(Playwright)`)
- [ ] README's milestone-1 example still runs verbatim
**Verification:** `PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()'`
before and after, with no test file edits other than the new exports test
**Dependencies:** T2. **Files:** `src/api.jl` → `src/api/*.jl`,
`src/Playwright.jl`, `test/runtests.jl`. **Scope: M**

#### Task 5: `evaluate` slice — Bonnie blocker 1
**Description:** `evaluate(target, expression, arg=missing; is_function=nothing)`
for `Page`/`Frame`/`JSHandle`; `evaluate_handle` returning a `JSHandle`;
`evaluate_handle(f, target, …)` scoped form that disposes on exit including on
throw (D4b); `dispose(handle)`; `eval_on_selector` / `eval_on_selector_all`.
`is_function` auto-detection with an override (D5). Fixture page exposing values,
a function, and a throwing expression.
**Acceptance criteria:**
- [ ] `evaluate(page, "1 + 1") == 2` and `evaluate(page, "x => x.a * 2", (a=21,)) == 42`
- [ ] `evaluate(page, "document.title")` returns the fixture's title as a `String`
- [ ] Throwing JS raises a `PlaywrightError` carrying the JS message
- [ ] A `JSHandle` obtained from `evaluate_handle` can be passed back as `arg`
- [ ] The scoped form disposes on the normal path **and** when the body throws
      (asserted by a subsequent use of the handle failing)
- [ ] `eval_on_selector_all(page, "input", "els => els.length")` returns the count
**Verification:** `test/test_evaluate.jl` in the smoke suite, both browsers
**Dependencies:** T3, T4. **Files:** `src/api/evaluate.jl`, `src/objects.jl`,
`test/fixtures/evaluate.html`, `test/test_evaluate.jl`, `src/Playwright.jl`. **Scope: M**

#### Task 6: Locator expansion + `dispatch_event` — Bonnie blockers 3 and 4
**Description:** `strict=false` on `locator`; `count`, `nth` (1-based → 0-based on
the wire), `Base.first`/`Base.last`, and the iteration protocol —
`iterate`/`length`/`getindex`/`firstindex`/`lastindex`/`eltype`, no
`AbstractArray` subtyping (D4a). State/content queries: `inner_text`,
`inner_html`, `get_attribute`, `is_visible`, `is_checked`, `is_enabled`.
`dispatch_event(loc, type, event_init=missing)` built on the codec.
`test/fixtures/sliders.html` mirrors Bonnie's `embed_raw`: two
`input[type=range]` elements plus a live readout of their values.
**Acceptance criteria:**
- [ ] `count` returns 2 for the two sliders; `nth(loc, 2)` acts on the second
- [ ] `for x in loc` yields exactly `count(loc)` single-element locators, and
      `collect(loc)[2] === nth(loc, 2)` in behaviour (acts on the same element)
- [ ] Iterating a strict locator with one match yields one element and does not error
- [ ] `dispatch_event` sets a range input to an exact value (7) that
      `input_value` reads back, on Chromium **and** Firefox
- [ ] `inner_text` on `body` excludes hidden text that `text_content` includes
      (asserted against a fixture with a `display:none` element)
- [ ] Acting on a multi-match strict locator still raises `PlaywrightError`
**Verification:** smoke suite, both browsers
**Dependencies:** T4. **Files:** `src/api/locators.jl`, `src/objects.jl`,
`test/fixtures/sliders.html`, `test/test_smoke.jl`. **Scope: M**

#### Task 7: Frames slice — Bonnie blocker 2
**Description:** `frames(page)` (main frame plus descendants, tracked from the
`frameAttached`/`frameDetached` events already flowing through `dispatch`),
`frame_locator(page_or_frame, selector)`, `content_frame(frame_locator_or_locator)`,
`owner_frame`, `parent_frame`, `url(frame)`/`name(frame)`, and frame-scoped
`locator`. `test/fixtures/iframe.html` embeds a same-origin child with its own
interactive element — the case Bonnie's oxygen-template test needs and could not
express.
**Acceptance criteria:**
- [ ] `length(frames(page)) == 2` for the iframe fixture, main frame first
- [ ] An element inside the child frame can be clicked/filled via `frame_locator`
      and the effect observed via `evaluate` on `content_frame`
- [ ] `evaluate(content_frame(fl), "document.title")` returns the child's title,
      not the parent's
- [ ] `parent_frame` of the child is the main frame; `parent_frame(main_frame)` is
      `nothing`
- [ ] Frames detached at runtime disappear from `frames(page)`
**Verification:** `test/test_frames.jl` in the smoke suite, both browsers
**Dependencies:** T5, T6. **Files:** `src/api/frames.jl`, `src/objects.jl`,
`src/connection.jl`, `test/fixtures/iframe.html`, `test/fixtures/iframe-child.html`,
`test/test_frames.jl`. **Scope: M**

#### Task 8: Launch options + explicit context lifecycle
**Description:** Extend `launch` with `args`, `chromium_sandbox`, `env`,
`firefox_user_prefs`, `executable_path`, `channel`, `slow_mo`, `proxy`,
`downloads_path` — all optional, all omitted from the wire when unset (`env` is
a `Dict` converted to the protocol's `NameValue` array). Add `new_context(browser;
viewport, user_agent, …)`, `new_page(::BrowserContext)`, `close(::BrowserContext)`,
`contexts(browser)`, `pages(context)`. `new_page(::Browser)` keeps working but
records the context it created so `close(page)` disposes it (D7).
**Acceptance criteria:**
- [ ] `launch(pw.chromium; chromium_sandbox=false, args=["--disable-dev-shm-usage"])`
      succeeds and the args reach the browser (asserted via
      `evaluate(page, "navigator.userAgent")` or a flag-observable behaviour)
- [ ] `firefox_user_prefs=Dict("dom.max_script_run_time" => 20)` is accepted on the
      Firefox leg and observably applied
- [ ] Unset options appear nowhere in the outgoing params (asserted hermetically
      against a fake transport)
- [ ] Explicit `new_context`/`close(context)` round-trips; `contexts(browser)`
      shrinks after close
- [ ] After `close(page)` on a page from `new_page(browser)`, `contexts(browser)`
      is empty — the milestone-1 leak is gone
**Verification:** hermetic params test + smoke suite, both browsers
**Dependencies:** T4. **Files:** `src/api/lifecycle.jl`, `src/objects.jl`,
`test/test_smoke.jl`, `test/test_connection.jl`. **Scope: M**

#### Task 9: Diagnostics — console messages and page errors
**Description:** `console_messages(page)` and `page_errors(page)` over the 1.61
pull-based getters (D6), returning `Vector{ConsoleMessage}` /
`Vector{PageError}` — plain structs with `type`, `text`, `location`, and for
errors `message`, `name`, `stack`. `clear_console_messages(page)` /
`clear_page_errors(page)` for per-test isolation. Fixture that logs at several
levels and throws an uncaught error.
**Acceptance criteria:**
- [ ] A `console.log` on the fixture appears in `console_messages(page)` with
      `type == "log"` and the right text
- [ ] An uncaught JS exception appears in `page_errors(page)` with its message and
      a non-empty stack
- [ ] `clear_*` empties the respective list
- [ ] Both work on Chromium and Firefox (message text may differ; assert on
      substrings, not exact strings)
**Verification:** smoke suite, both browsers
**Dependencies:** T4. **Files:** `src/api/diagnostics.jl`, `src/objects.jl`,
`test/fixtures/noisy.html`, `test/test_smoke.jl`. **Scope: S**

### Checkpoint B — after Tasks 4–9
- [ ] The `SPEC-M2.md` target snippet runs verbatim against the fixtures
- [ ] Full smoke suite green on Chromium **and** Firefox
- [ ] Hermetic suite still green with no Node/browser
- [ ] Human review before docs/polish

### Phase 3: Parity proof and polish

#### Task 10: Bonnie-parity shim, docs, format
**Description:** Write the `with_page` / `evaluate` / `poll_js` shim equivalent to
Bonnie's `test/cdp.jl` in under 40 lines of public API, as a documented example
(and run it in the smoke suite so it cannot rot). Update README: API table,
Status section, milestone-2 example, a note that `executable_path`/`channel` exist
for `CHROME_BIN`-style provisioning. Docstring audit over every new export. Run
JuliaFormatter, with `src/generated/` excluded. Walk the `bonnie_needs.md` table
and record, row by row, where each is satisfied.
**Acceptance criteria:**
- [ ] The shim is < 40 lines, uses only exported API, and passes in the smoke suite
- [ ] Every new exported function has a docstring and ≥1 test
- [ ] Every row of the `bonnie_needs.md` table maps to a named public function
- [ ] `format(".")` is a no-op on a clean tree; `src/generated/` untouched by it
- [ ] All eight `SPEC-M2.md` success criteria verified and ticked
**Verification:** both test modes; fresh-clone run of the README example
**Dependencies:** T5–T9. **Files:** `README.md`, `docs/bonnie-parity.md`,
`test/test_parity.jl`, `src/api/*.jl`, `.JuliaFormatter.toml`. **Scope: M**

### Checkpoint C — complete
- [ ] All eight `SPEC-M2.md` success criteria verified and demonstrated

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| The generator turns out to be the wrong abstraction, discovered after the API is built on it | **High** | T4 migrates the *existing* API first with the milestone-1 smoke suite as oracle, and Checkpoint A gates on human review of generated output. Rejecting D1 costs T1–T2, not the milestone |
| Spec yml has constructs the generator mishandles (`$mixin`, recursive `SerializedValue`, enums, `binary`/`json`) | Med | Generator reports every unmapped type instead of silently emitting `Any`; T2 acceptance requires reviewing that list. Only the commands we wrap need to be right |
| Generated output not byte-reproducible (JuliaFormatter version drift) | Med | Formatter pinned in `gen/[compat]`; `--check` in the test suite catches drift the moment it appears |
| Codec circular-reference handling (`id`/`ref`) is subtle and easy to get wrong | Med | Hermetic and cheap to test exhaustively (T3), which is why it is a standalone task ahead of any browser work |
| `iterate` semantics surprise users when the DOM mutates mid-loop | Med | Documented explicitly on `iterate` (D4a); the sampling behaviour is asserted in a test so it is a contract, not an accident |
| Firefox differs on `dispatch_event` for range inputs, or on console/error text | Med | Both are matrix dimensions from the start (T6, T9 acceptance names both browsers); assert on substrings, not exact strings |
| Vendoring ~19 Microsoft yml files raises licensing/noise concerns | Low | Apache-2.0, vendored under `protocol/` with its own LICENSE and a README stating provenance; refreshable by one script |
| Scope creep from "expand the API" into WebKit/events/routing | Low | `SPEC-M2.md` Non-Goals is explicit; every task traces to a `bonnie_needs.md` row |

## Notes

- Milestone-1 plan and todo are preserved under `tasks/m1/`.
- Task scope key: **S** ≈ under an hour, **M** ≈ a focused session, **L** ≈ more
  than one session (only T2).
