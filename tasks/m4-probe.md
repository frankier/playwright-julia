# T1 probe findings — tracing stop path (D1) and document-expect strings (D2)

Probed against the live 1.61.1 driver on **Chromium and Firefox**, 2026-08-04.
Two runs of two separate scripts; run 2 reproduced run 1 in full. Raw output is
in `artifacts/probe-output.txt` and `artifacts/probe-output-run2.txt`
(gitignored — reproduce with the scripts described at the bottom).

**Verdict: the milestone is buildable as specced. No Julia zip dependency is
required, so the `SPEC-M4.md` *Ask first* boundary is not triggered.**

## Q1 — what does `tracingStopChunk` hand back? (D1)

`tracingStopChunk` takes `mode: archive | discard | entries`
(`protocol/spec/tracing.yml`), and the mode decides the answer completely.

| `mode` | `artifact` | `entries` |
|---|---|---|
| `"archive"` | a real `Artifact` | `nothing` |
| `"entries"` | `nothing` | array of `{name, value}`, `value` = an absolute path |

With `mode = "archive"` the **driver assembles the zip itself**:

```
[chromium] artifact=Playwright.Artifact  entries=nothing
  pathAfterFinished -> /tmp/playwright-artifacts-5w4lCb/<id>.trace.zip
                       exists=true  size=30157
  saveAs -> artifacts/probe-chromium-archive.zip
            size=30157  magic=UInt8[0x50,0x4b,0x03,0x04]  isPK=true
[firefox]  same shape, size=185912, isPK=true
```

So **`save_as(artifact, path)` is the whole implementation of `stop_tracing`**
(D1's first branch). `localUtils.zip` is not needed and is not called.

Three sub-findings that shape T5:

1. **`tracesDir` at launch is *not* required.** Without it the driver writes to
   its own temp dir (`/tmp/playwright-artifacts-*`) and `archive` mode still
   produces a valid zip. Setting `tracesDir` only relocates that scratch
   directory — same artifact, same magic bytes, path under the given dir. So
   `launch` does **not** need a `traces_dir` option for A1 to work; the plan
   listed it as conditional on this probe, and the condition came back false.
2. **`tracingStart` then `tracingStartChunk` is the working order.**
   `tracingStartChunk` returns a `traceName` string (e.g.
   `"1fc6fc433163baaeed28d6ddf63cee42"`); a chunk must be open or
   `tracingStopChunk` has nothing to close. Each stop consumes its chunk — a
   second `archive` stop needs a second `tracingStartChunk` first.
3. The `Tracing` channel is reached through the context initializer:
   `from_channel(ctx.connection, ctx.initializer["tracing"])`. It is not a
   generated accessor, so T5 supplies one (kept internal — wire knowledge stays
   out of the API layer).

`mode = "entries"` does work and does return the entry list the
`localUtils.zip` path would consume, e.g.

```
{"name" => "trace.trace",   "value" => "/tmp/playwright-artifacts-5w4lCb/<id>-chunk1.trace"}
{"name" => "trace.network", "value" => ".../<id>-pwnetcopy-2.network"}
{"name" => "resources/b63fd621….html", "value" => ".../resources/b63fd621….html"}
```

It is recorded here for completeness only. **T5 uses `archive`** — it is one
call instead of two and puts zip assembly where it belongs, in the driver.

## Q2 — what strings does `frame.expect` want for the document? (D2)

**The selector must be the empty string `""`.** This is the finding that would
have cost the most to guess: a wrong selector fails with the *same* generic
`ExpectFailure` as a real mismatch, exactly as M3's T6 found.

| `selector` | `to.have.title = "M4"` on a page whose title is `M4` |
|---|---|
| `""` | **passes** |
| `":root"` | fails — call log says `waiting for locator(":root")` |
| `"html"` | fails, same way |

Confirmed identically on both engines. The expressions are `to.have.title` and
`to.have.url`, and the value goes in the usual `expectedText` array, so
`Regex` support comes for free from the existing `expected_text` helper.

### The failure shape

A mismatch arrives as `ExpectFailure` and **the existing M3 accessors read it
unchanged** — no new decoding is needed for T8:

```
details = {"received" => {"value" => {"s" => "M4"},
                          "ariaSnapshot" => "- heading \"Milestone 4\"…"},
           "timedOut" => true}

received_value(e)        == "M4"                          # src/errors.jl:146
custom_error_message(e)  === nothing
timed_out(e)             == true
```

`received.value` is the `{"s" => …}` serialized-string shape, which
`from_serialized` already handles. For `to.have.url` the received value is the
full URL (`"http://127.0.0.1:39353/m4.html"`).

So SC 6's "raises `AssertionFailure` carrying the received value" is satisfied
by the existing `assertion_failure` path; T8 adds table entries and a dispatch
method, and nothing else.

## Consequences for the plan

- **T5** implements `stop_tracing` as `tracingStopChunk(mode="archive")` +
  `save_as`. No `localUtils.zip`, no Julia zip library, no `traces_dir` on
  `launch`.
- **T8** adds `:to_have_title` and `:to_have_url` to `MATCHERS` with selector
  `""`, and needs no new error handling.
- The empty-string selector is a genuine sharp edge: it must be commented at
  the point of use, because `""` reads like an oversight rather than a
  requirement.

## Reproducing

Scripts run under the shared `@pw-probe` env (test-only deps are not loadable
via `--project=.`), not committed to `src/`:

- run 1 — both questions, both engines, plus the `tracesDir` variant
- run 2 — reproduction, plus `e.details` dumps and the selector comparison

Both write their transcript under `artifacts/`.
