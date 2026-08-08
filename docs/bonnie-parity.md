# Bonnie.jl parity

[`tasks/bonnie_needs.md`](../tasks/bonnie_needs.md) audited Bonnie.jl's
CDP-based e2e suite against Playwright.jl at milestone 1 and found three
blockers plus a comfort list. This records, row by row, where each one now
lands.

Bonnie is the *acceptance test*, not a dependency: Playwright.jl knows nothing
about it. The criterion is that Bonnie's `test/cdp.jl` surface and every
assertion in its `test/test_e2e.jl` can be written with public Playwright.jl
API. The port itself happens in Bonnie's repo.

## Blockers

| # | Gap | Satisfied by | Tested in |
|---|---|---|---|
| 1 | `evaluate` — arbitrary JS returning a value, plus the tagged value codec | `evaluate`, `evaluate_handle`, `eval_on_selector`, `eval_on_selector_all`, `dispose!` | `test_serializers.jl` (codec, hermetic), `test_evaluate.jl` (both browsers) |
| 2 | Frame access / iframes — `iframe.contentDocument` for the oxygen-template test | `frames`, `frame_locator`, `content_frame`, `owner_frame`, `parent_frame`, `url`, `frame_name`, frame-scoped `locator` | `test_frames.jl` |
| 3 | Non-strict locators and `count` — `embed_raw` asserts two sliders, drives the first | `locator(…; strict=false)`, `count`, `nth`, `first`, `last`, iteration/indexing | `test_smoke.jl` |
| 4 | Driving `input[type=range]` to an exact value of 7 | `dispatch_event!` (with `evaluate` as the general escape hatch) | `test_smoke.jl`, `test_parity.jl` |

## Comfort list

| Gap | Satisfied by | Tested in |
|---|---|---|
| `inner_text` — `document.body.innerText.includes('7')` | `inner_text`, plus `inner_html`, `get_attribute`, `is_visible`, `is_checked`, `is_enabled` | `test_smoke.jl` |
| Launch options — `--no-sandbox`, `--disable-dev-shm-usage`, `env` | `args`, `chromium_sandbox`, `env` on `launch` | `test_connection.jl` (exact wire params), `test_smoke.jl` |
| `firefox_user_prefs` — `dom.max_script_run_time` for the WGLMakie slow-script kill | `firefox_user_prefs` on `launch` | `test_connection.jl`, `test_smoke.jl` (Firefox leg) |
| Console / pageerror events — "spinner forever" vs. a captured JS exception | `console_messages`, `page_errors`, `clear_console_messages!`, `clear_page_errors!` | `test_smoke.jl` |
| `new_context` / `close!(context)` — the per-test context leak | `new_context`, `new_page(::BrowserContext)`, `close!(::BrowserContext)`, `contexts`, `pages`; `close!(page)` now disposes the context `new_page(browser)` created | `test_smoke.jl` |
| `executable_path` / `channel` — `CHROME_BIN`-style provisioning | `executable_path`, `channel` on `launch` | `test_connection.jl` |

Two entries in the audit were already fine and needed nothing: polling is
covered by Bonnie's own `wait_for`, and the `probe(base)` server-side
assertions are plain HTTP.jl.

## Re-scored by milestone 6

Network interception and the network events were the largest remaining "would
have to be hand-rolled" entry. They are public API now, which changes two rows
above and adds one the audit did not think to ask for:

| Gap | Satisfied by | Tested in |
|---|---|---|
| Asserting on what the page *fetched*, not just what it rendered | `expect_request`, `expect_response`, `:request` / `:response` / `:requestfinished` / `:requestfailed` | `test_smoke_network.jl` (both engines) |
| Driving the failure path without breaking the server | `route!`, `abort!`, `fulfill!(…; status = 500)` | `test_smoke_network.jl` |
| Testing a frontend with no backend running at all | `with_route` + `fulfill!(…; json = …)` | `test_smoke_network.jl`, `examples/oxygen_jl.jl` |
| The real response with one thing changed | `Playwright.fetch(route)` + `fulfill!(…; response = …)` | `test_smoke_network.jl` (SC 14) |

What this does *not* change: Bonnie's suite drives a real server and asserts on
real responses, so interception is an option it gains rather than a gap it had.
The value is in the cases a live backend makes awkward — the 500, the empty
state, the slow response — which are one line each now.

## Re-scored by milestone 7

**No row above changes, and that is the finding.** M7 shipped downloads, file
choosers and JavaScript dialogs; the audit in
[`tasks/bonnie_needs.md`](../tasks/bonnie_needs.md) asks for none of the three,
and re-reading it for them turns up nothing — Bonnie's suite renders pages and
asserts on them, and never moves a file in either direction. Writing a row here
anyway would be scoring a capability against a need that does not exist.

Two smaller M7 changes do touch the table, one in each direction:

| Row | Change |
|---|---|
| Blocker 2 | `name` is spelled `frame_name` now, and the row above says so. The rename is the whole change — same call, same meaning |
| Blocker 3 | `set_default_strict!` makes non-strict the page, context or frame default, so a suite that wants it in more than one place sets it once rather than per locator |

Neither is a gap closing. Blocker 3's row was already satisfied by
`locator(…; strict = false)`; what changed is how much of it a caller has to
repeat.

## The shim

Bonnie's `test/cdp.jl` is ~100 lines of hand-rolled CDP whose entire surface is
`with_page` / `evaluate` / `poll_js`. `evaluate` needs no shim — it is public
API with the same meaning — so the replacement is
[`test/bonnie_shim.jl`](../test/bonnie_shim.jl): under 40 lines of
implementation, no internals, and run against both fixtures in the smoke suite
so it cannot rot. `test_parity.jl` asserts the line count and the
public-API-only constraint, so this paragraph cannot drift from the truth
either.

The one capability the port *gains* rather than matches is
`firefox_user_prefs`: setting `dom.max_script_run_time` is what would let
Bonnie see the Firefox slow-script kill of WGLMakie's first frame, which
Chrome-based tests structurally cannot observe.

## Note on CI provisioning

Playwright downloads and manages its own browsers, into the shared
`~/.cache/ms-playwright`. Bonnie honours `CHROME_BIN` and uses system Chrome.
`executable_path` and `channel` on `launch` cover that case, so an existing
provisioning story keeps working — but `Playwright.install()` in CI is the
simpler path.
