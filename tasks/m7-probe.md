# M7 spec probe — the two open questions

Probed against the live 1.61.1 driver on **Chromium and Firefox**, 2026-08-07,
before any of M7 was written. Neither `:download` nor `:fileChooser` is wrapped
yet, so the probe injected raw `EventSpec`s into `PAGE_EVENTS` and read the
wire params directly. The script ran from scratch space; the "Reproducing"
section below gives the parts of it that are not obvious, not a verbatim copy.

**Both questions came back with the two engines in exact agreement**, which is
the outcome neither question expected. Nothing in `SPEC-M7.md` needs an
engine-specific carve-out.

---

## OQ1 — `acceptDownloads`: the default is accept, and "deny" still fires

Four context configurations, a `<a download>` pointing at a
`Content-Disposition: attachment` response. Identical results on both engines:

| `acceptDownloads` | `download` event | `Artifact.failure` | `pathAfterFinished` |
|---|---|---|---|
| **unset** (what `new_context` does today) | fires | `nothing` | real path, correct bytes |
| `"accept"` | fires | `nothing` | real path, correct bytes |
| `"deny"` | **fires** | `"Pass { acceptDownloads: true } when you are creating your browser context."` | **raises `DriverError`** |
| `"internal-browser-default"` | **never fires** (5 s timeout) | — | — |

Four things follow, and three of them change the spec:

1. **The default is already accept.** Omitting the parameter downloads
   normally on both engines. So `accept_downloads` is a convenience keyword,
   not mandatory boilerplate, and the guide does not have to open with it.
2. **`"deny"` does not suppress the event.** The download event still arrives
   with a correct `url` and `suggestedFilename`; the refusal shows up only when
   you ask the artifact for something. This is what makes SC 15 (a `Download`
   whose `failure` is non-`nothing`) straightforward — `expect_download`
   returns normally and `failure(dl)` is the discriminator.
3. **`path` on a denied download raises rather than returning.** The failure is
   *not* reported through the return value of `pathAfterFinished`; it is a
   `DriverError` carrying the driver's own English sentence. `path(dl)` and
   `save_as!(dl; …)` therefore raise on a denied download, and `failure(dl)` is
   the only non-throwing way to ask.
4. **`"internal-browser-default"` must never be sent.** It hands the download
   to the browser's own machinery and Playwright emits nothing at all — the
   page appears to do nothing and the test waits out its timeout. So `nothing`
   on the Julia side means *omit the parameter*, never *pass
   `internal-browser-default`*, which is the mapping mistake this value is
   sitting there waiting for someone to make.

## OQ2 — `isMultiple` agrees across engines, and `webkitdirectory` is `false`

Three inputs, clicked to open a chooser. Identical on both engines:

| Input | `isMultiple` |
|---|---|
| `<input type=file>` | `false` |
| `<input type=file multiple>` | `true` |
| `<input type=file webkitdirectory>` | **`false`** |

`param keys: element, isMultiple` on every one — the event carries nothing
else, so `FileChooser`'s surface in D13 is complete as specified.

The expected divergence did not happen: Firefox reports exactly what Chromium
reports, including for `webkitdirectory`, which is the Chromium-origin
attribute the question was really about. **SC 22 needs no narrowing.** The one
correction: `webkitdirectory` is `false`, not `true` — a directory chooser is
one selection, not many — so a test asserting `true` there would be asserting
the wrong thing on both engines rather than catching an engine difference.

## Incidental finding — `:download` is not opt-in, `:dialog` and `:fileChooser` are

`page.yml:592`'s `updateSubscription` enum is
`console, dialog, fileChooser, request, response, requestFinished,
requestFailed`. `download` is absent, so it fires unconditionally; the other
two need the opt-in flag on their `EventSpec`, the same mechanism M6 used for
the four network events.

This is also the mechanical basis for D12's auto-dismiss rule: the driver stops
auto-dismissing dialogs precisely because a client subscribed, so "registered a
listener" and "the driver expects an answer" are the same event on the wire.
Not a guess — it is why the enum contains `dialog` at all.

---

## Reproducing

```console
$ julia --project=@pw-probe probe_m7.jl
```

The script serves a fixture page and a `Content-Disposition` CSV from an
in-process HTTP.jl server, injects

```julia
P.PAGE_EVENTS[:download]    = P.EventSpec("download",    raw_payload, false)
P.PAGE_EVENTS[:filechooser] = P.EventSpec("fileChooser", raw_payload, true)
```

at top level (before any connection starts — the world-age trap), and calls
`P._browser_new_context(browser; acceptDownloads = …)` directly, since
`new_context` does not expose the keyword yet. `raw_payload` returns the event
params untouched.
