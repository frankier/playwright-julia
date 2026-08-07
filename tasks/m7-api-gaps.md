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

## 1. Headless Firefox now has WebGL, and `wglmakie_jl.jl` asserts it does not

Not an API gap — a **stale environmental assumption in an example**, recorded
here because it is the thing M7 must not quietly fix, and because it blocks a
Checkpoint B criterion that is otherwise met.

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

