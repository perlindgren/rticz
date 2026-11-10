# TODO

Decisions deferred on purpose, each with why it waits and what would
resume it.  Ordered by "would do next", not by size.

## Framework ergonomics

- [ ] `rticz-cli init <name>` — scaffold a new application package:
      build.zig.zon with a fresh fingerprint, the frozen application
      build.zig, a root.zig skeleton, printed next steps.
      *Why:* using rticz today means copying `examples/beats`' build
      files; a copy freezes, so framework-side wiring changes become
      migrations across every frozen copy.  `init` versions the
      template with the library — the maximum mitigation Zig 0.17's
      build system permits.
      *Waiting because:* decided 2026-11-09 to feel the friction on
      the second real application before smoothing it.

## Runtime

- [ ] Replace the ceiling *trace* with real masking: BASEPRI raise on
      claim, restore on release, Cortex-M target.
      *Prerequisite:* `Claim` must lend `*volatile T`, not `*T` — the
      same lesson the aliasing probes taught ("the optimizer does not
      know what memory means"; a non-volatile reload around the mask
      write is free to hoist).
- [ ] Real vector-table placement: map `interrupt_id` names to IRQ
      numbers per chip, place the generated trampolines via linker
      script/section.
- [ ] init as a task with its own context (RTIC gives init local
      resources; here init is still `fn () void`).

## Enforcement of the claim protocol

The three raw-access holes are documented in `ENFORCEMENT.md`
(*What this does not prevent* lives there now, with a worked example
of the open hole).  As of 2026-11-10 two tiers are
built and the hole count reflects it:

- [x] Tier B — language wall (built): resource storage is a generated
      module (`generated/storage.zig`) wired only to the generated
      contexts/vectors, so the application has no edge to it.  Both
      escape paths verified refused by the compiler on 0.17.1:
      `@import("storage")` → *no module named 'storage' available
      within module 'app'*; `@import("generated/storage.zig")` →
      *file exists in modules 'app' and 'storage'*.
- [x] Tier A — generator lint (built, the light form):
      `codegen/lint.zig` walks the app's import closure and rejects a
      bare resource name, a proxy `.ptr` read, and an import of
      generated code — all at generate time, `file:line:column`, with
      the cure in the message.  Known limit: text-level, so a
      comptime-built `@import(name)` is unseen — harmless for the
      wall (no edge to hide), cosmetic for the other two rules.
- [ ] Tier C — checked capability: replace the lent `*T` with a
      wrapper that self-destructs, closing the stashed-pointer hole —
      the one that survives both built tiers (a reference captured
      inside a section outlives the claim).
      Cannot intercept methods; pairs with the lint, not alone.

## Zig-upstream watch — re-probe on every toolchain upgrade

- [ ] Build-logic reuse for dependents (`importBuild`, `b.builder`,
      `generatedExe`): absent from 0.17.1 std, verified by grep.  The
      day one lands, `examples/beats/build.zig` collapses toward a
      one-line `rticz.addApp(b, ...)` and the `init` template above
      shrinks with it.
- [ ] Cross-file `pub` enforcement and the `@import` module-graph
      wall (both verified 0.17.1, both load-bearing for Tier B).
- [ ] `noalias` / `unreachable` under ReleaseFast (verified 0.17.1:
      no type-based alias analysis; `unreachable` guards get deleted
      — generated code must keep emitting neither).
