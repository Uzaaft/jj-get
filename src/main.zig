const std = @import("std");
const Io = std.Io;

const jj_get = @import("jj_get");

const usage =
    \\Usage: jj-get [options] <repository>
    \\
    \\Clone a repository into ~/repositories/<host>/<path> using jj.
    \\
    \\Repository formats:
    \\  user/repo                         resolved against github.com
    \\  github.com/user/repo
    \\  https://github.com/user/repo.git
    \\  git@github.com:user/repo.git
    \\
    \\Options:
    \\  -h, --help    Show this help
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    const io = init.io;
    const args = try init.minimal.args.toSlice(arena);

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    var repo: ?[]const u8 = null;
    for (args[1..]) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            var stdout_writer: Io.File.Writer = .init(.stdout(), io, &.{});
            try stdout_writer.interface.writeAll(usage);
            return 0;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            try stderr.print("error: unknown option '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        } else if (repo != null) {
            try stderr.print("error: unexpected argument '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        } else {
            repo = arg;
        }
    }

    const home = init.environ_map.get("HOME") orelse {
        try stderr.writeAll("error: HOME is not set\n");
        return 1;
    };

    const target = jj_get.get.resolve(arena, repo orelse {
        try stderr.print("error: missing repository\n\n{s}", .{usage});
        return 2;
    }, .{
        .root = try std.fs.path.join(arena, &.{ home, "repositories" }),
    }) catch |err| switch (err) {
        error.EmptyPath => {
            try stderr.print("error: invalid repository '{s}'\n", .{repo.?});
            return 1;
        },
        else => |e| return e,
    };

    jj_get.get.clone(io, target) catch |err| switch (err) {
        error.CloneFailed => return 1,
        error.AlreadyExists => {
            try stderr.print("error: {s} already exists\n", .{target.dest});
            return 1;
        },
        else => |e| return e,
    };
    return 0;
}
