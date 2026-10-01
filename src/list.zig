//! Discovering and reporting on the repositories under the root directory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const DiscoverError = Allocator.Error || Io.Dir.OpenError || Io.Dir.Iterator.Error;

/// Finds every jj repository under `root`, returning their paths relative
/// to it in sorted order. Repositories nested inside another repository
/// aren't reported, and symlinks aren't followed.
pub fn discover(arena: Allocator, io: Io, root: []const u8) DiscoverError![]const []const u8 {
    var dir = try Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer dir.close(io);

    var repos: std.ArrayList([]const u8) = .empty;
    try walk(arena, io, dir, "", &repos);
    std.mem.sort([]const u8, repos.items, {}, lessThan);
    return repos.items;
}

fn walk(arena: Allocator, io: Io, dir: Io.Dir, rel: []const u8, repos: *std.ArrayList([]const u8)) DiscoverError!void {
    var subdirs: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .directory) continue;
        if (std.mem.eql(u8, entry.name, ".jj")) {
            // A repository; whatever else is in here belongs to it.
            try repos.append(arena, rel);
            return;
        }
        if (std.mem.eql(u8, entry.name, ".git")) continue;
        try subdirs.append(arena, try arena.dupe(u8, entry.name));
    }

    for (subdirs.items) |name| {
        var sub = dir.openDir(io, name, .{ .iterate = true }) catch |err| switch (err) {
            // Unreadable directories can't hold repositories we could use.
            error.AccessDenied, error.PermissionDenied, error.FileNotFound => continue,
            else => |e| return e,
        };
        defer sub.close(io);
        const sub_rel = if (rel.len == 0) name else try std.fs.path.join(arena, &.{ rel, name });
        try walk(arena, io, sub, sub_rel, repos);
    }
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

test discover {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{
        "github.com/b/two/.jj",
        "github.com/a/one/.jj",
        "github.com/a/one/nested/.jj",
        "github.com/a/plain-git/.git",
        "gitlab.com/x/.jj",
        "empty",
    }) |path| try tmp.dir.createDirPath(io, path);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const repos = try discover(arena.allocator(), io, root);

    try std.testing.expectEqual(3, repos.len);
    try std.testing.expectEqualStrings("github.com/a/one", repos[0]);
    try std.testing.expectEqualStrings("github.com/b/two", repos[1]);
    try std.testing.expectEqualStrings("gitlab.com/x", repos[2]);
}
