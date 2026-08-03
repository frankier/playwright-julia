I read both: Bonnie's browser layer is test/cdp.jl (~100 lines: launch Chrome, open a tab, Runtime.evaluate, poll), used only by test/test_e2e.jl. Playwright.jl is at "milestone 1" — launch/new_page/goto/title/close, a strict single-element Locator with click/fill/text_content/input_value, and screenshot.

Blocking gaps (the port can't happen without these)

1. evaluate — arbitrary JS in the page returning a value. This is the primitive Bonnie's e2e suite is built on; every assertion in test_e2e.jl is evaluate/poll_js. Playwright.jl has no evaluate/eval_on_selector at all. Needs Frame.evaluateExpression plus the protocol's tagged value encoding ({"n":7}, {"s":…}, {"b":…}, {"v":"undefined"}, {"o":[…]}, {"a":[…]}) serialized/parsed both ways — that codec is the bulk of the work, not the RPC.

2. Frame access / frame_locator. test_e2e.jl:70-78 (oxygen templates) reaches into iframe.contentDocument to drive the app inside the iframe. Playwright.jl only ever resolves main_frame(page); there's no page.frames, no frame_locator, no content_frame. Without this the iframe test can't be expressed at all — and it's the one that proves same-origin embedding works.

3. Non-strict locators / count. Locator hardcodes "strict" => true, and there's no count. The embed_raw test asserts querySelectorAll('input[type=range]').length === 2, and then drives the first of two sliders. Needs count(loc) and nth(loc, i) (or first).

4. Driving input[type=range]. Playwright's fill rejects range inputs, so click in the middle of a track is the only built-in — imprecise, and Bonnie asserts an exact value of 7. You need either evaluate (gap 1) or dispatch_event to fire the synthetic input event the way slider_drive_js does. dispatch_event is missing.

Non-blocking but you'd feel the loss

- inner_text — assertions use document.body.innerText.includes('7'). text_content on body is close but includes hidden text; falls out of evaluate anyway.
- Launch options: args, chromium_sandbox, env, firefox_user_prefs. launch takes only headless and timeout. Bonnie's CDP path passes --no-sandbox --disable-dev-shm-usage, which containerised CI as root generally needs (chromium_sandbox=false is the Playwright equivalent). Separately, firefox_user_prefs is what would let you set dom.max_script_run_time — directly relevant to the Firefox slow-script kill of WGLMakie's first frame, which Chrome-based tests structurally can't see. Playwright.jl already supports Firefox, so this is the one place the port would gain a capability rather than just match one.
- Events (console, pageerror, crash). README lists these as out of scope. Not used today, but for WGLMakie failures "spinner forever" vs. a captured JS exception is the difference between a usable and a useless CI failure.
- new_context / close(context). new_page silently creates a context per page and close(page) doesn't close it, so Bonnie's per-test with_page pattern leaks a context per test until close(browser). Cosmetic at this suite's size.
- executable_path / channel. Bonnie honours CHROME_BIN and uses system Chrome; Playwright downloads its own browsers. Fine, arguably better — just note it changes CI provisioning.

What's already fine

wait_for in test/helpers.jl covers polling, so wait_for_function/auto-retrying expectations aren't needed. screenshot is a bonus over CDP. close/shutdown semantics map cleanly onto launch_chrome/close(browser). The probe(base) server-side assertions are plain HTTP.jl and unaffected.

Bottom line: evaluate + frame access + non-strict locators (count/nth) are the three must-haves; dispatch_event and launch args/chromium_sandbox make it comfortable. With evaluate alone you could port everything except the iframe test almost mechanically, since cdp.jl's surface is just with_page/evaluate/poll_js — the comment at the top of test/cdp.jl says it was kept separable for exactly this swap.
