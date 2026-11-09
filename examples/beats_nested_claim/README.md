# `beats_nested_claim` — a claim inside its own section

A copy of `../beats` with one new function and one changed line in
`root.zig` (marked `THE BUG`): `t0`'s critical section on `res_a`
now calls a section that re-claims `res_a`:

```zig
fn reclaim_a(c: *context.t0, n: *u64) void {
    _ = n;
    c.res_a.claim(add_n, 1); // inside res_a's own section
}

pub fn t0(ctx: *context.t0) void {
    ctx.res_a.claim(reclaim_a, ctx); // THE BUG: reclaim_a re-claims res_a
```

Run it (ReleaseFast, to show the guard is not a debug-only assert):

```
zig build -Doptimize=ReleaseFast run
```

This one **compiles** — and must: whether a section re-claims its own
resource depends on which functions the handlers call, and no static
check can decide that in general. It is caught by the one layer that
can see the moment it happens — `Claim`'s runtime guard, the same one
that on real hardware is the BASEPRI ceiling:

```
-- priority ceiling res_a 1
-- priority ceiling res_a 1          ← raised twice, never restored
thread N panic: resource claimed while already claimed —
compose by nesting *different* resources, never re-claim the same one
```

The run aborts on the first beat (exit 134), surviving `-Doptimize=ReleaseFast`:
a nested claim of the same resource is a bug in *every* build, so it
is a panic in every build, not undefined behavior. Fix: let sections
nest only *different* resources.
