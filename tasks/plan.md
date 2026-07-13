# Implementation Plan: Playwright.jl — Milestone 1 (minimal vertical slice)

## Context

The repo contains only `SPEC.md`. Goal: a pure-Julia package that drives real browsers
through the official Playwright Node driver — spawn the driver subprocess, speak its
length-prefixed JSON protocol over stdin/stdout, and expose a snake_case sync API
(`launch`, `new_page`, `goto`, `click`, `fill`, `text_content`, `screenshot`, …).
Success = the SPEC's README snippet runs verbatim on a clean machine, with driver and
browsers auto-downloaded on first use.

**Decisions confirmed with user:** Chromium **and Firefox** both in milestone 1;
**JSON.jl** for (de)serialization.

## Architecture Decisions

- **Driver hosting (SPEC open question 1): lazy download via Scratch.jl + Downloads.jl**,
  not `Artifacts.toml`. Upstream ships platform zips at
  `https://playwright.azureedge.net/builds/driver/playwright-<ver>-<platform>.zip`
  (platforms: `linux`, `linux-arm64`, `mac`, `mac-arm64`, `win32_x64`); Artifacts require
  stable gzipped tarballs we'd have to repackage and host. Pinned version lives in one
  const in `src/driver.jl`. Browsers installed via the driver's own
  `node cli.js install chromium firefox` into the standard Playwright cache dir.
- **Protocol layering** (mirrors playwright-python): `transport.jl` knows only bytes and
  framing (4-byte little-endian length prefix + UTF-8 JSON); `connection.jl` owns message
  ids, request/reply matching, the guid → ChannelOwner registry driven by `__create__` /
  `__dispose__` events, and error surfacing (`PlaywrightError`); `objects.jl` defines the
  typed wrappers; `api.jl` is protocol-free user surface. Wire names stay camelCase in
  `Dict`s; Julia surface is snake_case.
- **Sync-over-async:** transport read loop runs in a `Task`; each user call `put!`s a
  request and blocks on a per-message-id `Channel` for the reply.
- **Naming (SPEC open questions 2–3):** snake_case of upstream names (`new_page`,
  `text_content`); `pw.chromium` / `pw.firefox` as fields on an immutable struct.
- **Locators** are lazy selector holders (like upstream): a `Locator` stores
  `(frame, selector)` and each action sends a frame method with the selector — no
  element resolution client-side.

## Dependency Graph

```
T1 package skeleton
 ├── T2 driver.jl (download/locate/install)          [needs nothing from protocol]
 └── T3 transport.jl (framing)
        └── T4 connection.jl (dispatch, registry, errors)
               └── T5 bootstrap: spawn driver + handshake + playwright() wrapper
                      └── T6 launch → new_page → goto → title → close   ← first browser slice
                             ├── T7 locators: text_content, click, fill
                             └── T8 screenshot + error surfacing
                                    └── T9 shutdown hardening + Firefox smoke matrix
                                           └── T10 README + install UX polish
```

T2 and T3/T4 are independent → parallelizable. T6–T8 are vertical slices, each delivering
user-visible working functionality end to end.

## Task List

### Phase 1: Foundation (no browser needed)

#### Task 1: Package skeleton
**Description:** `Project.toml` (deps: JSON, Scratch, Downloads; test extras: Test, HTTP),
`src/Playwright.jl` module root with exports stubbed, `test/runtests.jl` that runs an
empty `@testset`, smoke tests gated behind `PLAYWRIGHT_JL_SMOKE=1` from day one.
**Acceptance criteria:**
- [ ] `Pkg.instantiate()` and `Pkg.test()` pass on a machine with no Node/browser
- [ ] `using Playwright` loads cleanly
**Verification:** `julia --project=. -e 'using Pkg; Pkg.test()'`
**Dependencies:** None. **Files:** `Project.toml`, `src/Playwright.jl`, `test/runtests.jl`. **Scope: S**

#### Task 2: Driver download, locate, install (`src/driver.jl`)
**Description:** Pin Playwright version in one const; map `Sys` info to platform string;
download+unzip driver into a Scratch space with progress output; `Playwright.install()`
also runs the driver's `install chromium firefox`. Provide `driver_cmd()` returning the
`Cmd` for `run-driver`. Respect `PLAYWRIGHT_BROWSERS_PATH` if set.
**Acceptance criteria:**
- [ ] `Playwright.install()` on a clean machine downloads driver + Chromium + Firefox with progress output, no manual steps
- [ ] Second call is a no-op (cached); version bump re-downloads
- [ ] `run(driver_version_cmd())` prints the pinned version
**Verification:** unit tests for platform-string mapping + URL construction (hermetic);
manual: `julia --project=. -e 'using Playwright; Playwright.install()'`
**Dependencies:** T1. **Files:** `src/driver.jl`, `test/test_driver.jl`. **Scope: M**

#### Task 3: Length-prefixed JSON transport (`src/transport.jl`)
**Description:** `Transport` over generic `IO`: write = 4-byte LE UInt32 length + UTF-8
JSON; read loop parses frames and invokes a message callback; handles partial reads and
EOF (driver crash) by signaling closure.
**Acceptance criteria:**
- [ ] Round-trip: messages written then read back byte-identically via an in-memory pipe
- [ ] Partial-read test: frame delivered one byte at a time still parses
- [ ] EOF mid-frame surfaces a clean "transport closed" state, not a hang
**Verification:** `Pkg.test()` unit tests, no browser
**Dependencies:** T1. **Files:** `src/transport.jl`, `test/test_transport.jl`. **Scope: S**

#### Task 4: Connection & object registry (`src/connection.jl`)
**Description:** Message-id assignment; blocking `send_message` with per-id reply
channels; dispatch of `__create__`/`__dispose__` maintaining guid → object registry with
a type-name → constructor table; event routing to objects; `PlaywrightError <: Exception`
built from protocol `error` payloads (message + log). `from_channel` helper to resolve
`{"guid": …}` references in results.
**Acceptance criteria:**
- [ ] Canned-trace unit tests: a scripted sequence of `__create__`, reply, error-reply, and `__dispose__` messages produces the right registry state and return values
- [ ] Error reply raises `PlaywrightError` carrying the driver's message
- [ ] Reply to an unknown id / message after close does not crash the read loop
**Verification:** `Pkg.test()` unit tests against canned traces (fake transport), no browser
**Dependencies:** T3. **Files:** `src/connection.jl`, `test/test_connection.jl`. **Scope: M**

### Checkpoint A — after Tasks 1–4
- [ ] `Pkg.test()` fully green on a machine with **no** Node/browser (success criterion 1)
- [ ] Human review of the protocol-layer API before building on it

### Phase 2: Vertical slices against a real browser

#### Task 5: Bootstrap handshake + `playwright() do ... end`
**Description:** Spawn `driver_cmd()` with piped stdio, wire it to Transport/Connection,
send `initialize`, receive the root `Playwright` object exposing `.chromium` /
`.firefox` (`BrowserType`s). `playwright(f)` guarantees driver shutdown (try/finally:
close connection, kill+wait process). Auto-install driver on first use if missing.
**Acceptance criteria:**
- [ ] `playwright() do pw; @assert pw.chromium isa BrowserType; end` passes
- [ ] After the block returns, the node process has exited (no orphans)
**Verification:** first smoke test (`PLAYWRIGHT_JL_SMOKE=1`); unit tests still hermetic
**Dependencies:** T2, T4. **Files:** `src/driver.jl`, `src/objects.jl`, `src/api.jl`, `test/test_smoke.jl`. **Scope: M**

#### Task 6: First browser slice — launch, new_page, goto, title, close
**Description:** `launch(::BrowserType; headless=true)` → `Browser`;
`new_page(::Browser)` (creates context + page); `goto(page, url; timeout, wait_until)`;
`title(page)`; `Base.close` for Browser/Page. Plus the test fixture harness: static
pages in `test/fixtures/` served by an in-process HTTP.jl server (test-only dep).
**Acceptance criteria:**
- [ ] Smoke test: launch headless Chromium, goto local fixture, `title(page)` returns the fixture's title, close cleanly
- [ ] `goto` returns a `Response`-ish object or `nothing`; bad URL raises `PlaywrightError`
**Verification:** `PLAYWRIGHT_JL_SMOKE=1 julia --project=. -e 'using Pkg; Pkg.test()'`
**Dependencies:** T5. **Files:** `src/objects.jl`, `src/api.jl`, `test/fixtures/*.html`, `test/test_smoke.jl`. **Scope: M**

#### Task 7: Locator slice — locator, text_content, click, fill
**Description:** `locator(page, selector)` returning lazy `Locator`; `text_content`,
`click`, `fill` sending the corresponding frame methods with the stored selector.
Fixture page has a button that mutates the DOM on click and a text input, so effects
are observable.
**Acceptance criteria:**
- [ ] Smoke: `text_content(locator(page, "h1"))` matches fixture text
- [ ] Smoke: `click` produces an observable DOM change readable via `text_content`
- [ ] Smoke: `fill` then reading the input's value round-trips
**Verification:** smoke suite; timeout on a non-existent selector raises `PlaywrightError`
**Dependencies:** T6. **Files:** `src/objects.jl`, `src/api.jl`, fixtures, `test/test_smoke.jl`. **Scope: M**

#### Task 8: screenshot + error-path coverage
**Description:** `screenshot(page; path=…)` (decode base64 result, write file);
tighten error surfacing so protocol errors anywhere in the slice raise `PlaywrightError`
with the driver's log attached.
**Acceptance criteria:**
- [ ] Smoke: screenshot produces a non-empty PNG (check magic bytes)
- [ ] Deliberate failure (bad selector with short timeout) raises `PlaywrightError` whose message includes the driver's explanation
**Verification:** smoke suite
**Dependencies:** T6. **Files:** `src/api.jl`, `test/test_smoke.jl`. **Scope: S**

### Checkpoint B — after Tasks 5–8
- [ ] Full SPEC snippet (Chromium) runs end to end
- [ ] Unit suite still green without browser; smoke suite green with `PLAYWRIGHT_JL_SMOKE=1`
- [ ] Human review before hardening/polish

### Phase 3: Hardening & polish

#### Task 9: Clean shutdown + Firefox matrix
**Description:** Harden `playwright()` teardown (finalizers as backstop, process-tree
wait); parameterize the smoke suite over `[chromium, firefox]`.
**Acceptance criteria:**
- [ ] After smoke suite, no orphan node/browser processes (test asserts on process exit)
- [ ] Whole smoke matrix passes on Firefox as well as Chromium (success criterion 2)
**Verification:** smoke suite ×2 browsers; `pgrep`-style check inside the test
**Dependencies:** T7, T8. **Files:** `src/api.jl`, `src/connection.jl`, `test/test_smoke.jl`. **Scope: M**

#### Task 10: README + first-use UX
**Description:** README with the SPEC example verbatim (example.com allowed there);
ensure first `launch` without prior `install()` triggers driver download with a clear
progress message; docstrings on every exported function; run JuliaFormatter.
**Acceptance criteria:**
- [ ] README example runs verbatim from a fresh clone (success criterion 4)
- [ ] Every exported function has a docstring and is exercised by ≥1 smoke test
**Verification:** delete scratch dir, run README example fresh; `Pkg.test()` both modes
**Dependencies:** T9. **Files:** `README.md`, `src/*.jl`. **Scope: S**

### Checkpoint C — complete
- [ ] All five SPEC success criteria verified and demonstrated

## Risks and Mitigations

| Risk | Impact | Mitigation |
|------|--------|------------|
| Protocol details drift by Playwright version (handshake shape, `__create__` initializers) | High | Pin one version; T5 is deliberately early and tiny so surprises hit at the checkpoint, not mid-API |
| `initialize` may reject unknown `sdkLanguage` values | Med | Send a supported value (`"javascript"`/`"python"`) at first; revisit later |
| Azure CDN URL scheme changes / download flakiness | Med | Isolated entirely in `driver.jl` (per SPEC open question 1); retry + clear error message |
| Sync-over-async deadlocks (reply never arrives after driver crash) | Med | T3/T4 EOF handling fails all pending calls with `PlaywrightError`; unit-tested with canned traces |
| Firefox behaviour differences in smoke tests | Low | Slices proven on Chromium first (T6–T8); Firefox added in T9 as a matrix dimension |

## Deliverables on approval

First action after approval: write this plan to `tasks/plan.md` and the checklist form
to `tasks/todo.md` (convention expected by `/build`). Then start at Task 1.
