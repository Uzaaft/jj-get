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
    /// The root `dest` lives under.
    root: []const u8,
};

/// Resolves `repo` into the URL to clone and its `<root>/<host>/<path>`
/// destination.
pub fn resolve(arena: Allocator, repo: []const u8, opts: Options) url.ParseError!Target {
    const u = try url.parse(arena, repo, opts.host, opts.scheme);
    return .{
        .source = try std.fmt.allocPrint(arena, "{f}", .{u}),
        .dest = try std.fs.path.join(arena, &.{ opts.root, try u.toPath(arena, opts.skip_host) }),
        .root = opts.root,
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
    const ok = switch (try child.wait(io)) {
        .exited => |code| code == 0,
        else => false,
    };
    if (!ok) {
        removeEmptyParents(io, target);
        return error.CloneFailed;
    }
}

/// jj creates every missing directory leading up to the destination and
/// leaves them behind when the clone fails. Remove the ones that are
/// still empty, stopping at the root.
fn removeEmptyParents(io: Io, target: Target) void {
    var path: ?[]const u8 = target.dest;
    while (path) |p| : (path = std.fs.path.dirname(p)) {
        if (p.len <= target.root.len or !std.mem.startsWith(u8, p, target.root)) break;
        Io.Dir.cwd().deleteDir(io, p) catch |err| switch (err) {
            error.FileNotFound => {},
            else => break,
        };
    }
}

/// A line of a dump file.
pub const DumpEntry = struct {
    repo: []const u8,
    branch: ?[]const u8 = null,
};

/// Parses a dump file as written by `jj-list --out dump`: one repository
/// per line, optionally followed by a branch as in git-get dump files.
/// Blank lines and `#` comments are ignored. On `error.InvalidLine`,
/// `bad_line` is set to the 1-based line number.
pub fn parseDump(arena: Allocator, contents: []const u8, bad_line: *usize) error{ InvalidLine, OutOfMemory }![]DumpEntry {
    var entries: std.ArrayList(DumpEntry) = .empty;
    var lines = std.mem.splitScalar(u8, contents, '\n');
    var n: usize = 0;
    while (lines.next()) |raw| {
        n += 1;
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const entry: DumpEntry = .{ .repo = fields.next().?, .branch = fields.next() };
        if (fields.next() != null) {
            bad_line.* = n;
            return error.InvalidLine;
        }
        try entries.append(arena, entry);
    }
    return entries.items;
}

test parseDump {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var bad: usize = 0;
    const entries = try parseDump(arena.allocator(),
        \\# my repos
        \\https://github.com/grdl/git-get
        \\
        \\  grdl/other   dev  
        \\
    , &bad);
    try std.testing.expectEqual(2, entries.len);
    try std.testing.expectEqualStrings("https://github.com/grdl/git-get", entries[0].repo);
    try std.testing.expectEqual(null, entries[0].branch);
    try std.testing.expectEqualStrings("grdl/other", entries[1].repo);
    try std.testing.expectEqualStrings("dev", entries[1].branch.?);

    try std.testing.expectError(error.InvalidLine, parseDump(arena.allocator(), "a\nb c d\n", &bad));
    try std.testing.expectEqual(2, bad);
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
