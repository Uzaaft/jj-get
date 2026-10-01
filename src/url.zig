//! Parsing of repository references into clone URLs and on-disk paths.
//!
//! Accepts everything `git clone` does (see the "GIT URLS" section of
//! git-clone(1)) plus shorthand forms like `user/repo` and
//! `github.com/user/repo` that are resolved against a default host.
const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Url = struct {
    scheme: []const u8,
    user: ?[]const u8 = null,
    /// May include a port, e.g. `github.com:22`. Empty for `file` URLs.
    host: []const u8,
    /// Always starts with `/` unless the scheme is `file` and the path
    /// is relative.
    path: []const u8,

    pub fn format(self: Url, w: *std.Io.Writer) std.Io.Writer.Error!void {
        try w.print("{s}://", .{self.scheme});
        if (self.user) |user| try w.print("{s}@", .{user});
        try w.print("{s}{s}", .{ self.host, self.path });
    }

    /// Converts the URL into a relative directory path, e.g.
    /// `ssh://git@github.com:22/~user/repo.git` => `github.com/user/repo`.
    pub fn toPath(self: Url, gpa: Allocator, skip_host: bool) Allocator.Error![]u8 {
        // Drop the port and any `~` from user-relative paths.
        const host = if (std.mem.indexOfScalar(u8, self.host, ':')) |i| self.host[0..i] else self.host;

        const path = try std.mem.replaceOwned(u8, gpa, self.path, "~", "");
        defer gpa.free(path);

        var trimmed = std.mem.trim(u8, path, "/");
        if (std.mem.endsWith(u8, trimmed, ".git")) trimmed = trimmed[0 .. trimmed.len - ".git".len];

        if (skip_host or host.len == 0) return gpa.dupe(u8, trimmed);
        if (trimmed.len == 0) return gpa.dupe(u8, host);
        return std.fmt.allocPrint(gpa, "{s}/{s}", .{ host, trimmed });
    }
};

pub const ParseError = error{EmptyPath} || Allocator.Error;

/// Parses `raw` into a URL, filling in `default_host` and `default_scheme`
/// where the reference doesn't specify them. Returned slices either point
/// into `raw` or are allocated with `gpa`; an arena is the expected use.
pub fn parse(gpa: Allocator, raw: []const u8, default_host: []const u8, default_scheme: []const u8) ParseError!Url {
    var url = if (std.fs.path.isAbsolutePosix(raw))
        // A local repository, as `git clone /path/to/repo` accepts.
        Url{ .scheme = "file", .host = "", .path = raw }
    else if (parseScp(raw)) |scp|
        Url{
            .scheme = "ssh",
            .user = scp.user,
            .host = scp.host,
            .path = try absolute(gpa, scp.path),
        }
    else if (std.mem.indexOf(u8, raw, "://")) |i|
        parseScheme(raw[0..i], raw[i + 3 ..])
    else
        try parseShorthand(gpa, raw, default_host, default_scheme);

    if (std.mem.eql(u8, url.scheme, "git+ssh")) url.scheme = "ssh";
    if (std.mem.eql(u8, url.scheme, "ssh") and url.user == null) url.user = "git";

    // There is no host in a file URL; what looks like one is the first
    // directory of a relative path.
    if (std.mem.eql(u8, url.scheme, "file") and url.host.len > 0) {
        url.path = try std.fmt.allocPrint(gpa, "{s}{s}", .{ url.host, url.path });
        url.host = "";
    }

    if (url.host.len == 0 and std.mem.trim(u8, url.path, "/").len == 0) return error.EmptyPath;
    return url;
}

const Scp = struct { user: []const u8, host: []const u8, path: []const u8 };

/// Matches the scp-like syntax `user@host:path`.
fn parseScp(raw: []const u8) ?Scp {
    const at = std.mem.indexOfScalar(u8, raw, '@') orelse return null;
    const colon = std.mem.indexOfScalarPos(u8, raw, at, ':') orelse return null;
    const user = raw[0..at];
    const host = raw[at + 1 .. colon];
    if (user.len == 0 or host.len == 0) return null;
    for (user) |c| if (!(std.ascii.isAlphanumeric(c) or c == '_')) return null;
    for (host) |c| if (!(std.ascii.isAlphanumeric(c) or c == '.' or c == '_' or c == '-')) return null;
    return .{ .user = user, .host = host, .path = raw[colon + 1 ..] };
}

fn parseScheme(scheme: []const u8, rest: []const u8) Url {
    const slash = std.mem.indexOfScalar(u8, rest, '/') orelse rest.len;
    const authority = rest[0..slash];
    const path = rest[slash..];
    if (std.mem.lastIndexOfScalar(u8, authority, '@')) |at| {
        return .{ .scheme = scheme, .user = authority[0..at], .host = authority[at + 1 ..], .path = path };
    }
    return .{ .scheme = scheme, .host = authority, .path = path };
}

/// Handles references without a scheme. A leading segment containing a
/// dot is taken as the host (`github.com/user/repo`), anything else is
/// resolved against the default host (`user/repo`).
fn parseShorthand(gpa: Allocator, raw: []const u8, default_host: []const u8, default_scheme: []const u8) Allocator.Error!Url {
    const slash = std.mem.indexOfScalar(u8, raw, '/') orelse raw.len;
    const first = raw[0..slash];
    if (slash < raw.len and std.mem.indexOfScalar(u8, first, '.') != null and !std.mem.startsWith(u8, first, ".")) {
        return .{ .scheme = default_scheme, .host = first, .path = raw[slash..] };
    }
    return .{ .scheme = default_scheme, .host = default_host, .path = try absolute(gpa, raw) };
}

fn absolute(gpa: Allocator, path: []const u8) Allocator.Error![]const u8 {
    if (std.mem.startsWith(u8, path, "/")) return path;
    return std.fmt.allocPrint(gpa, "/{s}", .{path});
}

fn testToPath(raw: []const u8, skip_host: bool, want: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const url = try parse(arena.allocator(), raw, "github.com", "ssh");
    const got = try url.toPath(arena.allocator(), skip_host);
    std.testing.expectEqualStrings(want, got) catch |err| {
        std.debug.print("input: {s}\n", .{raw});
        return err;
    };
}

test "toPath" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "ssh://github.com/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "ssh://user@github.com/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "ssh://user@github.com:1234/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "ssh://user@github.com/~user/grdl/git-get.git", "github.com/user/grdl/git-get", "user/grdl/git-get" },
        .{ "git+ssh://github.com/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "git@github.com:grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "git@github.com:/~user/grdl/git-get.git", "github.com/user/grdl/git-get", "user/grdl/git-get" },
        .{ "git://github.com/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "git://github.com/~user/grdl/git-get.git", "github.com/user/grdl/git-get", "user/grdl/git-get" },
        .{ "https://github.com/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "http://github.com/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "https://github.com/grdl/git-get", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "https://github.com/git-get.git", "github.com/git-get", "git-get" },
        .{ "https://github.com/git-get", "github.com/git-get", "git-get" },
        .{ "https://github.com/grdl/sub/path/git-get.git", "github.com/grdl/sub/path/git-get", "grdl/sub/path/git-get" },
        .{ "https://github.com:1234/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "https://github.com/grdl/git-get.git/", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "https://github.com/grdl/git-get/", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "https://github.com/grdl/git-get/////", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "https://github.com/grdl/git-get.git/////", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "ftp://github.com/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "ftps://github.com/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "rsync://github.com/grdl/git-get.git", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "local/grdl/git-get/", "github.com/local/grdl/git-get", "local/grdl/git-get" },
        .{ "file://local/grdl/git-get", "local/grdl/git-get", "local/grdl/git-get" },
        .{ "gitlab.com/grdl/git-get", "gitlab.com/grdl/git-get", "grdl/git-get" },
        .{ "grdl/git-get", "github.com/grdl/git-get", "grdl/git-get" },
        .{ "/srv/git/project.git", "srv/git/project", "srv/git/project" },
        .{ "file:///srv/git/project", "srv/git/project", "srv/git/project" },
    };
    for (cases) |c| {
        try testToPath(c[0], false, c[1]);
        try testToPath(c[0], true, c[2]);
    }
}

test "default scheme" {
    const cases = [_]struct { []const u8, []const u8, []const u8 }{
        .{ "grdl/git-get", "ssh", "ssh://git@github.com/grdl/git-get" },
        .{ "grdl/git-get", "https", "https://github.com/grdl/git-get" },
        .{ "https://github.com/grdl/git-get", "ssh", "https://github.com/grdl/git-get" },
        .{ "https://github.com/grdl/git-get", "https", "https://github.com/grdl/git-get" },
        .{ "ssh://github.com/grdl/git-get", "ssh", "ssh://git@github.com/grdl/git-get" },
        .{ "ssh://github.com/grdl/git-get", "https", "ssh://git@github.com/grdl/git-get" },
        .{ "git+ssh://github.com/grdl/git-get", "https", "ssh://git@github.com/grdl/git-get" },
        .{ "git@github.com:grdl/git-get", "ssh", "ssh://git@github.com/grdl/git-get" },
        .{ "git@github.com:grdl/git-get", "https", "ssh://git@github.com/grdl/git-get" },
        .{ "gitlab.com/grdl/git-get", "https", "https://gitlab.com/grdl/git-get" },
        .{ "/srv/git/project", "ssh", "file:///srv/git/project" },
    };
    for (cases) |c| {
        var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
        defer arena.deinit();
        const url = try parse(arena.allocator(), c[0], "github.com", c[1]);
        const got = try std.fmt.allocPrint(arena.allocator(), "{f}", .{url});
        try std.testing.expectEqualStrings(c[2], got);
    }
}

test "empty path is rejected" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expectError(error.EmptyPath, parse(arena.allocator(), "file://", "github.com", "ssh"));
    try std.testing.expectError(error.EmptyPath, parse(arena.allocator(), "", "", "ssh"));
}
