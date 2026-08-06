# API gaps found while building M6

The same instrument as [`tasks/m5-api-gaps.md`](m5-api-gaps.md), pointed at a
different milestone. M5's version was written *after* its docstrings, and its
lesson was that a gap record opened late is a gap record half written — by then
the surprises have been absorbed and no longer read as surprises. So this file
exists before Part B has a line of code in it, and is empty on purpose.

**Nothing here is fixed by M6.** That is the point of writing it down instead.
`SPEC-M6.md` Assumption 4 and R6 both say so: Part A puts every export in the
package under the eye at once, and Part B adds about twenty more, so the
milestone is exactly when unrelated fixes look cheap and reviewable. They are
neither. Anything noticed goes here; the diff stays about the bang convention
and the network.

The one exception, recorded so it is not mistaken for scope creep:
`tasks/m5-api-gaps.md` gap 1 is **resolved for `fill` and `close`** as a side
effect of D3 — they became `set_value!` and `close!`, which are real exports
covered by `checkdocs = :exports` rather than `Base` extensions invisible to
it. `count`, `first`, `last`, `length`, `iterate` and `getindex` still extend
`Base` and still are not exported, which for the iteration and indexing
protocol is correct rather than a gap. Gap 1 stands for those.

Recorded 2026-08-06, at the start of Part B.

---

_(No gaps recorded yet.)_
