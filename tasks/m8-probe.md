# M8 spec probe — the three open questions

Probed against the live 1.61.1 driver on **Chromium and Firefox**, 2026-08-08,
before any of M8 was written. Nothing in Parts A–D is wrapped yet, so the probe
calls the generated channel functions directly and taps the raw transport to
read event addressing. The script ran from scratch space; the "Reproducing"
notes below give the parts that are not obvious, not a verbatim copy.

**All three questions came back with the two engines in exact agreement**, and
two of them contradict what `SPEC-M8.md` guessed. D5 is rewritten as a result
and D9 gains a clause. The spec's edits reference this file.

---

## PQ0 — `utils` is present, and so is `webkit`

```
root initializer keys: ["android", "chromium", "electron", "firefox", "utils", "webkit"]
utils → Playwright.LocalUtils  guid=localUtils
```

`utils` is present on this driver build, resolving to a `LocalUtils` with the
fixed guid `localUtils`. **D1's optional handling stays anyway** — the protocol
declares it `LocalUtils?` (`playwright.yml:36`) and a guard that costs one
branch is cheaper than the `MethodError` three frames down that Assumption 6
describes.

Incidental, and **not** an M8 change: `webkit` is in the root initializer too.
The README's claim is about `PlaywrightAPI`'s fields, not the protocol's, so it
is still accurate as written — but "there is no `pw.webkit` to launch" is a
statement about this package's struct and a future milestone will find the
BrowserType sitting right there. Recorded so it is not re-discovered as a
surprise.

---

## OQ1 — the driver follows HAR redirects itself, and guards its own cycles

Four lookups against a hand-written HAR: `/a` 302s to `/b`, `/b` returns
`BODY-B`, and `/loop1` ↔ `/loop2` is a deliberate cycle.

| Lookup | `isNavigationRequest` | `action` | Other fields |
|---|---|---|---|
| `/a` (the redirecting entry) | `false` | **`fulfill`** | `status = 200`, `body = "BODY-B"` |
| `/b` (the target) | `false` | `fulfill` | `status = 200`, `body = "BODY-B"` |
| `/nope` (absent) | `false` | `noentry` | — |
| `/loop1` (cycle head) | `false` | **`error`** | `message = "HAR error: Found redirect cycle for http://probe.test/loop1"` |
| `/a` (the redirecting entry) | **`true`** | **`redirect`** | `redirectURL = "http://probe.test/b"` |

**Three things follow, and two of them change the spec.**

1. **`redirect` is a navigation-only action.** For a sub-resource the driver
   resolves the redirect chain *internally* and hands back the final response
   already fulfilled — `/a` returns `/b`'s body and a 200, not a 302. So the
   spec's guess (re-look-up at `redirectURL`, serve what that resolves to) is
   wrong for the case it was written for, because that case never reaches the
   client.
2. **The driver guards redirect cycles.** A cycle comes back as
   `action = "error"` with a message naming the URL, so **D5's client-side
   20-hop loop guard is unnecessary** — it would be a second guard behind a
   working one, and it could only ever fire on input the first guard already
   rejected.
3. **What `redirect` actually asks for** is that the *navigation* be pointed at
   `redirectURL`, which the client does by continuing the route at the new URL
   and letting the browser re-request. That is the only case D5 has to
   implement, and it is one branch, not a loop.

### Two `harOpen` behaviours worth knowing

- **A missing file raises, it does not return `{error}`.** `harOpen` on a
  nonexistent path throws `DriverError: ENOENT: no such file or directory,
  open '…'`. The declared `error: string?` return field is therefore *not* the
  channel for "no such file", and code that only checks the returned `error`
  will never see the common failure.
- **Valid JSON that is not a HAR opens successfully.**
  `{"this": "is not a har"}` returns a `harId` with no error. Every subsequent
  lookup is then `noentry`, so a typo'd or truncated archive presents exactly
  as an archive that simply does not cover your request — and under
  `not_found = :abort` (D4) that is a page whose every request fails with no
  hint as to why.

The second one is a **usability trap the spec did not anticipate**, and it
strengthens D4 rather than weakening it: `:abort` at least fails loudly. It is
recorded here as an argument for the error message on an aborted `noentry`
naming the archive it consulted, so that "your HAR is not a HAR" and "your HAR
lacks this entry" are distinguishable from the failure alone.

---

## OQ2 — `webSocketRoute` is delivered on the Page, when armed on the Page

Interception armed with `Page.setWebSocketInterceptionPatterns` (glob `**/*`),
then a `new WebSocket(…)` from a page served over a real `http://` origin — the
document fulfilled by M6's own `route!`, since `about:blank` is the wrong
origin to open a socket from.

| Engine | Event `guid` | Resolves to |
|---|---|---|
| Chromium | `page@873d4119…` | **PAGE** |
| Firefox | `page@113040a6…` | **PAGE** |

`params = {"webSocketRoute": {"guid": "webSocketRoute@…"}}` — the initializer
carries the route object and nothing else.

**D11's registry can key on the target the caller named.** Arming on the page
delivers on the page; there is no filtering step and no need to listen on the
context for a page-scoped registration. Both engines agree.

Not probed, and left as an implementation question rather than a spec one:
whether arming on the *context* delivers on the context for a socket opened by
one of its pages. The symmetric answer is the expected one and `route!` already
works that way, but Part D's first task should assert it rather than assume it.

### Reproducing

`Connection.start!` replaces `transport.on_message` with its own dispatch
(`connection.jl:60`), so a tap has to be re-installed *after* `start!` and must
be a top-level generic function — a closure defined later cannot be called by
the reader task (the world-age trap). The probe wraps rather than replaces:

```julia
const CONN = Ref{Any}(nothing)
function tap_and_dispatch(msg)
    tap(msg)
    c = CONN[]
    c === nothing || Playwright.dispatch(c, msg)
    return nothing
end
```

---

## OQ3 — persistent contexts honour `ContextOptions` on both engines

`launchPersistentContext` with `userAgent`, `locale` and `viewport`, then a
write to `localStorage`, a close, and a relaunch on the same directory with no
options at all.

| | Chromium | Firefox |
|---|---|---|
| returned fields | `(:browser, :context)` | `(:browser, :context)` |
| **pages already open** | **1** | **1** |
| `navigator.userAgent` | `M8-PROBE-UA` | `M8-PROBE-UA` |
| `navigator.language` | `de-DE` | `de-DE` |
| viewport | `812x613` | `812x613` |
| `localStorage` after relaunch | `"survived"` | `"survived"` |
| userAgent after relaunch (no opts) | real Chrome 149 UA | real Firefox 151 UA |

Three findings:

1. **`ContextOptions` are honoured identically on both engines.** Open
   Question 2's worry — that Firefox's profile handling would diverge — does
   not materialise, and Assumption 8's weaken-and-record clause is not needed
   for Part C.
2. **Persistence works, and the options do not persist with it.** The relaunch
   with no options gets the browser's real user agent back, which is correct:
   the profile stores site data, not the context configuration.
3. **A persistent context arrives with one page already open**, on both
   engines. This is a real API-design finding and **D9 gains a clause**:
   `new_page(ctx)` on a persistent context opens a *second* page, so the
   documented path must be `first(pages(ctx))`, and the docstring has to say
   so. A caller who reaches for `new_page` — the habit every other context in
   this package teaches — gets a stray blank page and, on the reopen test, a
   confusing result.

---

## Addendum, found at T5: a non-HAR archive answers `error`, not `noentry`

The probe established (OQ1) that `harOpen` succeeds on `{"this": "is not a
har"}`, and **D5a was written on the assumption that every subsequent lookup
against it returns `noentry`** — so that a typo'd archive would present as a
page whose every request silently aborts. T5 asserted that against the live
driver and it is **wrong in its second half**.

Three shapes, all probed on the pinned 1.61.1 driver:

| Archive | `harOpen` | lookup `action` | lookup `message` |
|---|---|---|---|
| `{"this": "is not a har"}` | succeeds, returns a `harId` | **`error`** | `HAR error: Cannot read properties of undefined (reading 'entries')` |
| `{"log": {"version": "1.2", "entries": []}}` | succeeds | `noentry` | — |
| `{"log": {"vers` (truncated) | **raises** `DriverError: Unterminated string in JSON at position 14` | — | — |

**D5a's conclusion survives; its mechanism does not.** The caller still has to
be told which archive was consulted and which URL was not found — but that work
belongs on the **`error`** branch, not only on the `noentry` one, because the
driver's own text for a non-HAR file is a raw JS `TypeError` that names neither.
So the implementation does both:

- `error` wraps the driver's message with the URL and the archive path;
- an aborted `noentry` warns with the URL and the archive path.

The `noentry` warning is not wasted by this finding: a *valid* archive that
lacks an entry is the second row of the table, and that is the case the warning
is actually for. What changed is that "your HAR is not a HAR" is distinguishable
by the driver rather than by us — it is a different `action`, not a different
message on the same one.

The three rows are pinned by the driver-gated testset at the bottom of
`test/test_har.jl`, so a driver upgrade that changes any of them is a test
failure rather than a surprise.

Recorded 2026-08-08, during T5.

---

## Addendum, found at T11: `harExport(mode = "archive")` always produces a zip

The round trip failed on its first run, on both engines, with the same error
from the replay half:

```
DriverError: Unexpected token 'P', "PK  "... is not valid JSON
```

`PK\x03\x04` is a zip's local file header. **`harExport(mode = "archive")`
returns a zip whatever `content` was** — `:embed` included, where there are no
attached bodies to justify one. `save_as!` had faithfully written that zip to a
path ending in `.har`, and `harOpen` then handed it to a JSON parser.

Nothing in `tracing.yml` says this; `harExport` is declared as returning an
`Artifact?` and the artifact's shape is not described. The spec's D8 reasoned by
analogy with `tracingStopChunk` — correctly, as it turns out, since *that* one
produces a zip too and M4 wrote it to a `.zip` path without ever having to
notice.

Two consequences, both implemented at T11:

- **Writing.** `stop_har_recording!` unzips on the way out when the destination
  is not a `.zip`, via the driver's own `harUnzip`, putting attached bodies
  beside the `.har` where `harLookup` resolves them. A `.zip` destination is
  written as exported. This is what other bindings do and what makes
  `path = "api.har"` mean what a caller expects.
- **Reading.** `route_from_har` now decides whether an archive is zipped from
  its **first four bytes rather than its extension**. Both directions of this
  feature produce a zip under a `.har` name if you let them, and the failure is
  a JSON parse error from inside the driver — as unhelpful a message as this
  milestone has produced. The extension is a guess; the content is the fact.

Worth noting against SPEC-M8's "What M8 is not": this is still not HAR parsing.
Reading four magic bytes to decide which driver call to make is not reading the
archive, and Julia still never sees the JSON.

Recorded 2026-08-08, during T11.
