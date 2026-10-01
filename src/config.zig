//! Settings shared by jj-get and jj-list, gathered from command line flags,
//! `JJGET_*` environment variables and the `[jjget]` table in jj's config,
//! in that order of precedence.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Config = struct {
    root: ?[]const u8 = null,
    host: ?[]const u8 = null,
    scheme: ?[]const u8 = null,
    skip_host: ?bool = null,

    /// Fills every unset field from `fallback`.
    pub fn orElse(self: Config, fallback: Config) Config {
        var result = self;
        inline for (@typeInfo(Config).@"struct".fields) |field| {
            if (@field(result, field.name) == null) @field(result, field.name) = @field(fallback, field.name);
        }
        return result;
    }
};

/// Config keys, as spelled in jj config and (uppercased, with `_` for `-`)
/// in environment variables.
const keys = .{
    .{ "root", "root" },
    .{ "host", "host" },
    .{ "scheme", "scheme" },
    .{ "skip-host", "skip_host" },
};

pub const Error = error{InvalidValue} || Allocator.Error;

/// Reads `JJGET_ROOT`, `JJGET_HOST`, `JJGET_SCHEME` and `JJGET_SKIP_HOST`.
/// `bad_key` is set to the offending variable on `error.InvalidValue`.
pub fn fromEnv(env: *const std.process.Environ.Map, bad_key: *[]const u8) Error!Config {
    var config: Config = .{};
    inline for (keys) |key| {
        const name = comptime envName(key[0]);
        if (env.get(name)) |value| {
            bad_key.* = name;
            @field(config, key[1]) = try parseValue(@FieldType(Config, key[1]), value);
        }
    }
    return config;
}

fn envName(comptime key: []const u8) []const u8 {
    comptime {
        var name: [key.len]u8 = undefined;
        for (key, 0..) |c, i| name[i] = if (c == '-') '_' else std.ascii.toUpper(c);
        const final = name;
        return "JJGET_" ++ &final;
    }
}

fn parseValue(comptime T: type, value: []const u8) Error!T {
    return switch (T) {
        ?[]const u8 => value,
        ?bool => if (std.ascii.eqlIgnoreCase(value, "true") or std.mem.eql(u8, value, "1"))
            true
        else if (std.ascii.eqlIgnoreCase(value, "false") or std.mem.eql(u8, value, "0"))
            false
        else
            error.InvalidValue,
        else => @compileError("unsupported config type"),
    };
}

pub const JjError = error{JjConfigFailed} || Error || std.process.RunError;

/// Reads the `[jjget]` table from jj's config. `bad_key` is set to the
/// offending key on `error.InvalidValue`.
pub fn fromJj(arena: Allocator, io: Io, bad_key: *[]const u8) JjError!Config {
    const result = try std.process.run(arena, io, .{
        .argv = &.{ "jj", "config", "list", "jjget", "-T", "name ++ \"\\t\" ++ json(value) ++ \"\\n\"" },
    });
    if (result.term != .exited or result.term.exited != 0) return error.JjConfigFailed;
    return parseJjList(arena, result.stdout, bad_key);
}

/// Parses `<name>\t<json value>` lines as printed by `jj config list`.
fn parseJjList(arena: Allocator, output: []const u8, bad_key: *[]const u8) Error!Config {
    var config: Config = .{};
    var lines = std.mem.tokenizeScalar(u8, output, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        const name = line[0..tab];
        const json = line[tab + 1 ..];
        inline for (keys) |key| {
            if (std.mem.eql(u8, name, "jjget." ++ key[0])) {
                bad_key.* = name;
                const T = @typeInfo(@FieldType(Config, key[1])).optional.child;
                @field(config, key[1]) = std.json.parseFromSliceLeaky(T, arena, json, .{}) catch |err| switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidValue,
                };
            }
        }
    }
    return config;
}

/// Expands a leading `~` in `path` to `home`.
pub fn expandHome(arena: Allocator, path: []const u8, home: ?[]const u8) Allocator.Error![]const u8 {
    const h = home orelse return path;
    if (std.mem.eql(u8, path, "~")) return h;
    if (std.mem.startsWith(u8, path, "~/")) return std.fs.path.join(arena, &.{ h, path[2..] });
    return path;
}

test "orElse prefers set fields" {
    const flags: Config = .{ .root = "/flag" };
    const env: Config = .{ .root = "/env", .host = "gitlab.com", .skip_host = false };
    const jj: Config = .{ .host = "codeberg.org", .scheme = "https", .skip_host = true };
    const merged = flags.orElse(env).orElse(jj);
    try std.testing.expectEqualStrings("/flag", merged.root.?);
    try std.testing.expectEqualStrings("gitlab.com", merged.host.?);
    try std.testing.expectEqualStrings("https", merged.scheme.?);
    try std.testing.expectEqual(false, merged.skip_host.?);
}

test fromEnv {
    var env: std.process.Environ.Map = .init(std.testing.allocator);
    defer env.deinit();
    try env.put("JJGET_ROOT", "/r");
    try env.put("JJGET_SKIP_HOST", "TRUE");
    var bad: []const u8 = "";
    const config = try fromEnv(&env, &bad);
    try std.testing.expectEqualStrings("/r", config.root.?);
    try std.testing.expectEqual(null, config.host);
    try std.testing.expectEqual(true, config.skip_host.?);

    try env.put("JJGET_SKIP_HOST", "maybe");
    try std.testing.expectError(error.InvalidValue, fromEnv(&env, &bad));
    try std.testing.expectEqualStrings("JJGET_SKIP_HOST", bad);
}

test parseJjList {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    var bad: []const u8 = "";
    const output = "jjget.root\t\"/x y\\\"z\"\n" ++
        "jjget.skip-host\ttrue\n" ++
        "jjget.unknown\t1\n";
    const config = try parseJjList(arena.allocator(), output, &bad);
    try std.testing.expectEqualStrings("/x y\"z", config.root.?);
    try std.testing.expectEqual(true, config.skip_host.?);
    try std.testing.expectEqual(null, config.scheme);

    try std.testing.expectError(error.InvalidValue, parseJjList(arena.allocator(), "jjget.skip-host\t\"yes\"\n", &bad));
    try std.testing.expectEqualStrings("jjget.skip-host", bad);
}

test expandHome {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectEqualStrings("/home/u/code", try expandHome(arena.allocator(), "~/code", "/home/u"));
    try std.testing.expectEqualStrings("/home/u", try expandHome(arena.allocator(), "~", "/home/u"));
    try std.testing.expectEqualStrings("/abs", try expandHome(arena.allocator(), "/abs", "/home/u"));
    try std.testing.expectEqualStrings("~/code", try expandHome(arena.allocator(), "~/code", null));
}
