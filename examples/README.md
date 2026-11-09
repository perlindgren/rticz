# Examples

## `beats/` — the working application

A complete application package that uses rticz as a library. To run
it, nothing to replicate but the folder itself — `root.zig` (the
whole application), `build.zig` and `build.zig.zon` (the wiring):

```
cd beats
zig build run          # init, then idle printing a beat every 2 s; Ctrl-C stops
zig build analyze      # the compile-time ceiling analysis, as text
```

Your own application is this same shape: a `pub const config` in
`root.zig`, resources as plain `pub var`s, handlers as `pub fn`s
taking their context.

## The four failures — copies of `beats` with one bug each

Each folder below is a byte-identical copy of `beats` except for
**one marked line** (`THE BUG`) in `root.zig`, and a README showing
the command and the real rejection it produces. Together they show
where each class of mistake is caught:

| folder | the bug | caught by |
|---|---|---|
| `beats_missing_handler/` | a row names a function that isn't there | the code generator, before anything compiles |
| `beats_private_init/` | `config.init` points at a non-public function | the same text check |
| `beats_wrong_context/` | a handler takes the wrong task's context | Zig's type checker, at the generated trampoline |
| `beats_nested_claim/` | a claim nested inside its own section | the claim guard at run time (compiles — no static check can decide it) |

Open any one of them and run `zig build` (the last:
`zig build -Doptimize=ReleaseFast run`); compare its `root.zig` with
`beats/root.zig` to see the one-line difference. The root package's
`zig build` / `zig build test` never build these — they are broken on
purpose.
