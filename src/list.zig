//! Discovering and reporting on the repositories under the root directory.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const DiscoverError = Allocator.Error || Io.Dir.OpenError || Io.Dir.Iterator.Error;

/// Finds every jj repository under `root`, returning their paths relative
/// to it in sorted order. Neither jj nor plain Git repositories are
/// descended into, and symlinks aren't followed.
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
    var is_git = false;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, ".jj") and entry.kind == .directory) {
            // A repository; whatever else is in here belongs to it.
            try repos.append(arena, rel);
            return;
        }
        // A file for worktrees and submodules, a directory otherwise.
        if (std.mem.eql(u8, entry.name, ".git")) is_git = true;
        if (entry.kind == .directory) try subdirs.append(arena, try arena.dupe(u8, entry.name));
    }
    // A plain Git working tree can be huge (node_modules, build output)
    // and isn't where jj repositories live, so don't search it.
    if (is_git) return;

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

/// The result of querying a repository: a value, or jj's error message.
pub fn Outcome(comptime T: type) type {
    return union(enum) {
        ok: T,
        err: []const u8,
    };
}

/// A local bookmark's relationship with one of its tracked remotes.
pub const Remote = struct {
    name: []const u8,
    /// Commits on the local bookmark not on the remote.
    ahead: u64,
    /// Commits on the remote bookmark not on the local one.
    behind: u64,
};

pub const Bookmark = struct {
    name: []const u8,
    conflict: bool = false,
    /// Tracked remotes, whether in sync or not.
    remotes: []const Remote = &.{},
};

/// The state of a repository's working copy and bookmarks.
pub const Status = struct {
    /// The closest bookmark at or below the working-copy commit, preferring
    /// local bookmarks, e.g. `main` or `main@origin`.
    current: ?[]const u8 = null,
    /// Files changed in the working-copy commit.
    changed: u64 = 0,
    /// Conflicted files in the working-copy commit.
    conflicted: u64 = 0,
    /// Local bookmarks, sorted by name.
    bookmarks: []const Bookmark = &.{},
    /// Why the working copy couldn't be inspected, if it couldn't.
    problem: ?Problem = null,

    pub const Problem = enum {
        /// The working copy is stale; its state is from the last snapshot.
        stale,
        /// Snapshotting failed, e.g. on an unreadable directory; the state
        /// is from the last snapshot.
        snapshot_failed,
        /// The workspace has no working-copy commit, typically because it
        /// was forgotten.
        no_working_copy,
    };

    pub fn bookmark(self: Status, name: []const u8) ?Bookmark {
        for (self.bookmarks) |b| if (std.mem.eql(u8, b.name, name)) return b;
        return null;
    }
};

// Everything needed for a status in one jj invocation. The revset covers
// the working copy, every local and tracked remote bookmark, and the
// nearest bookmarked ancestors of the working copy; the template emits a
// tab-separated record per fact of interest on each of those commits.
//
// A remote ref's ahead count is how far it is ahead of the local
// bookmark, so the two are swapped to report from the local bookmark's
// point of view. The `git` pseudo-remote of colocated repositories
// mirrors local state and is ignored.
const status_revset = "@ | bookmarks() | tracked_remote_bookmarks() | heads(::@ & bookmarks()) | heads(::@ & remote_bookmarks())";
const working_copy_template =
    \\if(current_working_copy,
    \\  "wc\t" ++ self.diff().files().len() ++ "\t" ++ self.conflicted_files().len() ++ "\n") ++
    \\if(self.contained_in("heads(::@ & bookmarks())"),
    \\  local_bookmarks.map(|b| "near\t" ++ b.name() ++ "\n").join("")) ++
    \\if(self.contained_in("heads(::@ & remote_bookmarks())"),
    \\  remote_bookmarks.filter(|b| b.remote() != "git").map(|b|
    \\    "nearremote\t" ++ b.name() ++ "@" ++ b.remote() ++ "\n").join(""))
;
const bookmarks_template =
    \\local_bookmarks.map(|b| "local\t" ++ b.name() ++ "\t" ++ b.conflict() ++ "\n").join("") ++
    \\remote_bookmarks.filter(|b| b.tracked() && b.tracking_present() && b.remote() != "git").map(|b|
    \\  "remote\t" ++ b.name() ++ "\t" ++ b.remote() ++ "\t" ++
    \\  b.tracking_behind_count().lower() ++ "\t" ++ b.tracking_ahead_count().lower() ++ "\n").join("")
;
const status_template = working_copy_template ++ " ++\n" ++ bookmarks_template;

// For a workspace without a working-copy commit, where `@` can't be
// resolved at all.
const bookmarks_revset = "bookmarks() | tracked_remote_bookmarks()";

/// Reads the status of the repository at `path` with a single jj
/// invocation, which also snapshots the working copy.
///
/// Repositories in an unusual state get a degraded status rather than
/// an error where possible: when the working copy can't be snapshotted
/// (it's stale, or a directory in it is unreadable) the last snapshot is
/// used, and a workspace that has been forgotten still reports its
/// bookmarks.
pub fn status(arena: Allocator, io: Io, path: []const u8) Outcome(Status) {
    const base = [_][]const u8{ "jj", "-R", path, "--color=never", "--no-pager" };
    const log = [_][]const u8{ "log", "--no-graph", "-r" };

    const first = switch (jj(arena, io, &(base ++ log ++ .{ status_revset, "-T", status_template }))) {
        .ok => |out| return parsed(arena, out, null),
        .err => |msg| msg,
    };
    const offline = base ++ .{"--ignore-working-copy"} ++ log;
    const second = switch (jj(arena, io, &(offline ++ .{ status_revset, "-T", status_template }))) {
        .ok => |out| return parsed(arena, out, if (std.mem.indexOf(u8, first, "stale") != null) .stale else .snapshot_failed),
        .err => |msg| msg,
    };
    if (std.mem.indexOf(u8, second, "doesn't have a working-copy commit") != null) {
        switch (jj(arena, io, &(offline ++ .{ bookmarks_revset, "-T", bookmarks_template }))) {
            .ok => |out| return parsed(arena, out, .no_working_copy),
            .err => {},
        }
    }
    return .{ .err = second };
}

fn parsed(arena: Allocator, out: []const u8, problem: ?Status.Problem) Outcome(Status) {
    var st = parseStatus(arena, out) catch |err| return .{ .err = @errorName(err) };
    st.problem = problem;
    return .{ .ok = st };
}

/// Fetches from every remote, then reads the status of the repository.
pub fn fetchAndStatus(arena: Allocator, io: Io, path: []const u8) Outcome(Status) {
    switch (jj(arena, io, &.{ "jj", "-R", path, "--color=never", "--no-pager", "git", "fetch", "--all-remotes" })) {
        .ok => {},
        .err => |msg| return .{ .err = msg },
    }
    return status(arena, io, path);
}

/// Returns the URL of the repository's `origin` remote, falling back to
/// its first remote, or null if it has none.
pub fn remoteUrl(arena: Allocator, io: Io, path: []const u8) Outcome(?[]const u8) {
    return switch (jj(arena, io, &.{ "jj", "-R", path, "--color=never", "--no-pager", "--ignore-working-copy", "git", "remote", "list" })) {
        .ok => |out| .{ .ok = parseRemotes(out) },
        .err => |msg| .{ .err = msg },
    };
}

/// Runs jj, returning its stdout or, on failure, its error message.
fn jj(arena: Allocator, io: Io, argv: []const []const u8) Outcome([]const u8) {
    const result = std.process.run(arena, io, .{ .argv = argv }) catch |err| return .{ .err = switch (err) {
        error.FileNotFound => "jj not found in PATH",
        else => @errorName(err),
    } };
    if (result.term == .exited and result.term.exited == 0) return .{ .ok = result.stdout };
    return .{ .err = condense(arena, result.stderr) catch "jj failed" };
}

/// Turns jj's multi-line error report into one line: the error itself
/// and, if any, its innermost cause. Hints are dropped.
fn condense(arena: Allocator, stderr: []const u8) Allocator.Error![]const u8 {
    var headline: ?[]const u8 = null;
    var cause: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, stderr, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \r");
        if (line.len == 0 or std.mem.startsWith(u8, line, "Hint:") or std.mem.startsWith(u8, line, "Caused by")) continue;
        // Causes are numbered "1: ...", "2: ...", innermost last.
        if (std.mem.indexOf(u8, line, ": ")) |i| {
            if (std.fmt.parseInt(u8, line[0..i], 10)) |_| {
                cause = line[i + 2 ..];
                continue;
            } else |_| {}
        }
        if (headline == null) headline = line;
    }
    var head = headline orelse return "jj failed";
    for ([_][]const u8{ "Error: ", "Internal error: " }) |prefix| {
        if (std.mem.startsWith(u8, head, prefix)) head = head[prefix.len..];
    }
    const c = cause orelse return head;
    return std.fmt.allocPrint(arena, "{s}: {s}", .{ head, c });
}

fn parseStatus(arena: Allocator, out: []const u8) error{ InvalidOutput, OutOfMemory }!Status {
    var result: Status = .{};
    var near_remote: ?[]const u8 = null;
    var bookmarks: std.StringArrayHashMapUnmanaged(struct { conflict: bool, remotes: std.ArrayList(Remote) }) = .empty;

    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.splitScalar(u8, line, '\t');
        const kind = fields.next().?;
        if (std.mem.eql(u8, kind, "wc")) {
            result.changed = try parseInt(fields.next());
            result.conflicted = try parseInt(fields.next());
        } else if (std.mem.eql(u8, kind, "near")) {
            if (result.current == null) result.current = try field(fields.next());
        } else if (std.mem.eql(u8, kind, "nearremote")) {
            if (near_remote == null) near_remote = try field(fields.next());
        } else if (std.mem.eql(u8, kind, "local")) {
            const name = try field(fields.next());
            const conflict = std.mem.eql(u8, try field(fields.next()), "true");
            // A conflicted bookmark is listed once per target.
            const entry = try bookmarks.getOrPut(arena, name);
            if (!entry.found_existing) entry.value_ptr.* = .{ .conflict = conflict, .remotes = .empty };
        } else if (std.mem.eql(u8, kind, "remote")) {
            const name = try field(fields.next());
            const remote: Remote = .{
                .name = try field(fields.next()),
                .ahead = try parseInt(fields.next()),
                .behind = try parseInt(fields.next()),
            };
            const entry = try bookmarks.getOrPut(arena, name);
            if (!entry.found_existing) entry.value_ptr.* = .{ .conflict = false, .remotes = .empty };
            try entry.value_ptr.remotes.append(arena, remote);
        } else {
            return error.InvalidOutput;
        }
    }
    if (result.current == null) result.current = near_remote;

    const list = try arena.alloc(Bookmark, bookmarks.count());
    for (bookmarks.keys(), bookmarks.values(), list) |name, value, *b| {
        std.mem.sort(Remote, value.remotes.items, {}, struct {
            fn lt(_: void, x: Remote, y: Remote) bool {
                return std.mem.lessThan(u8, x.name, y.name);
            }
        }.lt);
        b.* = .{ .name = name, .conflict = value.conflict, .remotes = value.remotes.items };
    }
    std.mem.sort(Bookmark, list, {}, struct {
        fn lt(_: void, x: Bookmark, y: Bookmark) bool {
            return std.mem.lessThan(u8, x.name, y.name);
        }
    }.lt);
    result.bookmarks = list;
    return result;
}

fn field(f: ?[]const u8) error{InvalidOutput}![]const u8 {
    return f orelse error.InvalidOutput;
}

fn parseInt(f: ?[]const u8) error{InvalidOutput}!u64 {
    return std.fmt.parseInt(u64, try field(f), 10) catch error.InvalidOutput;
}

fn parseRemotes(out: []const u8) ?[]const u8 {
    var first: ?[]const u8 = null;
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        const space = std.mem.indexOfScalar(u8, line, ' ') orelse continue;
        const url = line[space + 1 ..];
        if (std.mem.eql(u8, line[0..space], "origin")) return url;
        if (first == null) first = url;
    }
    return first;
}

/// Calls `f` on every repository under `root` concurrently, returning
/// the results in order. `arena` must be threadsafe.
pub fn forEach(
    comptime T: type,
    arena: Allocator,
    io: Io,
    root: []const u8,
    repos: []const []const u8,
    comptime f: fn (Allocator, Io, []const u8) T,
) (Allocator.Error || Io.Cancelable)![]T {
    const Task = struct {
        fn run(a: Allocator, i: Io, path: []const u8, result: *T) void {
            result.* = f(a, i, path);
        }
    };
    const results = try arena.alloc(T, repos.len);
    var group: Io.Group = .init;
    defer group.cancel(io);
    for (repos, results) |repo, *result| {
        group.async(io, Task.run, .{ arena, io, try std.fs.path.join(arena, &.{ root, repo }), result });
    }
    try group.await(io);
    return results;
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
        "github.com/a/plain-git/vendor/inner/.jj",
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
    const st = try parseStatus(arena.allocator(), "wc\t2\t1\n" ++
        "near\tmain\n" ++
        "nearremote\tmain@origin\n" ++
        "local\tmain\tfalse\n" ++
        "local\tdev\ttrue\n" ++
        "local\tdev\ttrue\n" ++
        "remote\tmain\tupstream\t0\t3\n" ++
        "remote\tmain\torigin\t1\t2\n" ++
        "local\tlocal-only\tfalse\n");
    try std.testing.expectEqualStrings("main", st.current.?);
    try std.testing.expectEqual(2, st.changed);
    try std.testing.expectEqual(1, st.conflicted);
    try std.testing.expectEqual(3, st.bookmarks.len);
    try std.testing.expectEqualStrings("dev", st.bookmarks[0].name);
    try std.testing.expect(st.bookmarks[0].conflict);
    try std.testing.expectEqualStrings("local-only", st.bookmarks[1].name);
    try std.testing.expectEqual(0, st.bookmarks[1].remotes.len);
    const main = st.bookmark("main").?;
    try std.testing.expectEqual(2, main.remotes.len);
    try std.testing.expectEqualStrings("origin", main.remotes[0].name);
    try std.testing.expectEqual(1, main.remotes[0].ahead);
    try std.testing.expectEqual(2, main.remotes[0].behind);

    const remote_only = try parseStatus(arena.allocator(), "wc\t0\t0\nnearremote\ttest@origin\n");
    try std.testing.expectEqualStrings("test@origin", remote_only.current.?);

    try std.testing.expectError(error.InvalidOutput, parseStatus(arena.allocator(), "wc\tx\t0\n"));
    try std.testing.expectError(error.InvalidOutput, parseStatus(arena.allocator(), "bogus\n"));
}

test condense {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("The working copy is stale (not updated since operation 0b4c8868c690).", try condense(a,
        \\Error: The working copy is stale (not updated since operation 0b4c8868c690).
        \\Hint: Run `jj workspace update-stale` to update it.
        \\See https://docs.jj-vcs.dev/latest/working-copy/#stale-working-copy for more information.
        \\
    ));
    try std.testing.expectEqualStrings("Failed to check out a commit: An object with id 0889 could not be found", try condense(a,
        \\Internal error: Failed to check out a commit
        \\Caused by:
        \\1: Failed to edit commit
        \\2: Current working-copy commit not found
        \\3: An object with id 0889 could not be found
        \\
    ));
    try std.testing.expectEqualStrings("jj failed", try condense(a, ""));
}

test parseRemotes {
    try std.testing.expectEqualStrings("b", parseRemotes("upstream a\norigin b\n").?);
    try std.testing.expectEqualStrings("a", parseRemotes("upstream a\nfork c\n").?);
    try std.testing.expectEqual(null, parseRemotes(""));
}
