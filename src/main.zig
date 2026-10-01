const std = @import("std");
const Io = std.Io;

const jj_get = @import("jj_get");
const Args = jj_get.Args;
const config = jj_get.config;

const get_usage =
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

const list_usage =
    \\Usage: jj-list [options]
    \\
    \\List the jj repositories under <root>.
    \\
    \\Options:
    \\  -o, --out <format>  Output format: tree or flat (default: tree)
    \\  -r, --root <path>   Root directory to scan (default: ~/repositories)
    \\  -h, --help          Show this help
    \\
    \\The root can also be set with JJGET_ROOT or jjget.root in jj's config.
    \\
;

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const argv = try init.minimal.args.toSlice(init.arena.allocator());

    var stderr_buffer: [1024]u8 = undefined;
    var stderr_writer: Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr = &stderr_writer.interface;
    defer stderr.flush() catch {};

    // Like git-get, one binary provides both commands and picks one based
    // on the name it was invoked as, typically through a jj-list symlink.
    var args: Args = .init(argv[1..]);
    if (std.mem.eql(u8, std.fs.path.basename(argv[0]), "jj-list")) {
        return listMain(init, &args, stderr);
    }
    return getMain(init, &args, stderr);
}

fn getMain(init: std.process.Init, args: *Args, stderr: *Io.Writer) !u8 {
    const usage = get_usage;
    const arena = init.arena.allocator();
    const io = init.io;

    var repo: ?[]const u8 = null;
    var branch: ?[]const u8 = null;
    var flags: config.Config = .{};

    while (args.next()) |arg| {
        const parsed = parseOption(args, &flags, &branch) catch {
            try stderr.print("error: option '{s}' requires a value\n\n{s}", .{ arg, usage });
            return 2;
        };
        if (parsed) continue;

        if (args.flag('h', "help")) {
            return printUsage(io, usage);
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

    const settings = try loadSettings(init, flags, stderr) orelse return 1;
    const opts: jj_get.get.Options = .{
        .root = settings.root.?,
        .host = settings.host.?,
        .scheme = settings.scheme.?,
        .skip_host = settings.skip_host.?,
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

fn listMain(init: std.process.Init, args: *Args, stderr: *Io.Writer) !u8 {
    const usage = list_usage;
    const arena = init.arena.allocator();
    const io = init.io;

    var flags: config.Config = .{};
    var format: jj_get.render.Format = .tree;
    var bad_format: []const u8 = "";
    while (args.next()) |arg| {
        const parsed = parseListOption(args, &flags, &format, &bad_format) catch |err| switch (err) {
            error.MissingValue => {
                try stderr.print("error: option '{s}' requires a value\n\n{s}", .{ arg, usage });
                return 2;
            },
            error.UnknownFormat => {
                try stderr.print("error: unknown output format '{s}'\n\n{s}", .{ bad_format, usage });
                return 2;
            },
        };
        if (parsed) continue;

        if (args.flag('h', "help")) {
            return printUsage(io, usage);
        } else if (!args.isPositional()) {
            try stderr.print("error: unknown option '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        } else {
            try stderr.print("error: unexpected argument '{s}'\n\n{s}", .{ arg, usage });
            return 2;
        }
    }

    const settings = try loadSettings(init, flags, stderr) orelse return 1;
    const root = settings.root.?;
    const repos = jj_get.list.discover(arena, io, root) catch |err| switch (err) {
        error.FileNotFound => {
            try stderr.print("error: root {s} does not exist\n", .{root});
            return 1;
        },
        else => |e| return e,
    };

    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout = &stdout_writer.interface;
    const statuses = try jj_get.list.statusAll(arena, io, root, repos);
    switch (format) {
        inline else => |f| try @field(jj_get.render, @tagName(f))(arena, stdout, root, repos, statuses),
    }
    try stdout.flush();

    for (statuses) |st| _ = st catch return 1;
    return 0;
}

fn parseListOption(
    args: *Args,
    flags: *config.Config,
    format: *jj_get.render.Format,
    bad_format: *[]const u8,
) (Args.Error || error{UnknownFormat})!bool {
    if (try args.option('r', "root")) |v| {
        flags.root = v;
    } else if (try args.option('o', "out")) |v| {
        bad_format.* = v;
        format.* = std.meta.stringToEnum(jj_get.render.Format, v) orelse return error.UnknownFormat;
    } else {
        return false;
    }
    return true;
}

fn printUsage(io: Io, usage: []const u8) !u8 {
    var stdout_writer: Io.File.Writer = .init(.stdout(), io, &.{});
    try stdout_writer.interface.writeAll(usage);
    return 0;
}

/// Merges `flags` with the environment and jj config and fills in
/// defaults, so every field of the result is set. Returns null after
/// reporting an error.
fn loadSettings(init: std.process.Init, flags: config.Config, stderr: *Io.Writer) !?config.Config {
    const arena = init.arena.allocator();
    var bad_key: []const u8 = "";

    const env = config.fromEnv(init.environ_map, &bad_key) catch |err| switch (err) {
        error.InvalidValue => {
            try stderr.print("error: invalid value for {s}\n", .{bad_key});
            return null;
        },
        else => |e| return e,
    };
    var settings = flags.orElse(env);

    // Spawning jj is only worth it when something is still unset.
    if (settings.root == null or settings.host == null or settings.scheme == null or settings.skip_host == null) {
        const jj = config.fromJj(arena, init.io, &bad_key) catch |err| switch (err) {
            error.InvalidValue => {
                try stderr.print("error: invalid value for {s} in jj config\n", .{bad_key});
                return null;
            },
            error.JjConfigFailed => {
                try stderr.writeAll("error: failed to read jj config\n");
                return null;
            },
            error.FileNotFound => {
                try stderr.writeAll("error: jj not found in PATH\n");
                return null;
            },
            else => |e| return e,
        };
        settings = settings.orElse(jj);
    }

    const home = init.environ_map.get("HOME");
    settings = settings.orElse(.{
        .root = if (home) |h| try std.fs.path.join(arena, &.{ h, "repositories" }) else null,
        .host = "github.com",
        .scheme = "ssh",
        .skip_host = false,
    });
    settings.root = try config.expandHome(arena, settings.root orelse {
        try stderr.writeAll("error: HOME is not set, pass --root\n");
        return null;
    }, home);
    return settings;
}

/// Handles the options that configure where and how to clone, returning
/// whether the current argument was one of them.
fn parseOption(args: *Args, flags: *config.Config, branch: *?[]const u8) Args.Error!bool {
    if (try args.option('r', "root")) |v| {
        flags.root = v;
    } else if (try args.option('t', "host")) |v| {
        flags.host = v;
    } else if (try args.option('c', "scheme")) |v| {
        flags.scheme = v;
    } else if (try args.option('b', "branch")) |v| {
        branch.* = v;
    } else if (args.flag('s', "skip-host")) {
        flags.skip_host = true;
    } else {
        return false;
    }
    return true;
}
