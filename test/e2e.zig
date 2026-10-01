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
    const version = try sb.ok(&.{ jj_get, "--version" });
    try testing.expect(std.mem.startsWith(u8, version, "jj-get "));
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

/// Returns the status part of the flat jj-list line for `dest`.
fn statusOf(out: []const u8, dest: []const u8) ![]const u8 {
    var lines = std.mem.tokenizeScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (std.mem.startsWith(u8, line, dest) and line.len > dest.len and line[dest.len] == ' ') return line[dest.len + 1 ..];
    }
    std.debug.print("no line for {s} in:\n{s}\n", .{ dest, out });
    return error.TestUnexpectedResult;
}

test "list prints every repository under the root" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    const b = try sb.source("src/b");
    const a = try sb.source("src/a");
    try sb.clone(root, b);
    try sb.clone(root, a);

    const out = try sb.ok(&.{ try sb.jjList(), "--root", root, "--out", "flat" });
    const want = try std.fmt.allocPrint(sb.arena.allocator(), "{s} main ok\n{s} main ok\n", .{ try sb.dest(root, a), try sb.dest(root, b) });
    try testing.expectEqualStrings(want, out);
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
    try testing.expectEqualStrings("main [ 1 changed ]", try statusOf(try sb.ok(&.{ list, "-r", root, "-o", "flat" }), dest));

    _ = try sb.ok(&.{ "jj", "-R", dest, "commit", "-m", "local" });
    _ = try sb.ok(&.{ "jj", "-R", dest, "bookmark", "set", "main", "-r", "@-" });
    try testing.expectEqualStrings("main 1 ahead", try statusOf(try sb.ok(&.{ list, "-r", root, "-o", "flat" }), dest));

    // Other bookmarks are listed below the current one.
    _ = try sb.ok(&.{ "jj", "-R", dest, "bookmark", "create", "feature", "-r", "main-" });
    const out = try sb.ok(&.{ list, "-r", root, "-o", "flat" });
    const want = try std.fmt.allocPrint(sb.arena.allocator(), "{s} feature no upstream\n", .{try spaces(sb, dest.len)});
    try testing.expect(std.mem.indexOf(u8, out, want) != null);
    _ = try sb.ok(&.{ "jj", "-R", dest, "bookmark", "delete", "feature" });

    const src = try sb.path("src/project");
    _ = try sb.ok(&.{ "git", "-C", src, "commit", "--quiet", "--allow-empty", "-m", "upstream" });
    _ = try sb.ok(&.{ "jj", "-R", dest, "git", "fetch" });
    // Both sides moved, so the bookmark is now conflicted.
    try testing.expectEqualStrings("main conflicted", try statusOf(try sb.ok(&.{ list, "-r", root, "-o", "flat" }), dest));
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
    try testing.expect(std.mem.indexOf(u8, last, "└── b main ok") != null);
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

test "get restores repositories from a dump" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const old = try sb.path("old");
    const new = try sb.path("new");
    const a = try sb.source("src/a");
    const b = try sb.source("src/b");
    try sb.clone(old, a);
    try sb.clone(old, b);

    const dump = try sb.ok(&.{ try sb.jjList(), "--root", old, "--out", "dump" });
    try sb.tmp.dir.writeFile(testing.io, .{ .sub_path = "dump.txt", .data = dump });
    const dump_path = try sb.path("dump.txt");

    _ = try sb.ok(&.{ jj_get, "--root", new, "--dump", dump_path });
    try testing.expect(sb.exists(try sb.dest(new, a)));
    try testing.expect(sb.exists(try sb.dest(new, b)));

    // Running it again skips what's already there.
    const again = try sb.run(&.{ jj_get, "--root", new, "--dump", dump_path });
    try expectExit(0, again);
    try testing.expect(std.mem.indexOf(u8, again.stderr, "skipping") != null);
}

test "get reports failures from a dump but clones the rest" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    const a = try sb.source("src/a");
    const missing = try std.fmt.allocPrint(sb.arena.allocator(), "file://{s}", .{try sb.path("src/missing")});
    const data = try std.fmt.allocPrint(sb.arena.allocator(), "{s}\n{s}\n", .{ missing, a });
    try sb.tmp.dir.writeFile(testing.io, .{ .sub_path = "dump.txt", .data = data });

    const result = try sb.run(&.{ jj_get, "--root", root, "--dump", try sb.path("dump.txt") });
    try expectExit(1, result);
    try testing.expect(std.mem.indexOf(u8, result.stderr, "1 of 2") != null);
    try testing.expect(sb.exists(try sb.dest(root, a)));
    // Directories created for the failed clone are cleaned up, but ones
    // shared with the successful clone stay.
    try testing.expect(!sb.exists(try sb.dest(root, missing)));
    try testing.expect(sb.exists(std.fs.path.dirname(try sb.dest(root, missing)).?));
}

test "get cleans up after a failed clone" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    try sb.tmp.dir.createDirPath(testing.io, "repos");
    const result = try sb.run(&.{ jj_get, "--root", root, "file:///nonexistent/deep/repo" });
    try expectExit(1, result);
    try testing.expect(!sb.exists(try sb.path("repos/nonexistent")));
    try testing.expect(sb.exists(root));
}

test "get rejects --dump combined with a repository" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    try expectExit(2, try sb.run(&.{ jj_get, "--dump", "x", "a/b" }));
}

test "list fetches before reading status" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    const url = try sb.source("src/project");
    try sb.clone(root, url);
    const src = try sb.path("src/project");
    _ = try sb.ok(&.{ "git", "-C", src, "commit", "--quiet", "--allow-empty", "-m", "upstream" });
    const list = try sb.jjList();

    // Without fetching the new upstream commit is unknown.
    const dest = try sb.dest(root, url);
    try testing.expectEqualStrings("main ok", try statusOf(try sb.ok(&.{ list, "-r", root, "-o", "flat" }), dest));

    // A tracked bookmark with no local changes simply moves forward.
    _ = try sb.ok(&.{ list, "-r", root, "-o", "flat", "--fetch" });
    const desc = try sb.ok(&.{ "jj", "-R", dest, "log", "--no-graph", "-r", "main", "-T", "description" });
    try testing.expectEqualStrings("upstream\n", desc);
}

fn spaces(sb: *Sandbox, n: usize) ![]const u8 {
    const s = try sb.arena.allocator().alloc(u8, n);
    @memset(s, ' ');
    return s;
}

test "list reports repositories it can't read" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    try sb.clone(root, try sb.source("src/a"));
    // Looks like a repository to discovery, but isn't one.
    try sb.tmp.dir.createDirPath(testing.io, "repos/broken/.jj");

    const result = try sb.run(&.{ try sb.jjList(), "--root", root, "-o", "flat" });
    try expectExit(1, result);
    const broken = try sb.path("repos/broken");
    try testing.expectEqualStrings("error", try statusOf(result.stdout, broken));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Oops, errors happened") != null);
}

test "list colors output on request" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    try sb.clone(root, try sb.source("src/a"));
    const colored = try sb.ok(&.{ try sb.jjList(), "--root", root, "--color", "always" });
    try testing.expect(std.mem.indexOf(u8, colored, "\x1b[1;32mok\x1b[0m") != null);
    const plain = try sb.ok(&.{ try sb.jjList(), "--root", root });
    try testing.expect(std.mem.indexOf(u8, plain, "\x1b[") == null);
}

test "list degrades gracefully on stale, forgotten and unreadable working copies" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    const url = try sb.source("src/project");
    try sb.clone(root, url);
    const dest = try sb.dest(root, url);
    const arena = sb.arena.allocator();

    // Rewriting another workspace's working-copy commit while it has
    // unsnapshotted changes makes it stale, as in jj's own tests.
    const stale = try std.fs.path.join(arena, &.{ root, "stale" });
    _ = try sb.ok(&.{ "jj", "-R", dest, "new" });
    _ = try sb.ok(&.{ "jj", "-R", dest, "workspace", "add", "--name", "stale", stale });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(arena, &.{ dest, "main-file" }), .data = "main" });
    try Io.Dir.cwd().writeFile(testing.io, .{ .sub_path = try std.fs.path.join(arena, &.{ stale, "file" }), .data = "stale" });
    _ = try sb.ok(&.{ "jj", "-R", dest, "squash" });

    // A forgotten workspace has no working-copy commit at all.
    const forgotten = try std.fs.path.join(arena, &.{ root, "forgotten" });
    _ = try sb.ok(&.{ "jj", "-R", dest, "workspace", "add", "--name", "forgotten", forgotten });
    _ = try sb.ok(&.{ "jj", "-R", dest, "workspace", "forget", "forgotten" });

    // An unreadable directory makes snapshotting fail.
    const locked = try std.fs.path.join(arena, &.{ dest, "locked" });
    try Io.Dir.cwd().createDirPath(testing.io, locked);
    _ = try sb.ok(&.{ "chmod", "000", locked });
    defer _ = sb.ok(&.{ "chmod", "755", locked }) catch {};

    const result = try sb.run(&.{ try sb.jjList(), "--root", root, "-o", "flat" });
    try expectExit(0, result);
    try testing.expectEqualStrings("main [ snapshot failed ]", try statusOf(result.stdout, dest));
    try testing.expectEqualStrings("main [ stale ]", try statusOf(result.stdout, stale));
    try testing.expect(std.mem.startsWith(u8, try statusOf(result.stdout, forgotten), "(no bookmark) [ no working copy ]"));
    try testing.expect(std.mem.indexOf(u8, result.stdout, "Oops") == null);
}

test "list condenses jj errors to one line" {
    const sb = try Sandbox.init();
    defer sb.deinit();
    const root = try sb.path("repos");
    try sb.tmp.dir.createDirPath(testing.io, "repos/broken/.jj");

    const result = try sb.run(&.{ try sb.jjList(), "--root", root, "-o", "flat" });
    try expectExit(1, result);
    var lines = std.mem.tokenizeScalar(u8, result.stdout, '\n');
    var last: []const u8 = "";
    var count: usize = 0;
    while (lines.next()) |line| : (count += 1) last = line;
    // The repository line, the header and exactly one line of explanation.
    try testing.expectEqual(3, count);
    try testing.expect(std.mem.startsWith(u8, last, try sb.path("repos/broken")));
}
