//! The application lint: three rules that keep framework spellings
//! out of application code, checked on the text before anything is
//! written.
//!
//! The wall is the module graph — generated storage is wired only to
//! the generated modules, so an application that *tries* to import
//! it meets the compiler's `no module named 'storage'`.  A wall is
//! not an explanation though, and there are two things it cannot do
//! at all: a bare resource name (`res_a += 1`) fails as the useless
//! `use of undeclared identifier`, and a proxy's `.ptr` field reads
//! fine until somebody claims something that was already claimed.
//! This lint answers both, in the application's own terms, at the
//! moment of the build.
//!
//! It walks root.zig *and the files it imports* — literal
//! `@import("file.zig")` edges, followed the way the compiler
//! resolves them, so an import cannot hide a misuse in a sibling
//! file.  What it deliberately does not catch: an import built at
//! comptime (`@import(name)`), which is text to no one.  That is the
//! accepted limit of a lint — the wall is the graph, this is the
//! manners.
//!
//! The rules, per application file:
//!
//!   * a resource name may not appear bare — never as a variable,
//!     parameter or field of the application.  Dotted uses
//!     (`.res_a` initializers, `ctx.res_a.claim`) are exactly the
//!     framework-approved spellings and pass;
//!   * `.ptr` is a proxy's framework-private field — reading it
//!     bypasses the claim, which is the one thing the model promises
//!     to prevent;
//!   * application code may not import the generated modules, by
//!     module name (`storage`) or by file path (`generated/…`) —
//!     those edges belong to the build.

const std = @import("std");
const Io = std.Io;
const Ast = std.zig.Ast;
const Allocator = std.mem.Allocator;

const appsrc = @import("appsrc.zig");

pub const Error = error{ Lint, OutOfMemory };

fn fail(comptime fmt: []const u8, args: anytype) Error {
    std.debug.print("generate: " ++ fmt ++ "\n", args);
    return error.Lint;
}

/// Lint the application: `root_rel` (relative to the current
/// directory, which is the generator's build root) and every file it
/// imports, transitively.  `resources` are the declared names — the
/// reserved vocabulary.
pub fn lint(
    io: Io,
    arena: Allocator,
    root_rel: []const u8,
    resources: []const appsrc.Decl,
) Error!void {
    var queue: std.ArrayList([]const u8) = .empty;
    var visited: std.ArrayList([]const u8) = .empty;
    try queue.append(arena, root_rel);

    var next: usize = 0;
    while (next < queue.items.len) : (next += 1) {
        const file = queue.items[next];

        // Unreadable or unparseable: the compiler will say so in
        // detail; the lint has nothing to add and no business
        // inventing a second error for it.
        const source = Io.Dir.cwd().readFileAllocOptions(io, file, arena, .unlimited, .of(u8), 0) catch continue;
        var ast = Ast.parse(arena, source, .{ .mode = .zig }) catch continue;
        defer ast.deinit(arena);
        if (ast.errors.len > 0) continue;

        try lintFile(io, arena, &ast, source, file, resources, &queue, &visited);
    }
}

fn lintFile(
    io: Io,
    arena: Allocator,
    ast: *const Ast,
    source: []const u8,
    file: []const u8,
    resources: []const appsrc.Decl,
    queue: *std.ArrayList([]const u8),
    visited: *std.ArrayList([]const u8),
) Error!void {
    var tok: u32 = 0;
    while (tok < ast.tokens.len) : (tok += 1) {
        const tag = ast.tokenTag(tok);
        if (tag == .builtin and std.mem.eql(u8, ast.tokenSlice(tok), "@import")) {
            // `@import("x")`, or `@import ("x")` with trivia between
            // — both are the same question, asked two ways.
            var t = tok + 1;
            if (t < ast.tokens.len and ast.tokenTag(t) == .l_paren) t += 1;
            if (t >= ast.tokens.len or ast.tokenTag(t) != .string_literal) continue;
            const raw = ast.tokenSlice(t);
            const target = raw[1 .. raw.len - 1]; // strip the quotes — plain paths only here
            if (std.mem.indexOfScalar(u8, target, '\\') != null) continue;

            if (std.mem.eql(u8, target, "storage") or
                std.mem.startsWith(u8, target, "generated/") or
                std.mem.indexOf(u8, target, "/generated/") != null)
            {
                return fail("{s}: application code cannot import the generated modules; " ++
                    "the build wires them, and resources are reached through `ctx.<name>.claim`", .{at(arena, source, ast, tok, file)});
            }

            // A file edge: follow it if the file is there, so the
            // lint covers everything the application is made of.  A
            // missing file is the compiler's message, not ours.
            if (std.mem.endsWith(u8, target, ".zig")) {
                const dir = std.fs.path.dirname(file) orelse ".";
                const joined = std.fs.path.join(arena, &.{ dir, target }) catch return error.OutOfMemory;
                Io.Dir.cwd().access(io, joined, .{}) catch continue;
                for (visited.items) |seen| {
                    if (std.mem.eql(u8, seen, joined)) break;
                } else {
                    try visited.append(arena, joined);
                    try queue.append(arena, joined);
                }
            }
            continue;
        }

        if (tag == .period and tok + 1 < ast.tokens.len and
            ast.tokenTag(tok + 1) == .identifier and
            std.mem.eql(u8, ast.tokenSlice(tok + 1), "ptr"))
        {
            return fail("{s}: `.ptr` is a claim proxy's framework-private field; " ++
                "resources are entered by `claim`, never by taking their address", .{at(arena, source, ast, tok, file)});
        }

        if (tag == .identifier) {
            const text = ast.tokenSlice(tok);
            for (resources) |decl| {
                if (!std.mem.eql(u8, decl.name, text)) continue;
                // A dotted use — `.res_a` initializer, `ctx.res_a`
                // proxy — is the framework's own spelling; only the
                // *bare* name, spelled as if the application owned
                // the instance, is the mistake.
                if (prevKept(ast, tok)) |p| {
                    if (ast.tokenTag(p) == .period) break;
                }
                return fail("{s}: '{s}' is a resource — its instance lives in the generated storage, " ++
                    "beyond application code.  Reach it through `ctx.{s}.claim(…)`; the name is reserved, " ++
                    "so nothing of the application may be spelled bare like this", .{ at(arena, source, ast, tok, file), text, text });
            }
        }
    }
}

/// The nearest token before `tok` that is not trivia, or null at the
/// file's start.  This token stream holds only doc comments as
/// trivia — line comments and whitespace never enter it.
fn prevKept(ast: *const Ast, tok: u32) ?u32 {
    var j = tok;
    while (j > 0) {
        j -= 1;
        switch (ast.tokenTag(j)) {
            .doc_comment, .container_doc_comment => continue,
            else => return j,
        }
    }
    return null;
}

/// `file:line:column` for a token, so a lint message lands where the
/// compiler's do.  This Ast carries no line table, so: count the
/// newlines before the token, the oldest way there is.
fn at(arena: Allocator, source: []const u8, ast: *const Ast, tok: u32, file: []const u8) []const u8 {
    const start = ast.tokenStart(tok);
    var line: usize = 1;
    var col: usize = 1;
    for (source[0..start]) |c| {
        if (c == '\n') {
            line += 1;
            col = 1;
        } else col += 1;
    }
    return std.fmt.allocPrint(arena, "{s}:{d}:{d}", .{ file, line, col }) catch file;
}
