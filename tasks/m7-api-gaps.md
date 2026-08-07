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

*No gaps recorded yet.*
