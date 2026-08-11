# Implementation Plan: Playwright.jl — Milestone 8 (the archive, the profile, and the socket)

Spec: [`SPEC-M8.md`](../SPEC-M8.md). Earlier plans are archived at
[`tasks/m1/plan.md`](m1/plan.md), [`tasks/m2/plan.md`](m2/plan.md),
[`tasks/m3/plan.md`](m3/plan.md), [`tasks/m4/plan.md`](m4/plan.md),
[`tasks/m5/plan.md`](m5/plan.md), [`tasks/m6/plan.md`](m6/plan.md) and
[`tasks/m7/plan.md`](m7/plan.md).

## Context

M8 is four subjects under one spec, and unlike M7 the ordering between them is
*mostly* free. That is the plan's main problem rather than its main
convenience: four independent parts invite four half-finished parts.

**What actually constrains the order:**

- **Part B's machinery is a prerequisite for one function in Part A.**
  `route_from_har(…; update = true)` is a recording (D7). Part A therefore
  ships that keyword as an explicit "not yet" error (SC 7) and Part B removes
  it. This is the only hard cross-part dependency in the milestone.
- **Part A must precede Part D**, not because of code but because of pattern.
  Part D is the *third* use of the registry + dispatcher-task shape from
  `routing.jl`, and Part A is the second. Getting the second one right — where
  it is nearly a straight reuse — is what makes the third one a known quantity
  instead of an invention under time pressure.
- **Part C is genuinely independent** and could run at any point. It is placed
  third because it is the smallest and the least likely to overrun, so it
  cannot become the reason Part D is squeezed.

**The probe is already done and it moved the spec.**
[`tasks/m8-probe.md`](m8-probe.md) settled all three open questions against
both engines before the plan was written, and two came back contradicting the
spec's guess:

- **D5 was rewritten.** The driver follows sub-resource redirect chains itself
  and guards its own cycles; `redirect` is a navigation-only action. What was
  going to be T5's bounded-loop implementation is now one `continue!` branch.
  A day of work and a class of off-by-one bug removed before either existed.
- **D5a and D9 are new clauses.** A file that is not a HAR opens successfully
  (so every lookup silently misses), and a persistent context arrives with a
  page already open (so `new_page` is the wrong habit). Both are documentation
  and error-message work that would otherwise have been discovered as bug
  reports.

**The risk this plan is actually managing is scope, not difficulty.** No single
task here is harder than M6's route dispatcher or M7's dialog registry. There
are simply more of them, across four surfaces, and Assumption 10 forbids the
usual release valve of quietly thinning the last part. So the checkpoints are
load-bearing: each one is a point at which the milestone could be *reported*
honestly, and slipping one is a conversation rather than a silent
re-prioritisation.

## Architecture Decisions

Recorded as D1–D14 in `SPEC-M8.md`. The ones that drive this plan:

- **D1 — `LocalUtils` plumbed through the `Connection`, not the
  `PlaywrightAPI`.** T2 is first in Part A because everything else in the part
  needs it, and it is hung off the connection because a `Route` handler can
  reach a connection and cannot reach a `PlaywrightAPI`.
- **D2 — `route_from_har` returns a `RouteRegistration`.** The whole feature is
  a `route!` handler, so `unroute!` already works and no new handle type is
  invented. This is what makes T3 (the release hook) a small change to
  `routing.jl` rather than a parallel lifetime system.
- **D4 — `not_found` defaults to `:abort`.** Drives T4's test design: the same
  `noentry` reply must produce two different observable outcomes, or the
  keyword is untested.
- **D5/D5a — post-probe.** T5 shrank to one branch; the cycle assertion is now
  against *the driver's* message, which is a better test than one against our
  own bound.
- **D6 — recording is a `start!`/`stop!` pair, not a `new_context` keyword.**
  Keeps T8 a sibling of `start_tracing!` and out of `lifecycle.jl` entirely.
- **D7 — `update = true` lands in Part B.** The reason T7 ships an error and
  T10 removes it, and the reason those are two tasks in two parts rather than
  one task deferred.
- **D9/D10 — persistent context ownership, and shared option builders.** T13
  refactors `launch`/`new_context` into shared builders *before* T14 adds the
  third caller. Order matters: adding the caller first means writing the 28
  keywords twice and deleting one copy.
- **D11/D12/D13 — the socket.** The registry is a reuse; `connect!` as the mode
  switch is the surprise; per-object events are the genuinely new mechanism and
  the one that can leak (T20).
- **D14 — `:websocket` keeps its deferred entry, message rewritten.** T21, and
  it is deliberately its own task so that the M7 lesson (`:dialog` left a table
  and arrived nowhere) is applied on purpose rather than remembered late.

## Dependency Graph

```
T1 open tasks/m8-api-gaps.md, empty     ← BEFORE Part A's first line of code

PART A — replay                                        (no browser needed)

T2 LocalUtils plumbing                  [D1, SC 1]
     ▼
T3 RouteRegistration release hook       [D3]   ← routing.jl, small
     ▼
T4 route_from_har core: action table,   [D2, D4, SC 2, 3]
   fulfill / noentry / not_found
     ▼
T5 redirect branch, driver's cycle      [D5, D5a, SC 4, 5]
   error, the naming abort message
     ▼
T6 .har.zip via harUnzip, temp dir      [D3, SC 6]
   lifetime owned by unroute!
     ▼
T7 with_har; update=true rejected;      [D2, D7, SC 7, 8]
   harClose asserted on the wire

     ═════ Checkpoint A: replay works, entirely hermetically ═════

PART B — recording

T8 HarRecording, start/stop,            [D6, D8, SC 9, 10, 11]
   symbol validation, no-artifact guard
     ▼
T9 with_har_recording block form        [D6]
     ▼
T10 update=true implemented; T7's       [D7, SC 7]
    error removed
     ▼
T11 test_smoke_har.jl round trip        [SC 12, 13]   ← both engines
     ▼
T12 update smoke, changed response      [SC 14]       ← both engines

     ═════ Checkpoint B: the HAR feature is real ═════

PART C — the profile                             (independent of A, B and D)

T13 shared launch_options /             [D10, SC 16]
    context_options; test_connection.jl
    grows FIRST
     ▼
T14 launch_persistent_context           [D9, SC 15, 17]
     ▼
T15 close!(ctx) closes the browser      [D9, SC 20]
     ▼
T16 test_smoke_persistent.jl:           [SC 18, 19]   ← both engines
    reopen, and pages == 1

     ═════ Checkpoint C ═════

PART D — the socket

T17 assert context-scoped delivery      [OQ 2]  ← unprobed; assert, don't assume
     ▼
T18 WebSocketRoute wrapper, registry,   [D11, D13, SC 21]
    dispatcher
     ▼
T19 connect!, send_to_page!/server!,    [D12, SC 24, 27]
    close_ws!, binary via base64
     ▼
T20 callbacks; subscriptions dropped    [D13, SC 28]
    when the route is disposed
     ▼
T21 :websocket's DEFERRED_EVENTS        [D14]
    message rewritten
     ▼
T22 test_smoke_websockets.jl            [SC 22, 23, 25, 26]  ← both engines

     ═════ Checkpoint D ═════

ALL PARTS

T23 docs: guide/har.md, network.md,     [SC 30]
    events.md, api.md
T24 exports; README Status and the      [SC 33]
    not-covered list, item by item
T25 bonnie-parity: re-score, or say     [SC 34]
    explicitly that it adds no row
T26 final verification of all 35        [SC 29, 31, 32, 35]
    criteria

     ═════ Checkpoint E: the milestone ═════
```

`T13 → T14` is the one ordering inside a part that is easy to get backwards and
expensive to undo; everything else within a part is a straight line because the
tasks share a file.

## Risks

**R1 — Four parts, and the last one is the hard one.** Part D is a new object
type, a new event shape and a bidirectional protocol, arriving when the
milestone is already long. Assumption 10 forbids thinning it silently.
*Mitigation:* Checkpoint C is deliberately early and small, so the state of the
budget is known *before* Part D starts rather than during it. If C lands late,
that is the moment to ask about D — not T20.

**R2 — The round trip (T11) is the first test that can fail for either part's
reasons.** Recording and replay are only proved together, and when the round
trip fails it will not be obvious which half is wrong.
*Mitigation:* T4–T7 test replay against a **hand-written** archive committed as
a fixture, so replay is known-good against known input before any recorded
archive exists. A T11 failure is then a recording failure by elimination.

**R3 — Part D can leak.** D13's per-object events belong to a short-lived
owner. A subscription table that grows for the process lifetime is invisible in
a test suite and obvious in a long-running scrape.
*Mitigation:* T20 asserts the table is empty after the socket closes (SC 28),
hermetically, so the leak is a test failure rather than a memory profile.

**R4 — D10's refactor touches working code.** `launch` and `new_context` are
used by every test and every example; a subtle change to option construction
breaks the suite far from its cause.
*Mitigation:* T13 grows `test_connection.jl` **before** the refactor, and SC 16
is that the pre-existing wire-param assertions pass unchanged. The refactor is
gated by tests written against the old behaviour.

**R5 — The temp directory and the `harId` are two lifetimes with one owner.**
T6 makes `unroute!` responsible for both. An exception between `harOpen` and
registration leaves an open HAR in the driver.
*Mitigation:* T7's SC 8 asserts `harClose` on the wire; T6 asserts the temp
directory is gone after `unroute!`. Both are hermetic, so neither depends on
noticing a leak.

**R6 — The usual one, fourth turn: unrelated warts look cheap.** M5, M6 and M7
each recorded this and each was right. Four new surfaces means four new
opportunities to "just fix" something adjacent.
*Mitigation:* `tasks/m8-api-gaps.md`, opened empty at T1 — before Part A's
first line, which is the discipline M5 learned by opening it late.

---

# Tasks

Sizes: **(S)** under an hour, **(M)** a focused session, **(L)** more than one
session — and, per M6's rule, an (L) that has not shown a green test in a day
is a task that should have been split.

## T1 — Open `tasks/m8-api-gaps.md`, empty (S)

- **Acceptance:** the file exists, states it is empty on purpose, and names the
  two entries M8 inherits as *not* gaps (the probe's `webkit`-in-initializer
  note, and anything already recorded in `m7-api-gaps.md`).
- **Verify:** the file is committed before any `src/` change in this milestone.
  `git log --diff-filter=A --format=%H -- tasks/m8-api-gaps.md` precedes the
  first `src/api/har.jl` commit.
- **Files:** `tasks/m8-api-gaps.md`

## Part A — replay

### T2 — `LocalUtils` plumbed through the connection (M)

- **Acceptance:** `Connection` carries the `LocalUtils`; `local_utils(conn)`
  returns it, or raises a `DriverError` naming HAR replay when absent (D1).
  `PlaywrightAPI` gains the field. `start_playwright` resolves
  `root.initializer["utils"]`.
- **Verify:** hermetic test constructing a connection *without* utils and
  asserting the error text; a smoke-gated assertion that the real driver has
  one. **SC 1.**
- **Files:** `src/objects.jl`, `src/connection.jl`, `src/api/lifecycle.jl`,
  `test/test_connection.jl`

### T3 — `RouteRegistration` gains a release hook (S)

- **Acceptance:** a registration can carry an optional zero-arg callable run by
  `unroute!` after the registration is removed, on every path including the
  throwing one. No behaviour change for registrations that do not set it.
- **Verify:** hermetic — a hook fires exactly once on `unroute!`, once at the
  end of `with_route`, and once when the body throws. Full existing
  `test_routing.jl` unchanged and green.
- **Files:** `src/api/routing.jl`, `test/test_routing.jl`

### T4 — `route_from_har`: the action table (L)

- **Acceptance:** `route_from_har(target, har; url, not_found)` registers a
  route, opens the archive, and maps `fulfill` and `noentry` onto the settle
  verbs D2's table names. `not_found` accepts `:abort`/`:fallback` and rejects
  anything else with an `ArgumentError` naming both.
- **Verify:** hermetic, against the committed hand-written fixture archive and
  a fake connection: each action driven as a canned `harLookup` reply, each
  settle verb asserted. The same `noentry` reply under both `not_found` values
  produces different outcomes. **SC 2, SC 3.**
- **Files:** `src/api/har.jl`, `src/Playwright.jl`, `test/test_har.jl`,
  `test/fixtures/api.har`

### T5 — Redirect, the driver's cycle error, and the naming abort (M)

- **Acceptance:** `redirect` → `continue!(route; url = redirectURL)`, one
  branch, no hop counter (D5). `error` → `DriverError` carrying the driver's
  `message`. An aborted `noentry` names the archive and the URL (D5a).
- **Verify:** hermetic. The navigation case and the sub-resource case asserted
  **separately** — the probe found they are different actions and a single
  test would hide that. A cyclic archive surfaces
  `HAR error: Found redirect cycle`, within the test's timeout. **SC 4, SC 5.**
- **Files:** `src/api/har.jl`, `test/test_har.jl`, `test/fixtures/api.har`

### T6 — `.har.zip`, and who owns the temp directory (M)

- **Acceptance:** a `.zip` path is unzipped via `harUnzip` into a temp
  directory and `harOpen` points at the result (D3). The directory is removed
  by the release hook from T3.
- **Verify:** hermetic replay from `test/fixtures/api.har.zip`; the temp
  directory does not exist after `unroute!`. **SC 6.**
- **Files:** `src/api/har.jl`, `test/test_har.jl`, `test/fixtures/api.har.zip`

### T7 — `with_har`, the `update` refusal, and `harClose` (M)

- **Acceptance:** `with_har` releases the archive even when the body throws.
  `update = true` raises a clear "not yet, lands in Part B" error (D7).
  `unroute!` calls `harClose`.
- **Verify:** hermetic; `harClose` asserted **on the wire**, not inferred.
  **SC 7, SC 8.**
- **Files:** `src/api/har.jl`, `test/test_har.jl`

> **Checkpoint A** — SC 1–8. Replay works against the hand-written fixture,
> with no browser involved in any of it.

## Part B — recording

### T8 — `HarRecording`, `start_har_recording!`, `stop_har_recording!` (L)

- **Acceptance:** the pair wraps `harStart`/`harExport` and writes through
  `save_as!` (D6, D8). `content` and `mode` are `Symbol`s validated to the wire
  enums. An export with no artifact raises a `DriverError` naming the unwritten
  path.
- **Verify:** hermetic for validation and the guard; the file-writing leg needs
  a browser and is covered by T11. **SC 9, SC 10, SC 11.**
- **Files:** `src/api/har.jl`, `src/Playwright.jl`, `test/test_har.jl`

### T9 — `with_har_recording` (S)

- **Acceptance:** block form, stops the recording even when the body throws.
- **Verify:** hermetic, mirroring `with_route`'s throwing test.
- **Files:** `src/api/har.jl`, `test/test_har.jl`

### T10 — `update = true` (M)

- **Acceptance:** the keyword records into the archive instead of serving from
  it, scoped to `url`, written when the registration is released. T7's refusal
  is removed in this commit and not before.
- **Verify:** hermetic that the refusal is gone and a recording is started;
  behaviour proved in T12. **SC 7's second half.**
- **Files:** `src/api/har.jl`, `test/test_har.jl`

### T11 — The round trip (L)

- **Acceptance:** record against the fixture server, **stop the server**,
  replay, page renders the same. Both engines. `url = "**/api/**"` excludes the
  document request, proved by replaying with `:abort` and watching it fail.
- **Verify:** `test_smoke_har.jl`; the server being down is asserted, not
  assumed. **SC 12, SC 13.**
- **Files:** `test/test_smoke_har.jl`, `test/runtests.jl`

### T12 — `update` against a changed response (M)

- **Acceptance:** an archive refreshed against a server whose body has changed
  serves the new body on replay. Both engines.
- **Verify:** `test_smoke_har.jl`. **SC 14.**
- **Files:** `test/test_smoke_har.jl`

> **Checkpoint B** — SC 9–14. The HAR feature is real: something recorded by
> this package is replayed by this package with the server switched off.

## Part C — the profile

### T13 — Shared option builders, tests first (M)

- **Acceptance:** `launch_options(…)` and `context_options(…)` build the wire
  `NamedTuple`s; `launch` and `new_context` call them and behave identically
  (D10). Internal, unexported.
- **Verify:** `test_connection.jl` grows its wire-param assertions **before**
  the refactor, and they pass unchanged after. **SC 16.**
- **Files:** `src/api/lifecycle.jl`, `test/test_connection.jl`

### T14 — `launch_persistent_context` (M)

- **Acceptance:** positional `user_data_dir`, the union of launch and context
  options via T13's builders, returns the `BrowserContext`. Empty
  `user_data_dir` is an `ArgumentError` before the wire. The docstring's
  example uses `first(pages(ctx))` and says why (D9).
- **Verify:** hermetic wire-param assertion. **SC 15, SC 17.**
- **Files:** `src/api/lifecycle.jl`, `src/Playwright.jl`,
  `test/test_connection.jl`

### T15 — The context owns the browser (M)

- **Acceptance:** `close!(ctx)` on a persistent context closes the browser too
  (D9). Non-persistent contexts unchanged.
- **Verify:** hermetic for the flag and the extra close; the process assertion
  is T16's. **SC 20.**
- **Files:** `src/connection.jl`, `src/api/lifecycle.jl`,
  `test/test_connection.jl`

### T16 — The reopen (M)

- **Acceptance:** both engines — set a cookie and a `localStorage` key, close,
  relaunch on the same directory, both survive. `length(pages(ctx)) == 1`
  immediately after launch. No browser process left behind.
- **Verify:** `test_smoke_persistent.jl`. **SC 18, SC 19.**
- **Files:** `test/test_smoke_persistent.jl`, `test/runtests.jl`

> **Checkpoint C** — SC 15–20. **This is the budget checkpoint.** If it lands
> late, ask about Part D here (R1), not at T20.

## Part D — the socket

### T17 — Assert context-scoped delivery (S)

- **Acceptance:** arming `setWebSocketInterceptionPatterns` on a
  `BrowserContext` delivers `webSocketRoute` on the context, for a socket
  opened by one of its pages. The probe established the page-scoped half
  ([`m8-probe.md`](m8-probe.md) OQ2); this is the half it left open.
- **Verify:** smoke, both engines. If it comes back page-scoped, **stop and
  amend the spec** — D11's registry needs a filtering step and that is a design
  change, not a fix.
- **Files:** `test/test_smoke_websockets.jl`

### T18 — `WebSocketRoute`, the registry, the dispatcher (L)

- **Acceptance:** `route_web_socket!` / `with_web_socket_route` /
  `unroute_web_socket!`, the registry keyed on the target the caller named
  (D11), user code on a dispatcher task and never on the reader task.
- **Verify:** hermetic, mirroring `test_dialogs.jl`: registration and removal,
  the reader-task assertion, exceptions collected and rethrown at
  unregistration. **SC 21.**
- **Files:** `src/api/websockets.jl`, `src/Playwright.jl`,
  `test/test_websockets.jl`

### T19 — `connect!`, the send verbs, binary (M)

- **Acceptance:** `connect!` switches mock → proxy (D12); `send_to_page!` and
  `send_to_server!` take `String` or `Vector{UInt8}`, with base64 and the
  `isBase64` flag handled invisibly; `close_ws!` takes `code`/`reason`.
  `send_to_server!` in mock mode raises before the wire.
- **Verify:** hermetic — the binary round trip asserted as `Vector{UInt8}` in
  and out; the mock-mode refusal asserted before any message is sent.
  **SC 24, SC 27.**
- **Files:** `src/api/websockets.jl`, `test/test_websockets.jl`

### T20 — Callbacks, and the subscriptions that must not leak (M)

- **Acceptance:** `on_message_from_page!`, `on_message_from_server!`,
  `on_close!`. Subscriptions for a route are dropped when the route object is
  disposed (D13).
- **Verify:** hermetic assertion on the subscription table after the socket
  closes — the leak in R3 must be a test failure, not a memory profile.
  **SC 28.**
- **Files:** `src/api/websockets.jl`, `src/api/events.jl`,
  `test/test_websockets.jl`

### T21 — `:websocket`'s deferred message (S)

- **Acceptance:** the entry stays in `DEFERRED_EVENTS` and its message points
  at `route_web_socket!` instead of claiming no accessors exist (D14).
- **Verify:** `test_events.jl`, asserting **on the message a user sees**, not
  only on table membership — the distinction `m7-api-gaps.md` gap 2 paid for.
  `deferred_table_is_honest` unchanged and green.
- **Files:** `src/api/events.jl`, `test/test_events.jl`

### T22 — The socket on real browsers (L)

- **Acceptance:** both engines — mock mode with the server never contacted
  (asserted server-side), proxy mode with a server message rewritten, a binary
  frame each way, the page observing `close_ws!` with its code and reason, and
  D12's swallowing behaviour pinned as intended.
- **Verify:** `test_smoke_websockets.jl` against a real WebSocket endpoint on
  the fixture server. **SC 22, SC 23, SC 25, SC 26.**
- **Files:** `test/test_smoke_websockets.jl`, `test/fixtures/m8.html`,
  `test/runtests.jl`

> **Checkpoint D** — SC 21–28.

## All parts

### T23 — Documentation (L)

- **Acceptance:** `docs/src/guide/har.md` new; `network.md` covers
  `route_from_har` and the socket; `events.md`'s table updated for
  `:websocket`; every new exported name in `api.md`.
- **Verify:** `julia --project=docs docs/make.jl` — zero errors, zero warnings,
  no gate weakened. **SC 30.**
- **Files:** `docs/src/guide/har.md`, `docs/src/guide/network.md`,
  `docs/src/guide/events.md`, `docs/src/api.md`

### T24 — Exports, README, the not-covered list (M)

- **Acceptance:** `test_exports.jl` grows; README Status rewritten for M8 and
  the not-covered list checked **item by item** against `names(Playwright)`,
  four entries removed and the rest justified individually.
- **Verify:** hermetic; the list re-read against the actual export set, not
  edited from memory. **SC 33.**
- **Files:** `src/Playwright.jl`, `test/test_exports.jl`, `README.md`

### T25 — Bonnie parity (S)

- **Acceptance:** `docs/bonnie-parity.md` re-scored, **or** a line stating that
  M8 adds no row and why.
- **Verify:** the file mentions M8 either way. **SC 34.**
- **Files:** `docs/bonnie-parity.md`

### T26 — Final verification (M)

- **Acceptance:** every one of the 35 success criteria run and recorded in
  `tasks/todo.md`'s table, with any that cannot be met saying so plainly — the
  M7 precedent, where two criteria were reported unmet rather than reworded.
- **Verify:** full hermetic and smoke counts recorded; `--check` in sync with
  an empty `src/generated/` diff for the whole milestone; `format(".")` clean;
  `Project.toml` diff empty. **SC 29, SC 31, SC 32, SC 35.**
- **Files:** `tasks/todo.md`, `tasks/m8-api-gaps.md`

> **Checkpoint E** — the milestone. Archive `plan.md` and `todo.md` to
> `tasks/m8/`.
