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
| 1 | `evaluate` — arbitrary JS returning a value, plus the tagged value codec | `evaluate`, `evaluate_handle`, `eval_on_selector`, `eval_on_selector_all`, `dispose` | `test_serializers.jl` (codec, hermetic), `test_evaluate.jl` (both browsers) |
| 2 | Frame access / iframes — `iframe.contentDocument` for the oxygen-template test | `frames`, `frame_locator`, `content_frame`, `owner_frame`, `parent_frame`, `url`, `name`, frame-scoped `locator` | `test_frames.jl` |
| 3 | Non-strict locators and `count` — `embed_raw` asserts two sliders, drives the first | `locator(…; strict=false)`, `count`, `nth`, `first`, `last`, iteration/indexing | `test_smoke.jl` |
| 4 | Driving `input[type=range]` to an exact value of 7 | `dispatch_event` (with `evaluate` as the general escape hatch) | `test_smoke.jl`, `test_parity.jl` |

## Comfort list

| Gap | Satisfied by | Tested in |
|---|---|---|
| `inner_text` — `document.body.innerText.includes('7')` | `inner_text`, plus `inner_html`, `get_attribute`, `is_visible`, `is_checked`, `is_enabled` | `test_smoke.jl` |
| Launch options — `--no-sandbox`, `--disable-dev-shm-usage`, `env` | `args`, `chromium_sandbox`, `env` on `launch` | `test_connection.jl` (exact wire params), `test_smoke.jl` |
| `firefox_user_prefs` — `dom.max_script_run_time` for the WGLMakie slow-script kill | `firefox_user_prefs` on `launch` | `test_connection.jl`, `test_smoke.jl` (Firefox leg) |
| Console / pageerror events — "spinner forever" vs. a captured JS exception | `console_messages`, `page_errors`, `clear_console_messages`, `clear_page_errors` | `test_smoke.jl` |
| `new_context` / `close(context)` — the per-test context leak | `new_context`, `new_page(::BrowserContext)`, `close(::BrowserContext)`, `contexts`, `pages`; `close(page)` now disposes the context `new_page(browser)` created | `test_smoke.jl` |
| `executable_path` / `channel` — `CHROME_BIN`-style provisioning | `executable_path`, `channel` on `launch` | `test_connection.jl` |

Two entries in the audit were already fine and needed nothing: polling is
covered by Bonnie's own `wait_for`, and the `probe(base)` server-side
assertions are plain HTTP.jl.

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
