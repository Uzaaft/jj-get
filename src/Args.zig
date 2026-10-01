//! A minimal command line parser supporting `-s value`, `--long value`
//! and `--long=value` options plus positional arguments.
const Args = @This();

const std = @import("std");

args: []const []const u8,
index: usize = 0,
/// The argument most recently returned by `next`.
current: []const u8 = "",
/// Set once `--` is seen; everything after it is positional.
positional_only: bool = false,

pub const Error = error{MissingValue};

pub fn init(args: []const []const u8) Args {
    return .{ .args = args };
}

/// Advances to the next argument.
pub fn next(self: *Args) ?[]const u8 {
    if (self.index >= self.args.len) return null;
    self.current = self.args[self.index];
    self.index += 1;
    if (!self.positional_only and std.mem.eql(u8, self.current, "--")) {
        self.positional_only = true;
        return self.next();
    }
    return self.current;
}

/// Whether the current argument is a positional rather than an option.
pub fn isPositional(self: Args) bool {
    return self.positional_only or !std.mem.startsWith(u8, self.current, "-") or self.current.len == 1;
}

/// Whether the current argument is the boolean option `short`/`long`.
pub fn flag(self: Args, short: ?u8, long: []const u8) bool {
    if (self.positional_only) return false;
    return self.isShort(short) or (std.mem.startsWith(u8, self.current, "--") and std.mem.eql(u8, self.current[2..], long));
}

/// If the current argument is the option `short`/`long`, returns its
/// value, consuming the following argument when it isn't attached.
pub fn option(self: *Args, short: ?u8, long: []const u8) Error!?[]const u8 {
    if (self.positional_only) return null;
    if (std.mem.startsWith(u8, self.current, "--") and std.mem.startsWith(u8, self.current[2..], long)) {
        const rest = self.current[2 + long.len ..];
        if (std.mem.startsWith(u8, rest, "=")) return rest[1..];
        if (rest.len > 0) return null;
    } else if (!self.isShort(short)) {
        return null;
    }
    if (self.index >= self.args.len) return error.MissingValue;
    self.index += 1;
    return self.args[self.index - 1];
}

fn isShort(self: Args, short: ?u8) bool {
    const s = short orelse return false;
    return self.current.len == 2 and self.current[0] == '-' and self.current[1] == s;
}

test Args {
    var args: Args = .init(&.{ "-r", "/a", "--host=gitlab.com", "--scheme", "https", "-s", "repo", "--", "-x" });
    var root: ?[]const u8 = null;
    var host: ?[]const u8 = null;
    var scheme: ?[]const u8 = null;
    var skip = false;
    var positionals: std.ArrayList([]const u8) = .empty;
    defer positionals.deinit(std.testing.allocator);

    while (args.next()) |arg| {
        if (try args.option('r', "root")) |v| {
            root = v;
        } else if (try args.option('t', "host")) |v| {
            host = v;
        } else if (try args.option('c', "scheme")) |v| {
            scheme = v;
        } else if (args.flag('s', "skip-host")) {
            skip = true;
        } else {
            try std.testing.expect(args.isPositional());
            try positionals.append(std.testing.allocator, arg);
        }
    }

    try std.testing.expectEqualStrings("/a", root.?);
    try std.testing.expectEqualStrings("gitlab.com", host.?);
    try std.testing.expectEqualStrings("https", scheme.?);
    try std.testing.expect(skip);
    try std.testing.expectEqual(2, positionals.items.len);
    try std.testing.expectEqualStrings("repo", positionals.items[0]);
    try std.testing.expectEqualStrings("-x", positionals.items[1]);
}

test "missing value" {
    var args: Args = .init(&.{"--root"});
    _ = args.next();
    try std.testing.expectError(error.MissingValue, args.option('r', "root"));
}

test "long option prefix is not a match" {
    var args: Args = .init(&.{"--rooted"});
    _ = args.next();
    try std.testing.expectEqual(null, try args.option('r', "root"));
    try std.testing.expect(!args.flag('r', "root"));
}
