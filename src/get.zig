//! Cloning a single repository into its place under the root directory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const url = @import("url.zig");

pub const Options = struct {
    root: []const u8,
    host: []const u8 = "github.com",
    scheme: []const u8 = "ssh",
    /// Leave the host out of the destination, i.e. `<root>/<path>`.
    skip_host: bool = false,
};

/// Where a repository comes from and where it goes.
pub const Target = struct {
    source: []const u8,
    dest: []const u8,
};

/// Resolves `repo` into the URL to clone and its `<root>/<host>/<path>`
/// destination.
pub fn resolve(arena: Allocator, repo: []const u8, opts: Options) url.ParseError!Target {
    const u = try url.parse(arena, repo, opts.host, opts.scheme);
    return .{
        .source = try std.fmt.allocPrint(arena, "{f}", .{u}),
        .dest = try std.fs.path.join(arena, &.{ opts.root, try u.toPath(arena, opts.skip_host) }),
    };
}

pub const CloneError = error{
    /// The destination directory already exists.
    AlreadyExists,
    /// `jj git clone` exited unsuccessfully. It reports its own errors.
    CloneFailed,
} || std.process.SpawnError || Io.Dir.AccessError || std.process.Child.WaitError;

pub const CloneOptions = struct {
    /// Bookmark to fetch and check out instead of the default branch.
    branch: ?[]const u8 = null,
};

/// Clones `target` using `jj git clone`, which creates any missing
/// parent directories of the destination.
pub fn clone(io: Io, target: Target, opts: CloneOptions) CloneError!void {
    if (Io.Dir.cwd().access(io, target.dest, .{})) |_| {
        return error.AlreadyExists;
    } else |err| switch (err) {
        error.FileNotFound => {},
        else => |e| return e,
    }

    var argv_buf: [7][]const u8 = undefined;
    var argv: std.ArrayList([]const u8) = .initBuffer(&argv_buf);
    argv.appendSliceAssumeCapacity(&.{ "jj", "git", "clone" });
    if (opts.branch) |branch| argv.appendSliceAssumeCapacity(&.{ "--branch", branch });
    argv.appendSliceAssumeCapacity(&.{ target.source, target.dest });

    var child = try std.process.spawn(io, .{ .argv = argv.items });
    switch (try child.wait(io)) {
        .exited => |code| if (code != 0) return error.CloneFailed,
        else => return error.CloneFailed,
    }
}

test resolve {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const target = try resolve(arena.allocator(), "grdl/git-get", .{ .root = "/repos" });
    try std.testing.expectEqualStrings("ssh://git@github.com/grdl/git-get", target.source);
    try std.testing.expectEqualStrings("/repos/github.com/grdl/git-get", target.dest);

    const skipped = try resolve(arena.allocator(), "grdl/git-get", .{ .root = "/repos", .skip_host = true });
    try std.testing.expectEqualStrings("/repos/grdl/git-get", skipped.dest);
}
