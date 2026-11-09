# `beats_direct_write` — a resource written bare

A copy of `../beats` with one change in `root.zig` (marked
`THE BUG`): `t0` reaches for its counter as if the application still
declared it — a bare write, no claim, no context:

```zig
pub fn t0(ctx: *context.t0) void {
    res_a += 1; // THE BUG: the counter, written bare — as if this file owned it
```

Run it:

```
zig build
```

It fails **before a single file is compiled** — the code generator
(`rticz`'s `codegen/generate.zig`) lints the application's text, over
`root.zig` *and every file it imports*, before it writes anything:

```
generate: root.zig:161:5: 'res_a' is a resource — its instance lives
in the generated storage, beyond application code.  Reach it through
`ctx.res_a.claim(…)`; the name is reserved, so nothing of the
application may be spelled bare like this
```

Two things are worth noticing. The *wall* is already real without
this message: since resources live in a generated `storage.zig` the
application cannot import, `res_a` is not a name this file has — the
compiler would also refuse, with:

```
root.zig:161:5: error: use of undeclared identifier 'res_a'
```

which states a fact but no cure. The lint's whole job is the cure —
and it reaches further than the compiler would bother: the same
`res_a` hidden inside a file that `root.zig` merely imports is
rejected the same way, because the lint follows the import closure.
(Dotted uses pass: `ctx.res_a.claim` is the spelling the framework
itself teaches.) Exit code 1, nothing written.

Fix: `ctx.res_a.claim(add_n, 1);` — and the beat is back.
