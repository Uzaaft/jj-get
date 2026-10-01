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
