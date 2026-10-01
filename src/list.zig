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

/// A tracked remote bookmark that has diverged from its local bookmark.
pub const Divergence = struct {
    name: []const u8,
    remote: []const u8,
    /// Commits on the local bookmark not on the remote.
    ahead: u64,
    /// Commits on the remote bookmark not on the local one.
    behind: u64,
};

/// The state of a repository's working copy and bookmarks.
pub const Status = struct {
    /// The closest bookmark at or below the working-copy commit, preferring
    /// local bookmarks, e.g. `main` or `main@origin`.
    bookmark: ?[]const u8 = null,
    /// The working-copy commit has changes.
    modified: bool = false,
    /// The working-copy commit has conflicts.
    conflict: bool = false,
    /// Local bookmarks that are conflicted.
    conflicted_bookmarks: []const []const u8 = &.{},
    /// Tracked remote bookmarks out of sync with their local bookmark.
    diverged: []const Divergence = &.{},

    pub fn isClean(self: Status) bool {
        return !self.modified and !self.conflict and
            self.conflicted_bookmarks.len == 0 and self.diverged.len == 0;
    }

    /// Writes a short summary such as `ok` or `modified, main 1 ahead of origin`.
    pub fn format(self: Status, w: *Io.Writer) Io.Writer.Error!void {
        if (self.isClean()) return w.writeAll("ok");
        var sep: []const u8 = "";
        if (self.modified) {
            try w.writeAll("modified");
            sep = ", ";
        }
        if (self.conflict) {
            try w.print("{s}conflict", .{sep});
            sep = ", ";
        }
        for (self.conflicted_bookmarks) |name| {
            try w.print("{s}{s} conflicted", .{ sep, name });
            sep = ", ";
        }
        for (self.diverged) |d| {
            try w.print("{s}{s}", .{ sep, d.name });
            if (d.ahead > 0) try w.print(" {d} ahead", .{d.ahead});
            if (d.ahead > 0 and d.behind > 0) try w.writeAll(",");
            if (d.behind > 0) try w.print(" {d} behind", .{d.behind});
            try w.print("{s} {s}", .{ if (d.behind == 0) " of" else "", d.remote });
            sep = ", ";
        }
    }
};

// One line per commit: whether it's the working copy, empty, conflicted,
// and its bookmarks with local ones first. The revset yields the working
// copy and the nearest bookmarked ancestors.
const log_revset = "@ | heads(::@ & (bookmarks() | remote_bookmarks()))";
const log_template =
    \\current_working_copy ++ "\t" ++ empty ++ "\t" ++ conflict ++ "\t" ++
    \\separate(" ",
    \\  local_bookmarks.map(|b| b.name()).join(" "),
    \\  remote_bookmarks.map(|b| b.name() ++ "@" ++ b.remote()).join(" "),
    \\) ++ "\n"
;

// Conflicted local bookmarks and tracked remote bookmarks that have
// diverged from their local counterpart. A remote ref's ahead count is
// how far it is ahead of the local bookmark, so the two are swapped to
// report from the local bookmark's point of view. The `git` pseudo-remote
// of colocated repositories mirrors local state and isn't interesting.
const bookmark_template =
    \\if(remote,
    \\  if(remote != "git" && tracking_present && !synced,
    \\    "remote\t" ++ name ++ "\t" ++ remote ++ "\t" ++
    \\    self.tracking_behind_count().lower() ++ "\t" ++
    \\    self.tracking_ahead_count().lower() ++ "\n"),
    \\  if(conflict, "conflict\t" ++ name ++ "\n"))
;

pub const StatusError = error{ JjFailed, InvalidOutput } || std.process.RunError;

/// Reads the status of the repository at `path`. The first jj command
/// snapshots the working copy so modifications are noticed; the second
/// reuses that snapshot.
pub fn status(arena: Allocator, io: Io, path: []const u8) StatusError!Status {
    const log = try jj(arena, io, &.{ "jj", "-R", path, "--color=never", "--no-pager", "log", "--no-graph", "-r", log_revset, "-T", log_template });
    const bookmarks = try jj(arena, io, &.{ "jj", "-R", path, "--color=never", "--no-pager", "--ignore-working-copy", "bookmark", "list", "-T", bookmark_template });
    return parseStatus(arena, log, bookmarks);
}

fn jj(arena: Allocator, io: Io, argv: []const []const u8) StatusError![]const u8 {
    const result = try std.process.run(arena, io, .{ .argv = argv });
    if (result.term != .exited or result.term.exited != 0) return error.JjFailed;
    return result.stdout;
}

fn parseStatus(arena: Allocator, log: []const u8, bookmarks: []const u8) error{ InvalidOutput, OutOfMemory }!Status {
    var result: Status = .{};

    var lines = std.mem.tokenizeScalar(u8, log, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const is_wc = try parseBool(fields.next());
        const empty = try parseBool(fields.next());
        const conflict = try parseBool(fields.next());
        const names = fields.next() orelse return error.InvalidOutput;
        if (is_wc) {
            result.modified = !empty;
            result.conflict = conflict;
        }
        if (result.bookmark == null and names.len > 0) {
            result.bookmark = names[0 .. std.mem.indexOfScalar(u8, names, ' ') orelse names.len];
        }
    }

    var conflicted: std.ArrayList([]const u8) = .empty;
    var diverged: std.ArrayList(Divergence) = .empty;
    lines = std.mem.tokenizeScalar(u8, bookmarks, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next().?;
        if (std.mem.eql(u8, kind, "conflict")) {
            try conflicted.append(arena, fields.next() orelse return error.InvalidOutput);
        } else if (std.mem.eql(u8, kind, "remote")) {
            const name = fields.next() orelse return error.InvalidOutput;
            const remote = fields.next() orelse return error.InvalidOutput;
            const ahead = std.fmt.parseInt(u64, fields.next() orelse "", 10) catch return error.InvalidOutput;
            const behind = std.fmt.parseInt(u64, fields.next() orelse "", 10) catch return error.InvalidOutput;
            try diverged.append(arena, .{ .name = name, .remote = remote, .ahead = ahead, .behind = behind });
        } else {
            return error.InvalidOutput;
        }
    }
    // Ahead/behind counts against a conflicted bookmark are meaningless;
    // the conflict says it all.
    var i: usize = 0;
    while (i < diverged.items.len) {
        const name = diverged.items[i].name;
        for (conflicted.items) |c| {
            if (std.mem.eql(u8, c, name)) {
                _ = diverged.orderedRemove(i);
                break;
            }
        } else i += 1;
    }
    result.conflicted_bookmarks = conflicted.items;
    result.diverged = diverged.items;
    return result;
}

fn parseBool(field: ?[]const u8) error{InvalidOutput}!bool {
    const f = field orelse return error.InvalidOutput;
    if (std.mem.eql(u8, f, "true")) return true;
    if (std.mem.eql(u8, f, "false")) return false;
    return error.InvalidOutput;
}

/// Reads the status of every repository concurrently. A repository whose
/// status can't be read gets an error instead. `arena` must be threadsafe.
pub fn statusAll(arena: Allocator, io: Io, root: []const u8, repos: []const []const u8) (Allocator.Error || Io.Cancelable)![]StatusError!Status {
    const results = try arena.alloc(StatusError!Status, repos.len);
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (repos, results) |repo, *result| {
        group.async(io, statusInto, .{ arena, io, try std.fs.path.join(arena, &.{ root, repo }), result });
    }
    try group.await(io);
    return results;
}

fn statusInto(arena: Allocator, io: Io, path: []const u8, result: *(StatusError!Status)) void {
    result.* = status(arena, io, path);
}

/// Orders paths component by component, so `a/b` sorts before `a-b` and
/// every directory's entries stay together.
fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    for (a[0..@min(a.len, b.len)], b[0..@min(a.len, b.len)]) |x, y| {
        if (x == y) continue;
        if (x == '/') return true;
        if (y == '/') return false;
        return x < y;
    }
    return a.len < b.len;
}

test discover {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{
        "github.com/b/two/.jj",
        "github.com/a/one/.jj",
        "github.com/a-b/.jj",
        "github.com/a/one/nested/.jj",
        "github.com/a/plain-git/.git",
        "gitlab.com/x/.jj",
        "empty",
    }) |path| try tmp.dir.createDirPath(io, path);

    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const root = try tmp.dir.realPathFileAlloc(io, ".", arena.allocator());
    const repos = try discover(arena.allocator(), io, root);

    try std.testing.expectEqual(4, repos.len);
    try std.testing.expectEqualStrings("github.com/a/one", repos[0]);
    try std.testing.expectEqualStrings("github.com/a-b", repos[1]);
    try std.testing.expectEqualStrings("github.com/b/two", repos[2]);
    try std.testing.expectEqualStrings("gitlab.com/x", repos[3]);
}

test parseStatus {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseStatus(
        arena.allocator(),
        "true\tfalse\tfalse\t\nfalse\ttrue\tfalse\tmain other\n",
        "remote\tmain\torigin\t1\t2\nconflict\tdev\nremote\tdev\torigin\t1\t0\n",
    );
    try std.testing.expectEqualStrings("main", st.bookmark.?);
    try std.testing.expect(st.modified);
    try std.testing.expect(!st.conflict);
    try std.testing.expectEqual(1, st.conflicted_bookmarks.len);
    try std.testing.expectEqualStrings("dev", st.conflicted_bookmarks[0]);
    try std.testing.expectEqual(1, st.diverged.len);
    try std.testing.expectEqual(1, st.diverged[0].ahead);
    try std.testing.expectEqual(2, st.diverged[0].behind);

    const summary = try std.fmt.allocPrint(arena.allocator(), "{f}", .{st});
    try std.testing.expectEqualStrings("modified, dev conflicted, main 1 ahead, 2 behind origin", summary);

    const clean = try parseStatus(arena.allocator(), "true\ttrue\tfalse\tmain\n", "");
    try std.testing.expect(clean.isClean());
    try std.testing.expectEqualStrings("main", clean.bookmark.?);
    try std.testing.expectEqualStrings("ok", try std.fmt.allocPrint(arena.allocator(), "{f}", .{clean}));

    const ahead = try parseStatus(arena.allocator(), "true\ttrue\tfalse\t\n", "remote\tmain\torigin\t3\t0\n");
    try std.testing.expectEqualStrings("main 3 ahead of origin", try std.fmt.allocPrint(arena.allocator(), "{f}", .{ahead}));

    try std.testing.expectError(error.InvalidOutput, parseStatus(arena.allocator(), "yes\n", ""));
}
