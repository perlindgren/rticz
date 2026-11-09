# `beats_missing_handler` — a row names no handler

A copy of `../beats` with one change in `root.zig` (marked
`THE BUG`): the second task row was renamed, but no function of that
name exists — the classic RTIC slip, task and handler no longer
sharing one name:

```zig
.{
    .name = "t3", // THE BUG: no `pub fn t3` is declared
    ...
```

Run it:

```
zig build
```

It fails **before a single file is compiled** — the code generator
(`rticz`'s `codegen/generate.zig`) reads `config` as text and checks
every row's name against the public functions the file declares:

```
generate: task 't3' names no public function of the app namespace;
a task and its handler share one name — declare `pub fn t3`, or fix the row
```

Exit code 1, nothing written: `generated/` is never produced, so the
build stops at its first step. Fix: put the name back (`.name = "t1"`)
and `zig build` succeeds.
