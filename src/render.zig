//! Rendering jj-list output.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const list = @import("list.zig");

pub const Format = enum { tree, flat, dump };

pub const Result = list.StatusError!list.Status;

/// Writes one line per repository: its full path, bookmark and status.
pub fn flat(arena: Allocator, w: *Io.Writer, root: []const u8, repos: []const []const u8, statuses: []const Result) !void {
    var rows: std.ArrayList(Row) = .empty;
    for (repos, statuses) |repo, st| {
        try rows.append(arena, try .init(arena, try std.fs.path.join(arena, &.{ root, repo }), st));
    }
    try writeRows(w, rows.items);
}

/// Writes one clone URL per line, in the format `jj-get --dump` reads.
/// Repositories without a remote can't be restored and are skipped.
pub fn dump(w: *Io.Writer, urls: []const list.StatusError!?[]const u8) !void {
    for (urls) |url| {
        if (url catch null) |u| try w.print("{s}\n", .{u});
    }
}

/// Writes the repositories as a tree rooted at `root`, with each
/// repository's bookmark and status aligned after it.
pub fn tree(arena: Allocator, w: *Io.Writer, root: []const u8, repos: []const []const u8, statuses: []const Result) !void {
    var top: Node = .{ .name = root };
    for (repos, 0..) |repo, i| {
        var node = &top;
        var parts = std.mem.tokenizeScalar(u8, repo, '/');
        while (parts.next()) |part| node = try node.child(arena, part);
        node.repo = i;
    }

    var rows: std.ArrayList(Row) = .empty;
    try rows.append(arena, .{ .label = root });
    var prefix: std.ArrayList(u8) = .empty;
    try top.render(arena, &rows, &prefix, statuses);
    try writeRows(w, rows.items);
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

    fn render(self: Node, arena: Allocator, rows: *std.ArrayList(Row), prefix: *std.ArrayList(u8), statuses: []const Result) !void {
        for (self.children.items, 0..) |c, i| {
            const last = i == self.children.items.len - 1;
            const label = try std.fmt.allocPrint(arena, "{s}{s}{s}", .{ prefix.items, if (last) "└── " else "├── ", c.name });
            try rows.append(arena, if (c.repo) |r| try .init(arena, label, statuses[r]) else .{ .label = label });

            const len = prefix.items.len;
            try prefix.appendSlice(arena, if (last) "    " else "│   ");
            try c.render(arena, rows, prefix, statuses);
            prefix.shrinkRetainingCapacity(len);
        }
    }
};

const Row = struct {
    label: []const u8,
    bookmark: []const u8 = "",
    status: []const u8 = "",

    fn init(arena: Allocator, label: []const u8, st: Result) !Row {
        if (st) |ok| {
            return .{
                .label = label,
                .bookmark = ok.bookmark orelse "-",
                .status = try std.fmt.allocPrint(arena, "{f}", .{ok}),
            };
        } else |err| {
            return .{
                .label = label,
                .bookmark = "-",
                .status = try std.fmt.allocPrint(arena, "error: {t}", .{err}),
            };
        }
    }
};

/// Writes rows with the bookmark and status columns aligned. Rows without
/// a status, like tree directories, are written as just their label.
fn writeRows(w: *Io.Writer, rows: []const Row) !void {
    var label_width: usize = 0;
    var bookmark_width: usize = 0;
    for (rows) |row| {
        if (row.status.len == 0) continue;
        label_width = @max(label_width, displayWidth(row.label));
        bookmark_width = @max(bookmark_width, row.bookmark.len);
    }
    for (rows) |row| {
        try w.writeAll(row.label);
        if (row.status.len > 0) {
            try w.splatByteAll(' ', label_width - displayWidth(row.label) + 2);
            try w.writeAll(row.bookmark);
            try w.splatByteAll(' ', bookmark_width - row.bookmark.len + 2);
            try w.writeAll(row.status);
        }
        try w.writeByte('\n');
    }
}

/// Counts codepoints, so tree drawing characters take one column.
fn displayWidth(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn testRender(comptime format: Format, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const repos = [_][]const u8{ "github.com/a/one", "github.com/a/two", "github.com/b", "gitlab.com/x/y" };
    const statuses = [_]Result{
        .{ .bookmark = "main" },
        .{ .bookmark = "trunk", .modified = true },
        error.JjFailed,
        .{},
    };
    var out: Io.Writer.Allocating = .init(arena.allocator());
    try @field(@This(), @tagName(format))(arena.allocator(), &out.writer, "/r", &repos, &statuses);
    try std.testing.expectEqualStrings(want, out.written());
}

test flat {
    try testRender(.flat,
        \\/r/github.com/a/one  main   ok
        \\/r/github.com/a/two  trunk  modified
        \\/r/github.com/b      -      error: JjFailed
        \\/r/gitlab.com/x/y    -      ok
        \\
    );
}

test tree {
    try testRender(.tree,
        \\/r
        \\├── github.com
        \\│   ├── a
        \\│   │   ├── one  main   ok
        \\│   │   └── two  trunk  modified
        \\│   └── b        -      error: JjFailed
        \\└── gitlab.com
        \\    └── x
        \\        └── y    -      ok
        \\
    );
}
