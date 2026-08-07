# API gaps found while building M7

The third turn of the instrument [`tasks/m5-api-gaps.md`](m5-api-gaps.md)
started and [`tasks/m6-api-gaps.md`](m6-api-gaps.md) continued. M5 wrote its
version *after* its docstrings and learned that a gap record opened late is a
gap record half written — by then the surprises have been absorbed and no
longer read as surprises. M6 followed the lesson and it held. So this file
exists before Part B has a line of code in it, and is **empty on purpose**.

**Nothing here is fixed by M7.** That is what writing it down is instead of.
`SPEC-M7.md` R4 is blunt about why the risk is highest in this particular
milestone: Part B puts the entire public surface under the eye at once, in a
milestone whose *stated subject* is fixing API deficiencies. Every unrelated
wart will look both cheap and in-scope, and it will be wrong on the second
count. Anything past D4–D9 is an ask-first, and anything noticed goes here.

Two things are deliberately **not** gaps, recorded so they are not re-found:

- **`tasks/m6-api-gaps.md` gap 1 is resolved by this milestone**, not deferred
  into it. D1–D3 fixed the generator's shadowing at the class rather than the
  instance, and `test/test_codegen.jl` gates it. That entry is marked resolved
  in place with the commits that did it.
- **`tasks/m5-api-gaps.md` is deleted by T11**, not carried forward. Its five
  surviving entries close as deliberate decisions (D9) with the rationale
  recorded in the docstring or guide page that owns each. A gap closed without
  its reason written down is a gap re-discovered next milestone, which is the
  failure mode this whole file exists to prevent.

Recorded 2026-08-07, at the start of Part B.

---

## 1. Headless Firefox now has WebGL, and `wglmakie_jl.jl` asserted it did not

> **RESOLVED, out of scope and on purpose.** Recorded first as a gap, then
> fixed on the maintainer's explicit instruction rather than on this file's
> own authority — which is the distinction the file exists to keep. The probe,
> the numbers and the decision are below; the fix is the commit that follows
> this edit. All 8 example runs pass, so Checkpoint B's "both examples pass on
> both engines" **is** met after all.
>
> M7 re-probed Firefox and found `has_webgl == true`, **1625 distinct
> colours** against Chromium's ~1690, crossing the 500 threshold **2.5s**
> after the canvas appears. The fallback branch is deleted and the pixel
> assertion runs on both engines. The 90-second budget is kept for both: it is
> a ceiling for `retry_until`, not a sleep, so it costs nothing on Firefox's
> 2.5s path and still covers the cold case it was calibrated for.

Not an API gap — a **stale environmental assumption in an example**, recorded
here because it is the thing M7 must not quietly fix, and because it blocked a
Checkpoint B criterion that was otherwise met.

`examples/wglmakie_jl.jl:144` asserts:

```julia
has_webgl = evaluate(page, "() => !!(c.getContext('webgl2') || c.getContext('webgl'))")
@test has_webgl == false      # "Headless Firefox has no WebGL"
```

That is now false. The example fails on Firefox with `3 passed, 1 failed`,
and passes on Chromium.

**It is not caused by anything in M7.** Verified by `git stash`ing Part B and
running the example at `f0186f0` — it fails identically, same line, same
count. The Playwright Firefox build this repo pins has gained headless WebGL
since M4 wrote the assertion; the comment above it ("Headless Firefox has no
WebGL, so the canvas is there and empty and WGLMakie draws its own fallback")
describes a browser that no longer exists.

**Why M7 does not fix it.** The fix is not a one-liner: the `else` branch is a
whole *alternative* assertion strategy, written because there was nothing to
assert about pixels. With WebGL present, the honest change is to run the
Chromium pixel path on both engines and delete the fallback branch — which
means re-measuring the render budget on Firefox, since the 90-second timeout
was calibrated against SwiftShader on Chromium. That is example work in a
milestone about downloads, dialogs and uploads, and R4 is explicit that this is
exactly when such work looks cheapest and is least in scope.

**Consequence, stated rather than hidden:** SPEC-M7's Checkpoint B criterion
"both examples pass on both engines" **cannot be met** in this environment, for
a reason that predates the milestone. Everything else in Checkpoint B holds.

