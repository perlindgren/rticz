# `beats_wrong_context` — the handler takes the wrong context

A copy of `../beats` with one change in `root.zig` (marked
`THE BUG`): `t0`'s signature names the *other* task's context:

```zig
pub fn t0(ctx: *context.t1) void { // THE BUG: t1's context, t0's row
```

Run it:

```
zig build
```

This time the generator passes — the row names `t0`, `t0` exists and
is public, so the text-level facts are all true. What is false lives
in the *types*, and Zig's own type checker rejects the program, at
the generated trampoline that must call the handler:

```
generated/irq.zig:38:12: error: expected type '*context.t1', found '*context.t0'
    app.t0(&ctx);
           ^~~~
root.zig:161:9: error: no field named 'res_a' in struct 'context.t1'
    ctx.res_a.claim(add_n, 1);
```

The bug shows twice because it is everywhere the wrong context is
reached: the TIMER0 trampoline builds a `context.t0` — that is what
the row says — and `t0` now asks for a `context.t1`, which does not
even have the `res_a` field its body claims. This is what the
generated contexts are *for*: a handler cannot touch or fake the
resources its declaration did not list, because the pointer type
it must accept is built from that declaration.

Fix: `*context.t0`.
