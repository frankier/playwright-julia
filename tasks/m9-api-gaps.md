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

### 1. No public accessor for the running browser's version

**Surfaced by:** the branded engines, and specifically by R4.

`Browser`'s initializer carries a `version` field — the diagnostics job read it
directly to answer OQ 3, and printed `chrome 151.0.7922.72`,
`msedge 150.0.4078.105` and so on. There is no public way to ask for it.
[`browser_name`](@ref) answers `"chromium"` and stops there.

Before M9 this was uninteresting: the bundled engines are pinned by
`PLAYWRIGHT_VERSION`, so the version was a constant a user could look up. D3a
changes that. Chrome and Edge come from the machine and move on Google's and
Microsoft's schedules, and the probe already caught the three runner images
carrying three different Chrome versions in the same run, one of them a major
version ahead. A user whose branded test starts failing has no supported way to
record what it ran against.

**Not done because** it is API surface, not a divergence, and M9's rule is that
Part A adds nothing beyond `Engine`, `engine`, `engine_name` and `skip_engine`.
Adding a `browser_version` accessor is a small, self-contained piece of work
that belongs in a milestone that is choosing its API rather than one that is
proving a matrix.

It is also the natural companion to a *reporting* question this milestone did
not open: `report_diagnostics` exists and would be the obvious place to include
the engine name and browser version together.
