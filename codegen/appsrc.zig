//! The application reader: the config of an application's `root.zig`, read as text.
//!
//! The generators must know the whole system definition — task names,
//! interrupt lines, priorities, resource accesses — before a single
//! line of the application compiles: the context structs they emit
//! are what the handlers' signatures name.  But the config is not a
//! data-only structure any more, and it does not have to be: it
//! *references* the init and idle functions, and asking Zig to
//! materialize a function reference analyzes that function's body —
//! a body that calls the interrupt vectors which do not exist yet.
//! That is the chicken-and-egg this reader dissolves: `std.zig.Ast`
//! is the very parser the compiler uses, so this tool reads the
//! config's literal exactly as written without compiling any of it.
//! A function reference is, here, a name token; a resource is a name
//! that its `config.resources` declaration spells, together with the
//! type and initializer text written beside it.  Nothing is analyzed,
//! so nothing can demand that something exist yet.
//!
//! Reading text is not guessing though: every name extracted here is
//! checked against the declarations of the same file — a task names
//! a `pub fn`, a resource access names a declared resource — so
//! the errors that used to arrive through the generator's copy of
//! the app still arrive, at the same moment of the build, with
//! clearer messages.  What remains for the compiler is what only the
//! compiler can do — types — and it now happens exactly once, against
//! the real generated files.
//!
//! Real RTIC does exactly this: its `#[app]` attribute is a macro
//! that parses the program's token stream, and the task table it
//! lifts out is what generates the contexts and the vector table.
//! Zig ships no attribute macros, but it ships its parser in the
//! standard library, and a `pub const` struct literal is easy enough
//! terrain to walk with it.

const std = @import("std");
const Ast = std.zig.Ast;
const Node = Ast.Node;
const Allocator = std.mem.Allocator;

pub const Task = struct {
    name: []const u8,
    interrupt_id: []const u8,
    priority: u8,
    /// The resource names the row's `resources` array lists: exactly
    /// what the context struct gets fields for.
    resources: []const []const u8,
};

/// One resource declaration of `config.resources`, copied out of the
/// application's text as the generator will emit it: the name, and
/// the type and initializer spelled for the generated storage module
/// — where the application's own declarations are reachable only as
/// `app.`-qualified names, so single identifiers naming them are
/// rewritten to that form on the way out.
pub const Decl = struct {
    name: []const u8,
    storage_type: []const u8,
    init_expr: []const u8,
};

pub const App = struct {
    tasks: []const Task,
    /// The config's resource declarations, in declaration order: the
    /// vocabulary every access list names into, and the text the
    /// storage module is emitted from.
    resources: []const Decl,
    /// The idle row's access declarations, read the same way.
    idle_resources: []const []const u8,
    /// The names the config's references use — checked against the
    /// functions the file declares, not resolved to bodies.
    init_name: []const u8,
    idle_name: []const u8,
    /// Every `pub fn` the file declares: the namespace the task rows
    /// name into.
    fns: []const []const u8,
};

pub const Error = error{ Malformed, OutOfMemory };

fn fail(comptime fmt: []const u8, args: anytype) Error {
    std.debug.print("generate: " ++ fmt ++ "\n", args);
    return error.Malformed;
}

pub fn read(arena: Allocator, source: [:0]const u8) Error!App {
    var ast = Ast.parse(arena, source, .{ .mode = .zig }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer ast.deinit(arena);
    if (ast.errors.len > 0) {
        var buf: [1024]u8 = undefined;
        var fw: std.Io.Writer = .fixed(&buf);
        ast.renderError(ast.errors[0], &fw) catch {};
        return fail("the application source does not parse: {s}", .{buf[0..fw.end]});
    }

    // First pass over the declarations: the namespace the config
    // names into — the public functions — the public top-level names,
    // which are exactly the vocabulary a declaration's type or
    // initializer may spell (the storage module reaches the
    // application through its `app` import, and an import sees only
    // public declarations), and where `config` itself is written.
    var fns: std.ArrayList([]const u8) = .empty;
    var names: std.ArrayList([]const u8) = .empty;
    var config_init: ?Node.Index = null;
    for (ast.rootDecls()) |n| {
        switch (ast.nodeTag(n)) {
            .fn_decl => {
                const name_tok = ast.nodeMainToken(n) + 1;
                // `pub` sits before the `fn` token, one further left
                // than the name; a handler must be public to be
                // named, so only public functions enter the
                // namespace.
                if (ast.tokenTag(name_tok - 2) == .keyword_pub) {
                    try fns.append(arena, ast.tokenSlice(name_tok));
                    try names.append(arena, ast.tokenSlice(name_tok));
                }
            },
            .simple_var_decl, .global_var_decl, .aligned_var_decl => {
                const main = ast.nodeMainToken(n);
                const name = ast.tokenSlice(main + 1);
                if (std.mem.eql(u8, name, "config")) {
                    config_init = initNodeOf(&ast, n) orelse
                        return fail("`pub const config` has no value — where is the system definition?", .{});
                } else if (ast.tokenTag(main - 1) == .keyword_pub) {
                    try names.append(arena, name);
                }
            },
            else => {},
        }
    }
    const config_node = config_init orelse
        return fail("the application declares no `pub const config` — that is the system definition", .{});

    // The config literal: exactly the fields the framework's `Config`
    // type takes.  The resource declarations are read first and on
    // their own pass — every later field *names into* them, and
    // reading them rewrites their text for the storage module, which
    // needs `names` already complete.  Each depth keeps its own
    // buffer alive as long as it reads its fields — nested literals
    // read deeper, so one shared buffer would overwrite what the
    // outer loop is still walking.
    var cfg_buf: [2]Node.Index = undefined;
    const cfg_fields = structFields(&ast, config_node, &cfg_buf) orelse
        return fail("`pub const config` must be initialized with a struct literal", .{});
    var resources: ?[]const Decl = null;
    for (cfg_fields) |f| {
        const fname = fieldName(&ast, f) orelse continue;
        if (std.mem.eql(u8, fname, "resources")) {
            resources = try configDecls(&ast, arena, f, names.items);
        }
    }
    const res_decls = resources orelse
        return fail("`config` declares no `resources` — every resource of the system " ++
            "is declared there, as `rticz.resource.decls(.{{ .name = rticz.resource.of(Type, init), … }})`", .{});

    var init_name: ?[]const u8 = null;
    var idle_name: ?[]const u8 = null;
    var idle_resources: ?[]const []const u8 = null;
    var tasks: ?[]const Task = null;
    for (cfg_fields) |f| {
        const fname = fieldName(&ast, f) orelse continue;
        if (std.mem.eql(u8, fname, "init")) {
            init_name = referenceName(&ast, f) orelse
                return fail("`config.init` must reference a function of the application by name", .{});
        } else if (std.mem.eql(u8, fname, "resources")) {
            continue; // read above, before anything could name into it
        } else if (std.mem.eql(u8, fname, "idle")) {
            var idle_buf: [2]Node.Index = undefined;
            const idle_fields = structFields(&ast, f, &idle_buf) orelse
                return fail("`config.idle` must be a struct literal with a `task_id` and `resources`", .{});
            for (idle_fields) |g| {
                const gname = fieldName(&ast, g) orelse continue;
                if (std.mem.eql(u8, gname, "task_id")) {
                    idle_name = referenceName(&ast, g) orelse
                        return fail("`config.idle.task_id` must reference a function of the application by name", .{});
                } else if (std.mem.eql(u8, gname, "resources")) {
                    idle_resources = try accessesOf(&ast, arena, g, res_decls, "the idle task");
                }
            }
        } else if (std.mem.eql(u8, fname, "tasks")) {
            tasks = try tasksOf(&ast, arena, f, res_decls);
        } else {
            return fail("unknown field '{s}' in `config`", .{fname});
        }
    }

    const t = tasks orelse return fail("`config` has no `tasks` field", .{});
    const idle_res = idle_resources orelse
        return fail("`config.idle` declares no `resources`", .{});

    // The references resolve: names are not yet meanings, but the
    // declarations they must find are all in this same file.
    const iname = init_name orelse return fail("`config` has no `init` field", .{});
    const idlename = idle_name orelse return fail("`config` has no `idle` field", .{});
    if (!hasName(fns.items, iname))
        return fail("`config.init` references '{s}', which is not a public function of the app namespace", .{iname});
    if (!hasName(fns.items, idlename))
        return fail("`config.idle` references '{s}', which is not a public function of the app namespace", .{idlename});
    for (t) |task| {
        if (!hasName(fns.items, task.name)) {
            return fail("task '{s}' names no public function of the app namespace; " ++
                "a task and its handler share one name — declare `pub fn {s}`, or fix the row", .{ task.name, task.name });
        }
    }

    return .{
        .tasks = t,
        .resources = res_decls,
        .idle_resources = idle_res,
        .init_name = iname,
        .idle_name = idlename,
        .fns = fns.items,
    };
}

fn hasName(names: []const []const u8, name: []const u8) bool {
    for (names) |n| {
        if (std.mem.eql(u8, n, name)) return true;
    }
    return false;
}

fn initNodeOf(ast: *const Ast, decl: Node.Index) ?Node.Index {
    return switch (ast.nodeTag(decl)) {
        .simple_var_decl => ast.nodeData(decl).opt_node_and_opt_node[1].unwrap(),
        .global_var_decl => ast.nodeData(decl).extra_and_opt_node[1].unwrap(),
        .aligned_var_decl => ast.nodeData(decl).node_and_opt_node[1].unwrap(),
        else => null,
    };
}

/// The fields of a struct literal of any shape.  `fullStructInit`
/// stores two fields inline, in a buffer the *caller* owns — so the
/// buffer travels in here, and the caller keeps it alive for as long
/// as it reads the fields (a field slice into a dead buffer is
/// garbage waiting to be read as a token).
fn structFields(ast: *const Ast, n: Node.Index, buf: *[2]Node.Index) ?[]const Node.Index {
    const si = ast.fullStructInit(buf, n) orelse return null;
    return si.ast.fields;
}

fn fieldName(ast: *const Ast, field: Node.Index) ?[]const u8 {
    // The `=` sits immediately left of the value's first token
    // (modulo doc comments); the name is the identifier left of that.
    var tok = ast.firstToken(field);
    while (tok > 0) {
        tok -= 1;
        switch (ast.tokenTag(tok)) {
            .equal => break,
            .doc_comment, .container_doc_comment => continue,
            else => return null,
        }
    } else return null;
    const name_tok = tok - 1;
    if (ast.tokenTag(name_tok) != .identifier) return null;
    return ast.tokenSlice(name_tok);
}

/// A reference to an application function: the plain identifier the
/// config wrote (a body is never read — that is the whole point).
fn referenceName(ast: *const Ast, value: Node.Index) ?[]const u8 {
    if (ast.nodeTag(value) != .identifier) return null;
    return ast.tokenSlice(ast.nodeMainToken(value));
}

/// The `tasks` value: an array of row literals.
fn tasksOf(ast: *const Ast, arena: Allocator, value: Node.Index, resources: []const Decl) Error![]const Task {
    // The field is a slice, so the rows live in a constant array the
    // slice points into: `&.{ … }`.  Look through the `&`.
    const rows_node = if (ast.nodeTag(value) == .address_of)
        ast.nodeData(value).node
    else
        value;
    var buf: [2]Node.Index = undefined;
    const ai = ast.fullArrayInit(&buf, rows_node) orelse
        return fail("`config.tasks` must be an array literal: `&.{{ ... }}`", .{});
    const out = try arena.alloc(Task, ai.ast.elements.len);
    for (ai.ast.elements, out) |elem, *slot| {
        var row_buf: [2]Node.Index = undefined;
        const fields = structFields(ast, elem, &row_buf) orelse
            return fail("every entry of `config.tasks` must be a struct literal", .{});
        var name: ?[]const u8 = null;
        var irq: ?[]const u8 = null;
        var priority: ?u8 = null;
        var res: ?[]const []const u8 = null;
        for (fields) |f| {
            const fname = fieldName(ast, f) orelse
                return fail("every field of a task row must be named", .{});
            if (std.mem.eql(u8, fname, "name")) {
                name = stringOf(ast, f) orelse return fail("a task row's `name` must be a string literal", .{});
            } else if (std.mem.eql(u8, fname, "interrupt_id")) {
                irq = stringOf(ast, f) orelse return fail("a task row's `interrupt_id` must be a string literal", .{});
            } else if (std.mem.eql(u8, fname, "priority")) {
                if (ast.nodeTag(f) != .number_literal) return fail("a task row's `priority` must be an integer literal", .{});
                const tok = ast.tokenSlice(ast.nodeMainToken(f));
                priority = std.fmt.parseInt(u8, tok, 0) catch
                    return fail("priority '{s}' is not a u8", .{tok});
            } else if (std.mem.eql(u8, fname, "resources")) {
                res = try accessesOf(ast, arena, f, resources, "a task");
            } else {
                return fail("unknown field '{s}' in a task row", .{fname});
            }
        }
        slot.* = .{
            .name = name orelse return fail("a task row has no `name`", .{}),
            .interrupt_id = irq orelse return fail("task '{s}' has no `interrupt_id`", .{name.?}),
            .priority = priority orelse return fail("task '{s}' has no `priority`", .{name.?}),
            .resources = res orelse return fail("task '{s}' has no `resources`", .{name.?}),
        };
    }
    return out;
}

/// A row's or idle's `.resources = &.{"res_a", …}` value: the names
/// it accesses, each checked against the config's declarations — the
/// declaration is where a resource exists, everywhere else is a
/// name.
fn accessesOf(
    ast: *const Ast,
    arena: Allocator,
    value: Node.Index,
    resources: []const Decl,
    who: []const u8,
) Error![]const []const u8 {
    const arr_node = if (ast.nodeTag(value) == .address_of)
        ast.nodeData(value).node
    else
        value;
    var buf: [2]Node.Index = undefined;
    const ai = ast.fullArrayInit(&buf, arr_node) orelse
        return fail("{s}'s `resources` must be an array of names: `&.{{ \"res_a\", … }}`", .{who});
    var out: std.ArrayList([]const u8) = .empty;
    for (ai.ast.elements) |elem| {
        const access = stringOf(ast, elem) orelse
            return fail("every entry of {s}'s `resources` must name a resource: `\"res_a\"`", .{who});
        var found = false;
        for (resources) |decl| {
            if (std.mem.eql(u8, decl.name, access)) found = true;
        }
        if (!found)
            return fail("resource '{s}' of {s} is not declared — `config.resources` is where resources exist; " ++
                "declare it there, or fix the name", .{ access, who });
        try out.append(arena, access);
    }
    return out.items;
}

/// The `decls` call — `rticz.resource.decls(.{ .res_a =
/// rticz.resource.of(u64, 0), … })` — read for the storage module
/// that will be emitted from it: each entry's name, plus its type and
/// initializer *as text*, rewritten so the generated file can compile
/// it (`Position` becomes `app.Position` — in the storage module the
/// application's declarations are only reachable qualified).
fn configDecls(
    ast: *const Ast,
    arena: Allocator,
    value: Node.Index,
    names: []const []const u8,
) Error![]const Decl {
    var cbuf: [1]Node.Index = undefined;
    const call = ast.fullCall(&cbuf, value) orelse
        return fail("`config.resources` must be `rticz.resource.decls(…)`", .{});
    if (call.ast.params.len != 1 or
        !std.mem.eql(u8, ast.tokenSlice(ast.lastToken(call.ast.fn_expr)), "decls"))
        return fail("`config.resources` must be `rticz.resource.decls(…)`", .{});
    var decl_buf: [2]Node.Index = undefined;
    const fields = structFields(ast, call.ast.params[0], &decl_buf) orelse
        return fail("`decls` takes a struct literal of named `of` declarations", .{});
    const out = try arena.alloc(Decl, fields.len);
    for (fields, 0..) |f, i| {
        const name = fieldName(ast, f) orelse
            return fail("every entry of `decls` must be named — the name is the resource", .{});
        for (out[0..i]) |earlier| {
            if (std.mem.eql(u8, earlier.name, name))
                return fail("resource '{s}' is declared twice; one declaration, one instance", .{name});
        }
        var of_buf: [1]Node.Index = undefined;
        const of_call = ast.fullCall(&of_buf, f) orelse
            return fail("resource '{s}' must be declared as `rticz.resource.of(Type, init)`", .{name});
        if (of_call.ast.params.len != 2 or
            !std.mem.eql(u8, ast.tokenSlice(ast.lastToken(of_call.ast.fn_expr)), "of"))
            return fail("resource '{s}' must be declared as `rticz.resource.of(Type, init)`", .{name});
        out[i] = .{
            .name = name,
            .storage_type = try storageText(ast, arena, of_call.ast.params[0], names, name, "type"),
            .init_expr = try storageText(ast, arena, of_call.ast.params[1], names, name, "initializer"),
        };
    }
    return out;
}

/// The type names a declaration may spell without the application
/// declaring them — everything else an identifier names must be one
/// of this file's own declarations, or the storage file would be
/// emitted with a name it cannot resolve and the error would surface
/// in a *generated* file.  Catching it here keeps the message in the
/// application's terms.  (Keywords — `true`, `anyerror`, `align` —
/// never appear in the identifier branch below, so this list carries
/// plain identifiers only.)
const builtin_types = [_][]const u8{
    "u8",    "u16",   "u32",  "u64",       "u128",
    "i8",    "i16",   "i32",  "i64",       "i128",
    "usize", "isize", "bool", "void",      "f16",
    "f32",   "f64",   "f80",  "anyopaque",
};

/// Rebuild the source text of one config sub-expression (a
/// declaration's type or initializer), qualifying every identifier
/// that names one of the application's own declarations with `app.` —
/// the one way the storage module can reach them.  Tokens keep their
/// original spacing (gaps collapse to one space); strings are single
/// tokens and pass through untouched; comments are dropped, as an
/// emitted line carries none.
fn storageText(
    ast: *const Ast,
    arena: Allocator,
    node: Node.Index,
    names: []const []const u8,
    res: []const u8,
    what: []const u8,
) Error![]const u8 {
    const first = ast.firstToken(node);
    const last = ast.lastToken(node);
    var out: std.ArrayList(u8) = .empty;
    var prev: ?std.zig.Token.Tag = null;
    var kept_end: usize = 0;
    var tok: u32 = first;
    while (tok <= last) : (tok += 1) {
        const tag = ast.tokenTag(tok);
        if (tag == .doc_comment or tag == .container_doc_comment) continue;
        // One space wherever the source separated two kept tokens —
        // `1 + 2` keeps its spaces, `.{}` keeps its none.
        if (prev != null and ast.tokenStart(tok) > kept_end) try out.append(arena, ' ');
        switch (tag) {
            .identifier => {
                const text = ast.tokenSlice(tok);
                // The *dotted* identifier of a member access is a
                // namespace hop, not a reference: in `Label.init(…)`
                // it is `Label` that must be reachable (`app.Label`),
                // while `init` after the dot passes through.
                const namespace_hop = prev != null and prev.? == .period;
                if (!namespace_hop and hasName(names, text)) {
                    // An application declaration: reachable in the
                    // storage module only as `app.`-qualified.
                    try out.appendSlice(arena, "app.");
                    try out.appendSlice(arena, text);
                } else if (!namespace_hop and !hasName(builtin_types[0..], text)) {
                    // Neither public nor a builtin: the storage file
                    // would fail to resolve it — say so here, in the
                    // application's terms.  A private declaration
                    // lands here too, and the message says the cure.
                    return fail("the {s} of resource '{s}' names '{s}', which is neither a builtin type " ++
                        "nor a public declaration of this file — the generated storage reaches the " ++
                        "application as `app.{s}`, so name a public one", .{ what, res, text, text });
                } else {
                    try out.appendSlice(arena, text);
                }
            },
            else => try out.appendSlice(arena, ast.tokenSlice(tok)),
        }
        prev = tag;
        kept_end = ast.tokenStart(tok) + ast.tokenSlice(tok).len;
    }
    return out.items;
}

fn stringOf(ast: *const Ast, n: Node.Index) ?[]const u8 {
    if (ast.nodeTag(n) != .string_literal) return null;
    // The literals here are plain identifiers in quotes; a name that
    // needed an escape sequence was never going to name a Zig
    // identifier anyway, so refuse anything but the plain case.
    const tok = ast.tokenSlice(ast.nodeMainToken(n));
    if (tok.len < 2 or tok[0] != '"' or tok[tok.len - 1] != '"') return null;
    const inner = tok[1 .. tok.len - 1];
    if (std.mem.indexOfScalar(u8, inner, '\\') != null) return null;
    return inner;
}
