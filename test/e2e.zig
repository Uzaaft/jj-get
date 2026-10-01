//! End-to-end tests running the built binaries against local repositories.
//! Requires `jj` and `git` on PATH.
const std = @import("std");
const testing = std.testing;
const Io = std.Io;

const build_options = @import("build_options");

/// An isolated sandbox with its own HOME and jj/git configuration, so the
/// developer's settings (signing keys, default remotes, ...) never leak in.
const Sandbox = struct {
    arena: std.heap.ArenaAllocator,
    tmp: testing.TmpDir,
    base: []const u8,
    env: std.process.Environ.Map,

    fn init() !*Sandbox {
        const self = try testing.allocator.create(Sandbox);
        errdefer testing.allocator.destroy(self);
        self.arena = .init(testing.allocator);
        errdefer self.arena.deinit();
        self.tmp = testing.tmpDir(.{});
        errdefer self.tmp.cleanup();

        const arena = self.arena.allocator();
        self.base = try self.tmp.dir.realPathFileAlloc(testing.io, ".", arena);
        try self.tmp.dir.createDirPath(testing.io, "home");
        try self.tmp.dir.writeFile(testing.io, .{
            .sub_path = "jj.toml",
            .data =
            \\[user]
            \\name = "Test"
            \\email = "test@example.com"
            \\
            ,
        });
        try self.tmp.dir.writeFile(testing.io, .{ .sub_path = "gitconfig", .data = "" });

        self.env = try std.process.Environ.createMap(testing.environ, arena);
        try self.env.put("HOME", try self.path("home"));
        try self.env.put("JJ_CONFIG", try self.path("jj.toml"));
        try self.env.put("GIT_CONFIG_GLOBAL", try self.path("gitconfig"));
        try self.env.put("GIT_CONFIG_NOSYSTEM", "1");
        try self.env.put("GIT_AUTHOR_NAME", "Test");
        try self.env.put("GIT_AUTHOR_EMAIL", "test@example.com");
        try self.env.put("GIT_COMMITTER_NAME", "Test");
        try self.env.put("GIT_COMMITTER_EMAIL", "test@example.com");
        return self;
    }

    fn deinit(self: *Sandbox) void {
        self.tmp.cleanup();
        self.arena.deinit();
        testing.allocator.destroy(self);
    }

    fn path(self: *Sandbox, sub_path: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ self.base, sub_path });
    }

    fn run(self: *Sandbox, argv: []const []const u8) !std.process.RunResult {
        return std.process.run(self.arena.allocator(), testing.io, .{
            .argv = argv,
            .environ_map = &self.env,
        });
    }

    /// Runs a command that must succeed, returning its stdout.
    fn ok(self: *Sandbox, argv: []const []const u8) ![]const u8 {
        const result = try self.run(argv);
        if (result.term != .exited or result.term.exited != 0) {
            const cmd = try std.mem.join(self.arena.allocator(), " ", argv);
            std.debug.print("command failed: {s}\nstderr: {s}\n", .{ cmd, result.stderr });
            return error.CommandFailed;
        }
        return result.stdout;
    }

    /// Creates a git repository at `sub_path` with a single commit on
    /// `main`, returning its file:// URL.
    fn source(self: *Sandbox, sub_path: []const u8) ![]const u8 {
        const dir = try self.path(sub_path);
        _ = try self.ok(&.{ "git", "init", "--quiet", "-b", "main", dir });
        _ = try self.ok(&.{ "git", "-C", dir, "commit", "--quiet", "--allow-empty", "-m", "initial" });
        return std.fmt.allocPrint(self.arena.allocator(), "file://{s}", .{dir});
    }

    /// Where jj-get places a clone of `url` under `root`.
    fn dest(self: *Sandbox, root: []const u8, url: []const u8) ![]const u8 {
        return std.fs.path.join(self.arena.allocator(), &.{ root, std.mem.trimStart(u8, url["file://".len..], "/") });
    }

    /// Clones `url` under `root` with jj-get.
    fn clone(self: *Sandbox, root: []const u8, url: []const u8) !void {
        _ = try self.ok(&.{ jj_get, "--root", root, url });
    }

    /// Returns a `jj-list` symlink to the binary, as installed.
    fn jjList(self: *Sandbox) ![]const u8 {
        const link = try self.path("jj-list");
        // The binary's path from the build system is relative to the cwd.
        const target = try Io.Dir.cwd().realPathFileAlloc(testing.io, jj_get, self.arena.allocator());
        self.tmp.dir.symLink(testing.io, target, "jj-list", .{}) catch |err| switch (err) {
            error.PathAlreadyExists => {},
            else => |e| return e,
        };
        return link;
    }

    fn exists(self: *Sandbox, sub_path: []const u8) bool {
        Io.Dir.cwd().access(testing.io, sub_path, .{}) catch return false;
        _ = self;
        return true;
    }
};

const jj_get = build_options.jj_get;

fn expectExit(code: u8, result: std.process.RunResult) !void {
    testing.expectEqual(std.process.Child.Term{ .exited = code }, result.term) catch |err| {
        std.debug.print("stdout: {s}\nstderr: {s}\n", .{ result.stdout, result.stderr });
        return err;
    };
}

test "get clones into root/path" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const url = try sb.source("src/project");
    const root = try sb.path("repos");

    _ = try sb.ok(&.{ jj_get, "--root", root, url });

    const dest = try sb.dest(root, url);
    try testing.expect(sb.exists(try std.fs.path.join(sb.arena.allocator(), &.{ dest, ".jj" })));
}

test "get refuses to clone over an existing directory" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const url = try sb.source("src/project");
    const root = try sb.path("repos");

    _ = try sb.ok(&.{ jj_get, "--root", root, url });
    const result = try sb.run(&.{ jj_get, "--root", root, url });
    try expectExit(1, result);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "already exists") != null);
}

test "get checks out the requested branch" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const url = try sb.source("src/project");
    const src = try sb.path("src/project");
    _ = try sb.ok(&.{ "git", "-C", src, "checkout", "--quiet", "-b", "dev" });
    _ = try sb.ok(&.{ "git", "-C", src, "commit", "--quiet", "--allow-empty", "-m", "dev" });
    _ = try sb.ok(&.{ "git", "-C", src, "checkout", "--quiet", "main" });
    const root = try sb.path("repos");

    _ = try sb.ok(&.{ jj_get, "--root", root, "--branch", "dev", url });

    const dest = try sb.dest(root, url);
    const desc = try sb.ok(&.{ "jj", "-R", dest, "log", "--no-graph", "-r", "@-", "-T", "description" });
    try testing.expectEqualStrings("dev\n", desc);
}

test "get uses ~/repositories by default" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const url = try sb.source("src/project");

    _ = try sb.ok(&.{ jj_get, url });

    try testing.expect(sb.exists(try sb.dest(try sb.path("home/repositories"), url)));
}

test "get rejects bad usage" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    try expectExit(2, try sb.run(&.{jj_get}));
    try expectExit(2, try sb.run(&.{ jj_get, "--bogus", "a/b" }));
    try expectExit(2, try sb.run(&.{ jj_get, "a/b", "c/d" }));
    try expectExit(2, try sb.run(&.{ jj_get, "a/b", "--root" }));
    try expectExit(0, try sb.run(&.{ jj_get, "--help" }));
}

test "get reads root from jj config, env and flags in increasing precedence" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const url = try sb.source("src/project");
    try sb.tmp.dir.writeFile(testing.io, .{
        .sub_path = "jj.toml",
        .data =
        \\[user]
        \\name = "Test"
        \\email = "test@example.com"
        \\[jjget]
        \\root = "~/from-jj"
        \\
        ,
    });

    _ = try sb.ok(&.{ jj_get, url });
    try testing.expect(sb.exists(try sb.dest(try sb.path("home/from-jj"), url)));

    try sb.env.put("JJGET_ROOT", try sb.path("from-env"));
    _ = try sb.ok(&.{ jj_get, url });
    try testing.expect(sb.exists(try sb.dest(try sb.path("from-env"), url)));

    _ = try sb.ok(&.{ jj_get, "--root", try sb.path("from-flag"), url });
    try testing.expect(sb.exists(try sb.dest(try sb.path("from-flag"), url)));
}

test "get rejects invalid config values" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    try sb.env.put("JJGET_SKIP_HOST", "maybe");
    const result = try sb.run(&.{ jj_get, "a/b" });
    try expectExit(1, result);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "JJGET_SKIP_HOST") != null);
}

/// Splits jj-list output into lines of whitespace-separated columns.
fn columns(sb: *Sandbox, out: []const u8) ![]const []const []const u8 {
    const arena = sb.arena.allocator();
    var rows: std.ArrayList([]const []const u8) = .empty;
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        var cols: std.ArrayList([]const u8) = .empty;
        // Columns are padded with spaces; the status itself uses ", ".
        var it = std.mem.tokenizeSequence(u8, line, "  ");
        while (it.next()) |col| try cols.append(arena, std.mem.trim(u8, col, " "));
        try rows.append(arena, cols.items);
    }
    return rows.items;
}

test "list prints every repository under the root" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    const b = try sb.source("src/b");
    const a = try sb.source("src/a");
    try sb.clone(root, b);
    try sb.clone(root, a);

    const rows = try columns(sb, try sb.ok(&.{ try sb.jjList(), "--root", root, "--out", "flat" }));
    try testing.expectEqual(2, rows.len);
    try testing.expectEqualStrings(try sb.dest(root, a), rows[0][0]);
    try testing.expectEqualStrings(try sb.dest(root, b), rows[1][0]);
    for (rows) |row| {
        try testing.expectEqualStrings("main", row[1]);
        try testing.expectEqualStrings("ok", row[2]);
    }
}

test "list reports working copy and bookmark status" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    const url = try sb.source("src/project");
    try sb.clone(root, url);
    const dest = try sb.dest(root, url);
    const list = try sb.jjList();

    const file = try std.fs.path.join(sb.arena.allocator(), &.{ dest, "file" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = file, .data = "hello" });
    try testing.expectEqualStrings("modified", (try columns(sb, try sb.ok(&.{ list, "-r", root, "-o", "flat" })))[0][2]);

    _ = try sb.ok(&.{ "jj", "-R", dest, "commit", "-m", "local" });
    _ = try sb.ok(&.{ "jj", "-R", dest, "bookmark", "set", "main", "-r", "@-" });
    try testing.expectEqualStrings("main 1 ahead of origin", (try columns(sb, try sb.ok(&.{ list, "-r", root, "-o", "flat" })))[0][2]);

    const src = try sb.path("src/project");
    _ = try sb.ok(&.{ "git", "-C", src, "commit", "--quiet", "--allow-empty", "-m", "upstream" });
    _ = try sb.ok(&.{ "jj", "-R", dest, "git", "fetch" });
    // Both sides moved, so the bookmark is now conflicted.
    const row = (try columns(sb, try sb.ok(&.{ list, "-r", root, "-o", "flat" })))[0];
    try testing.expectEqualStrings("main conflicted", row[2]);
}

test "list fails on a missing root" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const result = try sb.run(&.{ try sb.jjList(), "--root", try sb.path("nope") });
    try expectExit(1, result);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "does not exist") != null);
}

test "list prints a tree by default" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    try sb.clone(root, try sb.source("src/a"));
    try sb.clone(root, try sb.source("src/b"));

    const out = try sb.ok(&.{ try sb.jjList(), "--root", root });
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    try testing.expectEqualStrings(root, lines.next().?);
    var last: []const u8 = "";
    while (lines.next()) |line| last = line;
    try testing.expect(std.mem.startsWith(u8, last, "    "));
    try testing.expect(std.mem.indexOf(u8, last, "└── b  main  ok") != null);
}

test "list rejects unknown formats" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    try expectExit(2, try sb.run(&.{ try sb.jjList(), "--out", "json" }));
    try expectExit(2, try sb.run(&.{ try sb.jjList(), "--out" }));
}

test "list dumps clone urls" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    const a = try sb.source("src/a");
    const b = try sb.source("src/b");
    try sb.clone(root, a);
    try sb.clone(root, b);
    // A repository without a remote can't be dumped.
    _ = try sb.ok(&.{ "jj", "git", "init", try sb.path("repos/local") });

    const result = try sb.run(&.{ try sb.jjList(), "--root", root, "--out", "dump" });
    try expectExit(0, result);
    const want = try std.fmt.allocPrint(sb.arena.allocator(), "{s}\n{s}\n", .{ a, b });
    try testing.expectEqualStrings(want, result.stdout);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "has no remote") != null);
}
