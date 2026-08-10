# M9 API gaps

Empty on purpose, and opened before the first `src/` change. Fifth turn of the
instrument (M5–M8 each ran one; each was right that it would be needed).

This file records **Playwright API surface that M9 noticed and deliberately did
not build** — not bugs, not TODOs, and not things the spec already excludes. The
point is that "while I'm here" has somewhere to go that is not the diff. Three
new engines and two new platforms is the largest surface any milestone in this
repository has had for that temptation (R7).

## What counts as a gap here

A gap is API this package could wrap, that a user could reasonably want, that
M9's work brought into view and M9 is not doing. It is written down with the
engine or platform that surfaced it, because "WebKit exposes X" and "X is
missing" are different findings and only the first is useful later.

The specific class M9 expects to generate: **an engine-specific capability**.
The spec's "What M9 is not" says that nothing in Part A may add API only one
engine can use — so if WebKit or a branded channel turns out to expose something
the others do not, it lands here rather than in `src/`.

## What is explicitly *not* a gap

Recorded so that a later reader does not re-open a settled question:

- **Anything already in [`m8-api-gaps.md`](m8-api-gaps.md)** (and, transitively,
  `m4`–`m7`). M9 inherits those unchanged. They were not gaps because M9 is
  running; they are the same gaps they were.
- **Beta and dev channels** — `chrome-beta`, `msedge-dev`, `chrome-canary` and
  the rest. These are a *deliberate exclusion*, not an omission: they remain
  reachable today through `launch(...; channel = ...)`, which already works and
  is already asserted on the wire. D1a fixes the engine name set at five, and
  "What M9 is not" says so. A sixth engine name is an Ask First.
- **Intel macOS, Linux aarch64, 32-bit anything** — Assumption 6, a scope
  decision.
- **WebKit on Windows** — D12, a decision with a stated reason.
- **Service workers, the trace viewer, an async API** — the three remaining
  entries on the README's not-covered list, each still individually justified
  there. M9 clears the first entry (WebKit) and leaves those three.
- **A `tasklist`-based orphan-process check on Windows** — D11 decides against
  it in writing, with the reason. The gap it leaves is named in
  `docs/src/engines.md`, which is where a *user* would look, rather than here.
- **An engine divergence that is Playwright's own.** Those get a
  `docs/src/engines.md` row and an upstream link (D4). Only a divergence that
  turns out to be *this package's* baked-in assumption is a gap, and that one is
  a bug to fix rather than a gap to record.

## Gaps

_None recorded yet._
