//! config.zig — Source-of-truth MCP registry backed by ~/.mcpconfig.json.
//!
//! The file is owned entirely by mcpsync — it is a clean, minimal JSON file
//! with a single `mcpServers` key.  No other tool touches it.

const std = @import("std");
const fio = @import("fio.zig");

extern "c" fn getenv(name: [*:0]const u8) ?[*:0]const u8;
fn posixGetenv(name: []const u8) ?[]const u8 {
    var buf: [128]u8 = undefined;
    if (name.len >= buf.len) return null;
    @memcpy(buf[0..name.len], name);
    buf[name.len] = 0;
    const ptr = getenv(@ptrCast(&buf)) orelse return null;
    return std.mem.span(ptr);
}

// ── Types ────────────────────────────────────────────────────────────────────

/// One MCP server entry as stored in the source of truth.
pub const Server = struct {
    name: []const u8,
    /// stdio transport: command path
    command: ?[]const u8 = null,
    /// stdio transport: argument list
    args: []const []const u8 = &.{},
    /// HTTP/SSE transport: URL
    url: ?[]const u8 = null,
    /// Optional explicit transport hint (e.g. "stdio", "sse")
    transport: ?[]const u8 = null,

    pub fn dupe(self: Server, alloc: std.mem.Allocator) !Server {
        var s = self;
        s.name = try alloc.dupe(u8, self.name);
        if (self.command) |c| s.command = try alloc.dupe(u8, c);
        if (self.url) |u| s.url = try alloc.dupe(u8, u);
        if (self.transport) |t| s.transport = try alloc.dupe(u8, t);
        const args_copy = try alloc.alloc([]const u8, self.args.len);
        for (self.args, 0..) |a, i| args_copy[i] = try alloc.dupe(u8, a);
        s.args = args_copy;
        return s;
    }

    pub fn free(self: *Server, alloc: std.mem.Allocator) void {
        alloc.free(self.name);
        if (self.command) |c| alloc.free(c);
        if (self.url) |u| alloc.free(u);
        if (self.transport) |t| alloc.free(t);
        for (self.args) |a| alloc.free(a);
        alloc.free(self.args);
    }

    /// Two servers are "equivalent" if their command/url/args match.
    /// transport is intentionally excluded — it's a Devin-internal hint
    /// not written to target tool configs.
    pub fn eql(self: Server, other: Server) bool {
        if (!strEql(self.command, other.command)) return false;
        if (!strEql(self.url, other.url)) return false;
        if (self.args.len != other.args.len) return false;
        for (self.args, other.args) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        return true;
    }

    fn strEql(a: ?[]const u8, b: ?[]const u8) bool {
        if (a == null and b == null) return true;
        if (a == null or b == null) return false;
        return std.mem.eql(u8, a.?, b.?);
    }
};

/// The in-memory registry of all source-of-truth servers.
pub const Registry = struct {
    servers: std.ArrayList(Server),
    alloc: std.mem.Allocator,

    pub fn init(alloc: std.mem.Allocator) Registry {
        return .{ .servers = .empty, .alloc = alloc };
    }

    pub fn deinit(self: *Registry) void {
        for (self.servers.items) |*s| s.free(self.alloc);
        self.servers.deinit(self.alloc);
    }

    pub fn get(self: *const Registry, name: []const u8) ?*const Server {
        for (self.servers.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }

    pub fn add(self: *Registry, server: Server) !void {
        // replace if name already exists
        for (self.servers.items) |*s| {
            if (std.mem.eql(u8, s.name, server.name)) {
                s.free(self.alloc);
                s.* = try server.dupe(self.alloc);
                return;
            }
        }
        try self.servers.append(self.alloc, try server.dupe(self.alloc));
    }

    pub fn remove(self: *Registry, name: []const u8) bool {
        for (self.servers.items, 0..) |*s, i| {
            if (std.mem.eql(u8, s.name, name)) {
                s.free(self.alloc);
                _ = self.servers.orderedRemove(i);
                return true;
            }
        }
        return false;
    }
};

// ── Path ─────────────────────────────────────────────────────────────────────

pub fn sourcePath(alloc: std.mem.Allocator) ![]const u8 {
    const home = posixGetenv("HOME") orelse return error.NoHome;
    return std.mem.concat(alloc, u8, &.{ home, "/.mcpconfig.json" });
}

// ── Load ─────────────────────────────────────────────────────────────────────

/// Load the registry from ~/.mcpconfig.json.
/// Returns an empty registry if the file doesn't exist or has no mcpServers.
pub fn load(alloc: std.mem.Allocator) !Registry {
    const path = try sourcePath(alloc);
    defer alloc.free(path);

    const text = fio.readFileAlloc(alloc, path, 4 * 1024 * 1024) catch |err| {
        if (err == error.FileNotFound) return Registry.init(alloc);
        return err;
    };
    defer alloc.free(text);

    return parseRegistry(alloc, text);
}

fn parseRegistry(alloc: std.mem.Allocator, text: []const u8) !Registry {
    var reg = Registry.init(alloc);
    errdefer reg.deinit();

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return reg;
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return reg;

    const mcp_val = root.object.get("mcpServers") orelse return reg;
    if (mcp_val != .object) return reg;

    var it = mcp_val.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const obj = entry.value_ptr.*;
        if (obj != .object) continue;

        var srv = Server{ .name = name };

        if (obj.object.get("command")) |v| if (v == .string) {
            srv.command = v.string;
        };
        if (obj.object.get("url")) |v| if (v == .string) {
            srv.url = v.string;
        };
        if (obj.object.get("transport")) |v| if (v == .string) {
            srv.transport = v.string;
        };
        if (obj.object.get("args")) |v| if (v == .array) {
            var list: std.ArrayList([]const u8) = .empty;
            for (v.array.items) |item| {
                if (item == .string) try list.append(alloc, item.string);
            }
            srv.args = try list.toOwnedSlice(alloc);
        };

        try reg.add(srv);
    }

    return reg;
}

// ── Save ─────────────────────────────────────────────────────────────────────

/// Write the registry to ~/.mcpconfig.json.
/// This file is owned by mcpsync; it is always written fresh (no merging needed).
pub fn save(alloc: std.mem.Allocator, reg: *const Registry) !void {
    const path = try sourcePath(alloc);
    defer alloc.free(path);

    var aw = std.Io.Writer.Allocating.init(alloc);
    defer aw.deinit();
    try aw.writer.writeAll("{\n  \"mcpServers\": ");
    try writeMcpServers(&aw.writer, reg);
    try aw.writer.writeAll("\n}\n");
    const out = try aw.toOwnedSlice();
    defer alloc.free(out);

    try fio.writeFileAtomic(alloc, path, out);
}

fn writeMcpServers(writer: anytype, reg: *const Registry) !void {
    try writer.writeAll("{\n");
    for (reg.servers.items, 0..) |s, i| {
        const comma: []const u8 = if (i + 1 < reg.servers.items.len) "," else "";
        try writer.print("    \"{s}\": {{\n", .{s.name});
        if (s.command) |cmd| {
            try writer.print("      \"command\": \"{s}\"", .{cmd});
            if (s.args.len > 0 or s.transport != null) try writer.writeAll(",\n") else try writer.writeAll("\n");
        }
        if (s.url) |u| {
            try writer.print("      \"url\": \"{s}\"", .{u});
            if (s.transport != null) try writer.writeAll(",\n") else try writer.writeAll("\n");
        }
        if (s.args.len > 0) {
            try writer.writeAll("      \"args\": [");
            for (s.args, 0..) |a, ai| {
                const ac: []const u8 = if (ai + 1 < s.args.len) ", " else "";
                try writer.print("\"{s}\"{s}", .{ a, ac });
            }
            try writer.writeAll("]");
            if (s.transport != null) try writer.writeAll(",\n") else try writer.writeAll("\n");
        }
        if (s.transport) |t| {
            try writer.print("      \"transport\": \"{s}\"\n", .{t});
        }
        try writer.print("    }}{s}\n", .{comma});
    }
    try writer.writeAll("  }");
}


