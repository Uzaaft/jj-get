const std = @import("std");
const Io = std.Io;

const jj_get = @import("jj_get");
const Args = jj_get.Args;

const usage =
    \\Usage: jj-get [options] <repository>
    \\
    \\Clone a repository into <root>/<host>/<path> using jj.
    \\
    \\Repository formats:
    \\  user/repo                         resolved against the default host
    \\  github.com/user/repo
    \\  https://github.com/user/repo.git
    \\  git@github.com:user/repo.git
    \\
    \\Options:
    \\  -b, --branch <name>    Bookmark to check out instead of the default branch
    \\  -t, --host <host>      Default host for short references (default: github.com)
    \\  -r, --root <path>      Root directory for repositories (default: ~/repositories)
    \\  -c, --scheme <scheme>  Default scheme for short references (default: ssh)
    \\  -s, --skip-host        Don't create a directory for the host
    \\  -h, --help             Show this help
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var repo: ?[]const u8 = null;
    var root: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var opts: jj_get.get.Options = .{ .root = undefined };

    var args: Args = .init((try init.minimal.args.toSlice(arena))[1..]);
    while (args.next()) |arg| {
        const parsed = parseOption(&args, &opts, &root, &branch) catch {
            try stderr.print("error: option '{s}' requires a value\n\n{s}", .{ arg, usage });
            return 2;
        };
        if (parsed) continue;

        if (args.flag('h', "help")) {
            var stdout_writer: Io.File.Writer = .init(.stdout(), io, &.{});
            try stdout_writer.interface.writeAll(usage);
            return 0;
        } else if (!args.isPositional()) {
            try stderr.print("error: unknown option '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        } else if (repo != null) {
            try stderr.print("error: unexpected argument '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        } else {
            repo = arg;
        }
    }

    opts.root = root orelse blk: {
        const home = init.environ_map.get("HOME") orelse {
            try stderr.writeAll("error: HOME is not set, pass --root\n");
            return 1;
        };
        break :blk try std.fs.path.join(arena, &.{ home, "repositories" });
    };

    const target = jj_get.get.resolve(arena, repo orelse {
        try stderr.print("error: missing repository\n\n{s}", .{usage});
        return 2;
    }, opts) catch |err| switch (err) {
        error.EmptyPath => {
            try stderr.print("error: invalid repository '{s}'\n", .{repo.?});
            return 1;
        },
        else => |e| return e,
    };

    jj_get.get.clone(io, target, .{ .branch = branch }) catch |err| switch (err) {
        error.CloneFailed => return 1,
        error.AlreadyExists => {
            try stderr.print("error: {s} already exists\n", .{target.dest});
            return 1;
        },
        else => |e| return e,
    };
    return 0;
}

/// Handles the options that configure where and how to clone, returning
/// whether the current argument was one of them.
fn parseOption(
    args: *Args,
    opts: *jj_get.get.Options,
    root: *?[]const u8,
    branch: *?[]const u8,
) Args.Error!bool {
    if (try args.option('r', "root")) |v| {
        root.* = v;
    } else if (try args.option('t', "host")) |v| {
        opts.host = v;
    } else if (try args.option('c', "scheme")) |v| {
        opts.scheme = v;
    } else if (try args.option('b', "branch")) |v| {
        branch.* = v;
    } else if (args.flag('s', "skip-host")) {
        opts.skip_host = true;
    } else {
        return false;
    }
    return true;
}
