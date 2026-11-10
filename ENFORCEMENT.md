# Enforcement — what guards the claim protocol, and what slips through

The claim guard in `src/resource.zig` is a runtime echo of a borrow
check, not a borrow check.  This document is the honest ledger: what
an application can still do to reach a resource outside its critical
section, what closes each path, and how far each closure goes.  The
build status of the tiers lives in `TODO.md`; this is the discussion.

There are three raw accesses an application could reach.

## 1. Write the declaration directly — closed by construction

The declaration is not in the application anymore.
`config.resources` describes the storage; the generator emits it into
`generated/storage.zig`, and the application's build wires no import
edge to that module — no file of the application, at any import
depth, can name it.  This is what real RTIC gets from Rust's module
privacy; here it is a graph-visibility fact, not a text rule.  The
compiler refuses both spellings (verified on 0.17.1):
`@import("storage")` — *no module named 'storage' available within
module 'app'*; `@import("generated/storage.zig")` — *file exists in
modules 'app' and 'storage'*.

What remains nameable is the *pointer* a claim lends — that is
hole 3, not this one.

## 2. Read through the proxy — closed by the lint, as manners

`ctx.res_a.ptr.*` is nine characters to raw memory, because `ptr` is
an ordinary struct field and Zig has no private fields.  A generator
*lint* (`codegen/lint.zig`) walks the application's import closure
before anything compiles and rejects any `.ptr` in its text.  This is
a convention enforced at the build, not a type rule; aliasing tricks
like `var p = ctx.res_a.ptr;` are caught by the same token, and
hiding behind them needs a deliberately indirect program.  The lint
is text-level, so a comptime-built `@import(name)` of an extra file
is unseen — harmless for the wall (there is no edge to hide), a
cosmetic gap for the other two rules.

## 3. Stash the lent `*T` — open

When a claim runs the critical section, it lends the resource's
address.  Inside the section that is exactly what the code needs;
but a Zig pointer never dies, and nothing stops an application from
saving it and using it after the section ends:

```zig
var saved: ?*u64 = null;                    // a global
fn inside(r: *u64) void { saved = r; }      // stash during the claim
pub fn t1(ctx: *context.t1) void {          // much later, low priority
    if (saved) |p| p.* += 1;                // silent, unsynchronized
}
```

The lint does not catch this — every line is legal text.  The
runtime guard does not catch it either — the check runs at the claim
boundary, and this path never crosses a boundary.  The result is
silent corruption: a write below the ceiling, with no message.  The
retraction of the reference at the end of the section is ceremony;
making references expire needs a borrow checker — the real
foundation of Rust RTIC, and the reason its locks are compile-time
facts.

### What Tier C would be

Stop lending the raw pointer; lend a *capability* — a small
generated wrapper struct holding the pointer plus an `open` flag
that `claim` flips off on return, whose accessor panics when the
flag says the section is over.  In Zig this is a runtime check
attached to every use of the reference rather than a lifetime fact,
but it moves the line: the obvious stash — save the reference, use
it late — turns from silent corruption into a panic at the offending
dereference.  The promise upgrades from *we check the door* to
*every path into storage meets a check*.

What it honestly does not buy: a raw pointer deliberately extracted
from the wrapper and hidden behind a method call or inside a data
structure still escapes — the wrapper closes *ordinary* stashes, not
*determined* ones.  It pairs with the lint and does not stand alone.

## Two rules that follow for generated code

- **Never emit `noalias`.**  With no type-based alias analysis to
  contradict it (verified: the app's ReleaseFast IR carries zero
  `!tbaa` annotations), an honest-sounding `noalias` on anything
  user code reaches lets the optimizer assume away the very sharing
  the guard exists to catch.
- **Never use `unreachable` to mean "the application should not do
  this".**  ReleaseFast deletes `unreachable` guards entirely —
  probed: the double-claim check vanished, 2 raises, 0 restores,
  segfault.  App misbehavior must meet `@panic` or `@compileError`,
  which survive every optimization mode.

## The ledger, in one line

The protocol is guarded against accidents, the storage is
unreachable by construction, and only a program written to evade the
model still can.
