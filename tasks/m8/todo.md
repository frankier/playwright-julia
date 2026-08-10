# TODO: Playwright.jl — Milestone 8 (the archive, the profile, and the socket)

Spec: `SPEC-M8.md`. See `tasks/plan.md` for full task descriptions, acceptance
criteria, and verification steps. Milestones 1–7 are archived under `tasks/m1/`
… `tasks/m7/`. The spec-phase probe findings are in `tasks/m8-probe.md`.

Sizes: (S) small, (M) medium, (L) large.

**The rule for Part A:** replay is tested against a **hand-written** fixture
archive, committed before T4. Replay must be known-good against known input
before any recorded archive exists — otherwise T11's round trip fails for two
possible reasons and neither is distinguishable (R2).

**The rule for Part C:** T13 before T14. The shared option builders land, and
`test_connection.jl`'s wire assertions grow, *before* the third caller exists.
Adding the caller first means writing 28 keyword defaults twice (R4).

**The rule for Part D:** the registry is a reuse, not an invention. If it
starts diverging from `routing.jl`'s shape, stop and say why in the spec.

**The tripwire, all parts:** if a test needs a `sleep` to pass, the lifetime is
wrong. Fix the lifetime, not the test.

**Checkpoint C is the budget checkpoint.** If it lands late, that is when to
ask about Part D — not at T20 (R1, Assumption 10).

## Phase 0: before any code

- [x] **T1** (S) Open `tasks/m8-api-gaps.md`, empty on purpose. Fourth turn of
      the instrument. Must be committed before the first `src/` change.

## Phase 1: Part A — replay

- [x] **T2** (M) `LocalUtils` plumbed through the `Connection`; `local_utils`
      accessor with the absent case named (D1) — SC 1
- [x] **T3** (S) `RouteRegistration` gains an optional release hook (D3)
- [x] **T4** (L) `route_from_har`: the action table, `fulfill`/`noentry`,
      `not_found` validation (D2, D4) — SC 2, 3
- [x] **T5** (M) `redirect` → one `continue!`; the driver's cycle error; the
      abort message that names the archive (D5, D5a) — SC 4, 5
- [x] **T6** (M) `.har.zip` via `harUnzip`; the temp dir owned by `unroute!`
      (D3) — SC 6
- [x] **T7** (M) `with_har`; `update = true` refused; `harClose` on the wire
      (D2, D7) — SC 7, 8

**Checkpoint A** — SC 1–8, entirely hermetic.

## Phase 2: Part B — recording

- [x] **T8** (L) `HarRecording`, `start_har_recording!`,
      `stop_har_recording!`; symbol validation; the no-artifact guard
      (D6, D8) — SC 9, 10, 11
- [x] **T9** (S) `with_har_recording` (D6)
- [x] **T10** (M) `update = true` implemented; T7's refusal removed (D7)
- [x] **T11** (L) The round trip, both engines: record, **stop the server**,
      replay — SC 12, 13
- [x] **T12** (M) `update` against a changed response, both engines — SC 14

**Checkpoint B** — SC 9–14. The HAR feature is real.

## Phase 3: Part C — the profile

- [x] **T13** (M) Shared `launch_options`/`context_options`;
      `test_connection.jl` grows **first** (D10) — SC 16
- [x] **T14** (M) `launch_persistent_context`; `first(pages(ctx))` documented
      (D9) — SC 15, 17
- [x] **T15** (M) `close!(ctx)` closes the browser it owns (D9) — SC 20
- [x] **T16** (M) The reopen, both engines; `pages(ctx)` has one page — SC 18, 19

**Checkpoint C** — SC 15–20. **The budget checkpoint.**

## Phase 4: Part D — the socket

- [x] **T17** (S) Assert context-scoped `webSocketRoute` delivery. If it is
      page-scoped, **stop and amend the spec** (OQ 2)
- [x] **T18** (L) `WebSocketRoute`, the registry, the dispatcher
      (D11, D13) — SC 21
- [x] **T19** (M) `connect!`, `send_to_page!`/`send_to_server!`, `close_ws!`,
      binary (D12) — SC 24, 27
- [x] **T20** (M) Callbacks; subscriptions dropped on dispose (D13) — SC 28
- [x] **T21** (S) `:websocket`'s `DEFERRED_EVENTS` message rewritten (D14)
- [x] **T22** (L) The socket on real browsers, both engines — SC 22, 23, 25, 26

**Checkpoint D** — SC 21–28.

## Phase 5: all parts

- [x] **T23** (L) `guide/har.md`, `network.md`, `events.md`, `api.md` — SC 30
- [x] **T24** (M) Exports; README Status and the not-covered list, item by
      item — SC 33
- [x] **T25** (S) `bonnie-parity.md` re-scored, or explicitly not — SC 34
- [x] **T26** (M) Final verification of all 35 criteria — SC 29, 31, 32, 35

**Checkpoint E** — the milestone. Archive `plan.md` and `todo.md` to
`tasks/m8/` — done by the *next* milestone's spec commit, as `SPEC-M8`'s own
commit archived M7's.

## Success criteria — how each was verified

Filled in by T26. **All 35 are met**; none had to be reported unmet, which is
worth saying explicitly because M7's table has two that were — the precedent is
that a criterion which cannot be met says so rather than being reworded until
it passes.

| SC | Verified by |
|---|---|
| 1 | `test_connection.jl` "local_utils names HAR replay when the driver exposes none (T2, SC 1)" — the absent case, hermetic; and "the pinned driver exposes a LocalUtils (T2, SC 1)", smoke-gated |
| 2 | `test_har.jl` "`fulfill` serves the archived response", "`redirect` is one continue!", "`error` carries the driver's message", "`noentry` under :abort fails the request" — one testset per action, each asserting the settle verb |
| 3 | `test_har.jl` "`noentry` under :abort fails the request" / "under :fallback reaches the real network", driven from the *same* canned reply; smoke's server-side half in `test_smoke_har.jl` |
| 4 | `test_har.jl` "`redirect` is one continue! at redirectURL" and "a sub-resource redirect is fulfilled, not continued" — separate testsets, per the probe; the cycle in "what the driver really answers (T5, SC 4)" |
| 5 | `test_har.jl` "an aborted noentry names the archive and the URL", asserted on the message text; ":fallback misses are not warned about" is its other half |
| 6 | `test_har.jl` "a .zip is unzipped by the driver, into a temp dir", "the temp directory is gone after unroute!", and the live "a .har.zip really replays through harUnzip" |
| 7 | Part A shipped the refusal; T10 removed it in the commit that implemented the keyword. Now `test_har.jl` "update = true records instead of replaying" and "unroute! on an update registration writes the file" |
| 8 | `test_har.jl` "unroute! closes the archive, on the wire" and "unroute_all! closes the archive too" — asserted on the wire, not inferred |
| 9 | `test_har.jl` "start_har_recording! sends the RecordHarOptions" and "stop_har_recording! exports, saves, and returns the path" |
| 10 | `test_har.jl` "content and mode reject a bad Symbol, naming the set" — before the wire |
| 11 | `test_har.jl` "an export with no artifact names the unwritten path" |
| 12 | `test_smoke_har.jl` "$engine: record, stop the server, replay (T11, SC 12)", both engines; the server being down asserted by `server_is_up` |
| 13 | `test_smoke_har.jl` "$engine: a url filter leaves the document out (T11, SC 13)", both engines |
| 14 | `test_smoke_har.jl` "$engine: update = true refreshes a stale archive (T12, SC 14)", both engines |
| 15 | `test_connection.jl` "launch_persistent_context sends the union of both (T14, SC 15)" |
| 16 | `test_connection.jl` "new_context sends only the options that were set", "new_context's full option set crosses unchanged", "accept_downloads = false denies rather than omitting" — all pre-existing assertions, unchanged across D10's refactor |
| 17 | `test_connection.jl` "an empty user_data_dir is refused before the wire (T14, SC 17)" |
| 18 | `test_smoke_persistent.jl` "$engine: the profile survives the process (T16, SC 18)", both engines |
| 19 | `test_smoke_persistent.jl` "$engine: it arrives with exactly one page (T16, SC 19)", both engines; the docstring's example uses `first(pages(ctx))` |
| 20 | `test_connection.jl` "close! on a persistent context closes only the context" / "a non-persistent context closes only itself" for the flag; `test_smoke_persistent.jl` "$engine: close! leaves no browser process" for the process |
| 21 | `test_websockets.jl` "handlers never run on the transport reader task (T18, SC 21)", and "callbacks never run on the transport reader task (T20, SC 21)" for T20's callbacks |
| 22 | `test_smoke_websockets.jl` "$engine: mock mode never contacts the server (T22, SC 22)", both engines, asserted on the server's connection counter |
| 23 | `test_smoke_websockets.jl` "$engine: proxy mode rewrites a server message (T22, SC 23)", both engines |
| 24 | `test_smoke_websockets.jl` "$engine: a binary frame survives each way (T22, SC 24)", both engines; hermetically in `test_websockets.jl` "send_to_page! base64-encodes bytes", "a binary page message arrives as bytes", "a wire message decodes back to the type it was sent as" |
| 25 | `test_smoke_websockets.jl` "$engine: close_ws! is what the page's onclose sees (T22, SC 25)", both engines |
| 26 | `test_smoke_websockets.jl` "$engine: a handled server message is swallowed (T22, SC 26)", both engines; hermetically in `test_websockets.jl` "a handled server message is swallowed, as intended" |
| 27 | `test_websockets.jl` "send_to_server! in mock mode raises before the wire (T19, SC 27)" — asserts the *absence* of the wire message |
| 28 | `test_websockets.jl` "the route's subscriptions are gone once it closes (T20, SC 28)", plus "disposing the route drops its state too" and "unrouting drops a live socket's state" for the other two ends. Proved to bite by commenting the teardown out and watching it fail |
| 29 | **2417 hermetic, 3348 smoke**, both engines, all green — 4m17 and 15m32 (M7 recorded 1933 / 2776) |
| 30 | `julia --project=docs docs/make.jl` — zero errors, zero warnings, with `checkdocs = :exports`, `warnonly = false` and `doctest = true` all unchanged |
| 31 | `gen/generate.jl --check`: "Generated channel layer is in sync with protocol/spec/". `git diff` on `src/generated/` empty from T1's commit to HEAD. `format(".")` clean |
| 32 | `git diff` on `Project.toml` from T1's commit to HEAD: empty. `Base64` was already a dependency, which is why D3 could use it |
| 33 | README Status rewritten; four entries removed from the not-covered list and the remaining three justified individually. Gated by `test_exports.jl` "the README's not-covered list is still true (T24, SC 33)", which also asserts a stale list would be caught |
| 34 | `docs/bonnie-parity.md` "Re-scored by milestone 8" — no row added, with the reason for each of the three features, including why the WGLMakie socket is not the row it looks like |
| 35 | `tasks/m8-api-gaps.md` exists, was committed at T1 before any `src/` change, and is **still empty** — no gap was found that M8 declined to fix |
