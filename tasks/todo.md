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

- [ ] **T23** (L) `guide/har.md`, `network.md`, `events.md`, `api.md` — SC 30
- [ ] **T24** (M) Exports; README Status and the not-covered list, item by
      item — SC 33
- [ ] **T25** (S) `bonnie-parity.md` re-scored, or explicitly not — SC 34
- [ ] **T26** (M) Final verification of all 35 criteria — SC 29, 31, 32, 35

**Checkpoint E** — the milestone. Archive `plan.md` and `todo.md` to
`tasks/m8/`.

## Success criteria — how each was verified

Filled in by T26. A criterion that cannot be met says so — the M7 precedent,
where two criteria were reported unmet rather than reworded until they passed.

| SC | Verified by |
|---|---|
| 1 | |
| 2 | |
| 3 | |
| 4 | |
| 5 | |
| 6 | |
| 7 | |
| 8 | |
| 9 | |
| 10 | |
| 11 | |
| 12 | |
| 13 | |
| 14 | |
| 15 | |
| 16 | |
| 17 | |
| 18 | |
| 19 | |
| 20 | |
| 21 | |
| 22 | |
| 23 | |
| 24 | |
| 25 | |
| 26 | |
| 27 | |
| 28 | |
| 29 | |
| 30 | |
| 31 | |
| 32 | |
| 33 | |
| 34 | |
| 35 | |
