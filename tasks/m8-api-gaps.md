# API gaps found while building M8

The fourth turn of the instrument [`tasks/m5-api-gaps.md`](m5-api-gaps.md)
started, [`tasks/m6-api-gaps.md`](m6-api-gaps.md) continued and
[`tasks/m7-api-gaps.md`](m7-api-gaps.md) confirmed. M5 wrote its version
*after* its docstrings and learned that a gap record opened late is a gap
record half written — by then the surprises have been absorbed and no longer
read as surprises. M6 and M7 followed the lesson and it held both times. So
this file exists before Part A has a line of code in it, and is **empty on
purpose**.

**Nothing here is fixed by M8.** That is what writing it down is instead of.
`tasks/plan.md` R6 states the risk plainly: M8 opens *four* new surfaces —
replay, recording, the profile and the socket — which is four new sets of
adjacent warts, each of which will look both cheap and in-scope while the
relevant file is already open. Anything outside D1–D14 is an ask-first
(SPEC-M8 "Boundaries"), and anything noticed goes here.

Two things are deliberately **not** gaps, recorded so they are not re-found:

- **`webkit` is in the root initializer.** [`tasks/m8-probe.md`](m8-probe.md)
  PQ0 found `["android", "chromium", "electron", "firefox", "utils",
  "webkit"]`. This is not a gap and not an M8 change: the README's claim is
  about `PlaywrightAPI`'s fields, not the protocol's, so it is accurate as
  written. It is recorded because a future milestone reaching for WebKit will
  find the `BrowserType` sitting right there, and should find this note rather
  than re-discover it as a surprise. Assumption 12 keeps WebKit out of M8.
- **[`tasks/m7-api-gaps.md`](m7-api-gaps.md) is carried forward, not
  re-opened.** Both of its entries were resolved on instruction within M7 and
  are marked resolved in place, with the commits that did it. Nothing in it is
  outstanding for M8 to inherit, and its entries are not re-litigated here.
  M7 deleted `m5-api-gaps.md` when its entries closed; M8 does not delete
  `m7-api-gaps.md`, because a resolved entry with its reasoning attached is the
  record, and the record is the point.

Recorded 2026-08-08, before T2.

---

*(empty)*

## Closed at T26, still empty

Four surfaces, twenty-six tasks, and nothing was found that M8 declined to fix.
That is the honest result rather than a claim of restraint: the two things this
milestone did notice about neighbouring code were both fixed in the task that
found them, so neither belongs here.

- T19 found `handle_web_socket_route` calling `ensureOpened` unconditionally.
  That was correct when T18 wrote it — there was no `connect!` yet — and became
  wrong in the commit that added one, so it was fixed there.
- T24 found the README's not-covered list stale in four entries. Fixing it was
  the task; what came out of it is a test, so the next stale entry fails the
  suite rather than waiting to be re-read.

R6 predicted the opposite — four new surfaces meaning four new chances to "just
fix" something adjacent — and the file being empty is not evidence the risk was
imaginary. It is evidence that the boundary held for one milestone.
