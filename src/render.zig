//! Rendering jj-list output, modeled on git-list's.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const list = @import("list.zig");

pub const Format = enum { tree, flat, dump };

pub const Result = list.Outcome(list.Status);

/// Whether to emit ANSI colors, using the same palette as git-list.
pub const Style = struct {
    color: bool,

    const Color = enum(u8) { red = 31, green = 32, yellow = 33, blue = 34 };

    fn paint(self: Style, w: *Io.Writer, color: Color, text: []const u8) !void {
        if (self.color) {
            try w.print("\x1b[1;{d}m{s}\x1b[0m", .{ @intFromEnum(color), text });
        } else {
            try w.writeAll(text);
        }
    }
};

/// Writes one clone URL per line, in the format `jj-get --dump` reads.
/// Repositories without a remote can't be restored and are skipped.
pub fn dump(w: *Io.Writer, urls: []const list.Outcome(?[]const u8)) !void {
    for (urls) |url| switch (url) {
        .ok => |u| if (u) |s| try w.print("{s}\n", .{s}),
        .err => {},
    };
}

/// Writes each repository's full path followed by its status, with any
/// other bookmarks on the lines below.
pub fn flat(arena: Allocator, w: *Io.Writer, style: Style, root: []const u8, repos: []const []const u8, results: []const Result) !void {
    if (repos.len == 0) return empty(w, root);
    for (repos, results) |repo, result| {
        const path = try std.fs.path.join(arena, &.{ root, repo });
        try w.writeAll(path);
        try leaf(arena, w, style, result, try spaces(arena, displayWidth(path)));
    }
    try errors(arena, w, style, root, repos, results);
}

/// Writes the repositories as a tree rooted at `root`, with each
/// repository's status after its name.
pub fn tree(arena: Allocator, w: *Io.Writer, style: Style, root: []const u8, repos: []const []const u8, results: []const Result) !void {
    if (repos.len == 0) return empty(w, root);
    var top: Node = .{ .name = root };
    for (repos, 0..) |repo, i| {
        var node = &top;
        var parts = std.mem.tokenizeScalar(u8, repo, '/');
        while (parts.next()) |part| node = try node.child(arena, part);
        node.repo = i;
    }

    try w.print("{s}\n", .{root});
    var prefix: std.ArrayList(u8) = .empty;
    try top.render(arena, w, style, &prefix, results);
    try errors(arena, w, style, root, repos, results);
}

fn empty(w: *Io.Writer, root: []const u8) !void {
    try w.print("There are no jj repositories under {s}\n", .{root});
}

const Node = struct {
    name: []const u8,
    children: std.ArrayList(Node) = .empty,
    /// Index into the repository list if this node is a repository.
    repo: ?usize = null,

    fn child(self: *Node, arena: Allocator, name: []const u8) !*Node {
        for (self.children.items) |*c| if (std.mem.eql(u8, c.name, name)) return c;
        try self.children.append(arena, .{ .name = name });
        return &self.children.items[self.children.items.len - 1];
    }

    fn render(self: Node, arena: Allocator, w: *Io.Writer, style: Style, prefix: *std.ArrayList(u8), results: []const Result) !void {
        for (self.children.items, 0..) |c, i| {
            const last = i == self.children.items.len - 1;
            try w.print("{s}{s}{s}", .{ prefix.items, if (last) "└── " else "├── ", c.name });

            const len = prefix.items.len;
            try prefix.appendSlice(arena, if (last) "    " else "│   ");
            if (c.repo) |r| {
                // Further bookmarks line up under the first one, keeping
                // the tree's vertical links intact.
                const indent = try std.fmt.allocPrint(arena, "{s}{s}", .{ prefix.items, try spaces(arena, displayWidth(c.name)) });
                try leaf(arena, w, style, results[r], indent);
            } else {
                try w.writeByte('\n');
            }
            try c.render(arena, w, style, prefix, results);
            prefix.shrinkRetainingCapacity(len);
        }
    }
};

/// Writes the rest of a repository's line: its current bookmark and
/// status, then every other bookmark on its own line after `indent`.
fn leaf(arena: Allocator, w: *Io.Writer, style: Style, result: Result, indent: []const u8) !void {
    const st = switch (result) {
        .ok => |st| st,
        .err => {
            try w.writeByte(' ');
            try style.paint(w, .red, "error");
            return w.writeByte('\n');
        },
    };

    try w.writeByte(' ');
    try style.paint(w, .blue, st.current orelse "(no bookmark)");
    const current = if (st.current) |name| if (st.bookmark(name)) |b| try bookmarkStatus(arena, b) else "" else "";
    const worktree = try worktreeStatus(arena, st);
    if (current.len == 0 and worktree.len == 0) {
        try w.writeByte(' ');
        try style.paint(w, .green, "ok");
    }
    if (current.len > 0) {
        try w.writeByte(' ');
        try style.paint(w, .yellow, current);
    }
    if (worktree.len > 0) {
        try w.writeByte(' ');
        try style.paint(w, .red, worktree);
    }
    try w.writeByte('\n');

    for (st.bookmarks) |b| {
        if (st.current != null and std.mem.eql(u8, b.name, st.current.?)) continue;
        try w.print("{s} ", .{indent});
        try style.paint(w, .blue, b.name);
        try w.writeByte(' ');
        const status = try bookmarkStatus(arena, b);
        if (status.len == 0) try style.paint(w, .green, "ok") else try style.paint(w, .yellow, status);
        try w.writeByte('\n');
    }
}

/// Describes how a bookmark relates to its tracked remotes, or returns an
/// empty string when it's in sync with all of them.
fn bookmarkStatus(arena: Allocator, b: list.Bookmark) ![]const u8 {
    if (b.conflict) return "conflicted";
    if (b.remotes.len == 0) return "no upstream";

    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    for (b.remotes) |r| {
        if (r.ahead == 0 and r.behind == 0) continue;
        if (out.written().len > 0) try w.writeAll(", ");
        // With a single remote its name goes without saying, as in git-list.
        if (b.remotes.len > 1) try w.print("{s} ", .{r.name});
        if (r.ahead > 0) try w.print("{d} ahead", .{r.ahead});
        if (r.ahead > 0 and r.behind > 0) try w.writeByte(' ');
        if (r.behind > 0) try w.print("{d} behind", .{r.behind});
    }
    return out.written();
}

/// Describes the working-copy commit, e.g. `[ 2 changed 1 conflicted ]`,
/// or returns an empty string when it has no changes. When the working
/// copy couldn't be inspected, says why instead, since the counts would
/// be out of date.
fn worktreeStatus(arena: Allocator, st: list.Status) ![]const u8 {
    if (st.problem) |p| return switch (p) {
        .stale => "[ stale ]",
        .snapshot_failed => "[ snapshot failed ]",
        .no_working_copy => "[ no working copy ]",
    };
    if (st.changed == 0 and st.conflicted == 0) return "";
    var out: Io.Writer.Allocating = .init(arena);
    const w = &out.writer;
    try w.writeAll("[");
    if (st.changed > 0) try w.print(" {d} changed", .{st.changed});
    if (st.conflicted > 0) try w.print(" {d} conflicted", .{st.conflicted});
    try w.writeAll(" ]");
    return out.written();
}

/// Lists the error messages behind any `error` entries.
fn errors(arena: Allocator, w: *Io.Writer, style: Style, root: []const u8, repos: []const []const u8, results: []const Result) !void {
    var header = false;
    for (repos, results) |repo, result| switch (result) {
        .ok => {},
        .err => |msg| {
            if (!header) {
                try w.writeByte('\n');
                try style.paint(w, .red, "Oops, errors happened when loading repository status:");
                try w.writeByte('\n');
                header = true;
            }
            try w.print("{s}: {s}\n", .{ try std.fs.path.join(arena, &.{ root, repo }), msg });
        },
    };
}

fn spaces(arena: Allocator, n: usize) ![]const u8 {
    const s = try arena.alloc(u8, n);
    @memset(s, ' ');
    return s;
}

/// Counts codepoints, so names line up even with non-ASCII characters.
fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

const test_repos = [_][]const u8{ "github.com/a/one", "github.com/a/two", "github.com/b", "gitlab.com/x/y" };
const test_results = [_]Result{
    .{ .ok = .{
        .current = "main",
        .bookmarks = &.{
            .{ .name = "dev", .remotes = &.{.{ .name = "origin", .ahead = 2, .behind = 0 }} },
            .{ .name = "main", .remotes = &.{.{ .name = "origin", .ahead = 0, .behind = 0 }} },
            .{ .name = "wip" },
        },
    } },
    .{ .ok = .{
        .current = "trunk",
        .changed = 3,
        .bookmarks = &.{.{ .name = "trunk", .remotes = &.{.{ .name = "origin", .ahead = 1, .behind = 2 }} }},
    } },
    .{ .err = "There is no jj repo" },
    .{ .ok = .{ .current = "main@origin" } },
};

fn testRender(comptime format: Format, color: bool, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(arena.allocator());
    try @field(@This(), @tagName(format))(arena.allocator(), &out.writer, .{ .color = color }, "/r", &test_repos, &test_results);
    try std.testing.expectEqualStrings(want, out.written());
}

test flat {
    try testRender(.flat, false,
        \\/r/github.com/a/one main ok
        \\                    dev 2 ahead
        \\                    wip no upstream
        \\/r/github.com/a/two trunk 1 ahead 2 behind [ 3 changed ]
        \\/r/github.com/b error
        \\/r/gitlab.com/x/y main@origin ok
        \\
        \\Oops, errors happened when loading repository status:
        \\/r/github.com/b: There is no jj repo
        \\
    );
}

test tree {
    try testRender(.tree, false,
        \\/r
        \\├── github.com
        \\│   ├── a
        \\│   │   ├── one main ok
        \\│   │   │       dev 2 ahead
        \\│   │   │       wip no upstream
        \\│   │   └── two trunk 1 ahead 2 behind [ 3 changed ]
        \\│   └── b error
        \\└── gitlab.com
        \\    └── x
        \\        └── y main@origin ok
        \\
        \\Oops, errors happened when loading repository status:
        \\/r/github.com/b: There is no jj repo
        \\
    );
}

test "colors" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(arena.allocator());
    try flat(arena.allocator(), &out.writer, .{ .color = true }, "/r", test_repos[1..2], test_results[1..2]);
    try std.testing.expectEqualStrings("/r/github.com/a/two \x1b[1;34mtrunk\x1b[0m \x1b[1;33m1 ahead 2 behind\x1b[0m \x1b[1;31m[ 3 changed ]\x1b[0m\n", out.written());
}

test bookmarkStatus {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("conflicted", try bookmarkStatus(a, .{ .name = "x", .conflict = true }));
    try std.testing.expectEqualStrings("", try bookmarkStatus(a, .{ .name = "x", .remotes = &.{.{ .name = "origin", .ahead = 0, .behind = 0 }} }));
    try std.testing.expectEqualStrings("origin 1 ahead, upstream 4 behind", try bookmarkStatus(a, .{ .name = "x", .remotes = &.{
        .{ .name = "origin", .ahead = 1, .behind = 0 },
        .{ .name = "upstream", .ahead = 0, .behind = 4 },
    } }));
}

test "empty root" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var out: Io.Writer.Allocating = .init(arena.allocator());
    try tree(arena.allocator(), &out.writer, .{ .color = false }, "/r", &.{}, &.{});
    try std.testing.expectEqualStrings("There are no jj repositories under /r\n", out.written());
}
