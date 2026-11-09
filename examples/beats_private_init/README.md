# `beats_private_init` — the entry point is not public

A copy of `../beats` with one change in `root.zig` (marked
`THE BUG`): `init` lost its `pub`, so it is an ordinary private
function while the config still points at it:

```zig
fn init() void { // THE BUG: the `pub` is gone
```

Run it:

```
zig build
```

Again the generator stops the build before compiling anything. The
same name check that covers task rows also resolves `config.init`: a
reference may only name a *public* function, because "referenced from
the system definition" makes a handler part of the application's
visible surface:

```
generate: `config.init` references 'init', which is not a public
function of the app namespace
```

Exit code 1, nothing written. Fix: add the `pub` back.
