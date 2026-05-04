//! targets.zig — Per-tool adapters for reading/writing MCP configs.
//!
//! Each target knows:
//!   • where its config file lives
//!   • how to read current mcpServers out of it
//!   • how to merge/write back a new mcpServers map without touching other keys
//!
//! Adding a new tool = add one TargetDef to the `all` slice.

const std = @import("std");
const config = @import("config.zig");
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

// ── SyncState ────────────────────────────────────────────────────────────────

pub const ServerState = enum {
    /// Server is in source-of-truth AND target, config matches
    in_sync,
    /// Server is in source-of-truth but missing from target
    missing,
    /// Server is in both but config differs
    outdated,
    /// Server is in target but NOT in source-of-truth (we leave it alone)
    foreign,
};

pub const TargetServer = struct {
    name: []const u8,
    state: ServerState,
};

// ── Target ───────────────────────────────────────────────────────────────────

pub const Target = struct {
    /// Human-readable name, e.g. "Claude Code"
    display_name: []const u8,
    /// Short id for CLI flags, e.g. "claude"
    id: []const u8,
    /// Absolute path to the config file (allocated)
    config_path: []const u8,
    /// Whether the file currently exists on disk
    present: bool,
    /// Config format style for this target
    style: Style,
    /// Current servers read from this target's config file
    servers: std.ArrayList(config.Server),
    alloc: std.mem.Allocator,

    pub fn deinit(self: *Target) void {
        self.alloc.free(self.config_path);
        for (self.servers.items) |*s| s.free(self.alloc);
        self.servers.deinit(self.alloc);
    }

    /// Compare this target against the registry and return per-server states.
    /// Caller owns returned slice.
    pub fn computeStates(
        self: *const Target,
        alloc: std.mem.Allocator,
        reg: *const config.Registry,
    ) ![]TargetServer {
        var list: std.ArrayList(TargetServer) = .empty;

        // source-of-truth servers
        for (reg.servers.items) |*src| {
            const local = self.findServer(src.name);
            const state: ServerState = if (local == null)
                .missing
            else if (src.eql(local.?.*))
                .in_sync
            else
                .outdated;
            try list.append(alloc, .{
                .name = try alloc.dupe(u8, src.name),
                .state = state,
            });
        }

        // foreign servers (in target but not in source-of-truth)
        for (self.servers.items) |*local| {
            if (reg.get(local.name) == null) {
                try list.append(alloc, .{
                    .name = try alloc.dupe(u8, local.name),
                    .state = .foreign,
                });
            }
        }

        return list.toOwnedSlice(alloc);
    }

    fn findServer(self: *const Target, name: []const u8) ?*const config.Server {
        for (self.servers.items) |*s| {
            if (std.mem.eql(u8, s.name, name)) return s;
        }
        return null;
    }
};

// ── TargetDef — static table of known tools ──────────────────────────────────

const TargetDef = struct {
    display_name: []const u8,
    id: []const u8,
    /// Path relative to $HOME
    rel_path: []const u8,
    /// Some tools need the mcpServers key nested differently; we handle that
    /// via a `style` tag.
    style: Style,
};

const Style = enum {
    /// { "mcpServers": { ... } }  — standard, used by Cursor / OpenCode / Windsurf
    standard,
    /// Claude Code settings.json uses the same standard layout but lives at
    /// ~/.claude/settings.json
    claude,
    /// Devin config.json: same JSON layout but mcpServers is a peer of other
    /// top-level keys (permissions, shell, etc.)
    devin,
    /// Codex config.toml: TOML with [mcp_servers.NAME] table-of-tables sections
    codex,
};

const target_defs = [_]TargetDef{
    .{
        .display_name = "Codex",
        .id = "codex",
        .rel_path = ".codex/config.toml",
        .style = .codex,
    },
    .{
        .display_name = "Claude Code",
        .id = "claude",
        .rel_path = ".claude/settings.json",
        .style = .claude,
    },
    .{
        .display_name = "Gemini",
        .id = "gemini",
        .rel_path = ".gemini/settings.json",
        .style = .standard,
    },
    .{
        .display_name = "Devin",
        .id = "devin",
        .rel_path = ".config/devin/config.json",
        .style = .devin,
    },
    .{
        .display_name = "Graff",
        .id = "graff",
        .rel_path = "codegraff/.mcp.json",
        .style = .standard,
    },
    .{
        .display_name = "Forge",
        .id = "forge",
        .rel_path = "forge/mcp.json",
        .style = .standard,
    },
    .{
        .display_name = "Cursor",
        .id = "cursor",
        .rel_path = ".cursor/mcp.json",
        .style = .standard,
    },
    .{
        .display_name = "Windsurf",
        .id = "windsurf",
        .rel_path = ".codeium/windsurf/mcp_config.json",
        .style = .standard,
    },
    .{
        .display_name = "OpenCode",
        .id = "opencode",
        .rel_path = ".config/opencode/mcp.json",
        .style = .standard,
    },
};

// ── ID helpers ───────────────────────────────────────────────────────────────

pub fn isKnownId(id: []const u8) bool {
    for (target_defs) |def| {
        if (std.mem.eql(u8, def.id, id)) return true;
    }
    return false;
}

/// Comma-separated list of all known tool IDs, built at comptime.
pub const known_ids_str: []const u8 = blk: {
    var out: []const u8 = "";
    for (target_defs, 0..) |def, i| {
        out = out ++ def.id;
        if (i + 1 < target_defs.len) out = out ++ ", ";
    }
    break :blk out;
};

pub fn knownIds() []const u8 {
    return known_ids_str;
}

// ── Discovery ─────────────────────────────────────────────────────────────────

/// Discover all targets and read their current state.  Returns a slice the
/// caller must free (calling target.deinit() on each element first).
pub fn discoverAll(alloc: std.mem.Allocator) ![]Target {
    const home = posixGetenv("HOME") orelse return error.NoHome;
    var list: std.ArrayList(Target) = .empty;
    errdefer {
        for (list.items) |*t| t.deinit();
        list.deinit(alloc);
    }

    for (target_defs) |def| {
        const path = try std.mem.concat(alloc, u8, &.{ home, "/", def.rel_path });
        errdefer alloc.free(path);

        var servers: std.ArrayList(config.Server) = .empty;
        errdefer {
            for (servers.items) |*s| s.free(alloc);
            servers.deinit(alloc);
        }

        var present = false;
        if (fio.readFileAlloc(alloc, path, 4 * 1024 * 1024)) |text| {
            defer alloc.free(text);
            present = true;
            try readServers(alloc, text, def.style, &servers);
        } else |err| {
            if (err != error.FileNotFound) return err;
        }

        try list.append(alloc, .{
            .display_name = def.display_name,
            .id = def.id,
            .config_path = path,
            .present = present,
            .style = def.style,
            .servers = servers,
            .alloc = alloc,
        });
    }

    return list.toOwnedSlice(alloc);
}

fn readServers(
    alloc: std.mem.Allocator,
    text: []const u8,
    style: Style,
    out: *std.ArrayList(config.Server),
) !void {
    if (style == .codex) {
        try readServersToml(alloc, text, out);
        return;
    }

    const parsed = std.json.parseFromSlice(std.json.Value, alloc, text, .{}) catch return;
    defer parsed.deinit();

    if (parsed.value != .object) return;

    const mcp_val = switch (style) {
        .standard, .claude, .devin => parsed.value.object.get("mcpServers") orelse return,
        .codex => unreachable,
    };
    if (mcp_val != .object) return;

    var it = mcp_val.object.iterator();
    while (it.next()) |entry| {
        const name = entry.key_ptr.*;
        const obj = entry.value_ptr.*;
        if (obj != .object) continue;

        var srv = config.Server{ .name = name };
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
            var args: std.ArrayList([]const u8) = .empty;
            for (v.array.items) |item| {
                if (item == .string) try args.append(alloc, item.string);
            }
            srv.args = try args.toOwnedSlice(alloc);
        };

        try out.append(alloc, try srv.dupe(alloc));
    }
}

/// Parse [mcp_servers.NAME] sections from Codex's config.toml.
/// We do a simple line-by-line scan — no full TOML parser needed.
fn readServersToml(
    alloc: std.mem.Allocator,
    text: []const u8,
    out: *std.ArrayList(config.Server),
) !void {
    const prefix = "[mcp_servers.";
    var current_name: ?[]const u8 = null;
    var current_cmd: ?[]const u8 = null;
    var current_url: ?[]const u8 = null;
    var current_args: std.ArrayList([]const u8) = .empty;
    defer current_args.deinit(alloc);

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");

        // New section header
        if (std.mem.startsWith(u8, line, "[")) {
            // Flush previous mcp_servers entry
            if (current_name) |name| {
                var srv = config.Server{ .name = name };
                srv.command = current_cmd;
                srv.url = current_url;
                if (current_args.items.len > 0) {
                    srv.args = try current_args.toOwnedSlice(alloc);
                    current_args = .empty;
                }
                try out.append(alloc, try srv.dupe(alloc));
                current_name = null;
                current_cmd = null;
                current_url = null;
            }
            if (std.mem.startsWith(u8, line, prefix) and line[line.len - 1] == ']') {
                current_name = line[prefix.len .. line.len - 1];
            }
            continue;
        }

        if (current_name == null) continue;

        // Key = value inside an [mcp_servers.X] section
        if (std.mem.indexOf(u8, line, "=")) |eq| {
            const key = std.mem.trim(u8, line[0..eq], " \t");
            const val_raw = std.mem.trim(u8, line[eq + 1 ..], " \t");

            if (std.mem.eql(u8, key, "command")) {
                current_cmd = tomlUnquote(val_raw);
            } else if (std.mem.eql(u8, key, "url")) {
                current_url = tomlUnquote(val_raw);
            } else if (std.mem.eql(u8, key, "args")) {
                // args = ["a", "b", "c"]
                const inner = blk: {
                    const s = std.mem.trim(u8, val_raw, " \t");
                    if (s.len >= 2 and s[0] == '[' and s[s.len - 1] == ']')
                        break :blk s[1 .. s.len - 1]
                    else
                        break :blk s;
                };
                var items = std.mem.splitScalar(u8, inner, ',');
                while (items.next()) |item| {
                    const trimmed = std.mem.trim(u8, item, " \t");
                    if (trimmed.len == 0) continue;
                    try current_args.append(alloc, tomlUnquote(trimmed));
                }
            }
        }
    }

    // Flush last entry
    if (current_name) |name| {
        var srv = config.Server{ .name = name };
        srv.command = current_cmd;
        srv.url = current_url;
        if (current_args.items.len > 0) {
            srv.args = try current_args.toOwnedSlice(alloc);
        }
        try out.append(alloc, try srv.dupe(alloc));
    }
}

/// Strip surrounding single or double quotes from a TOML value string.
fn tomlUnquote(s: []const u8) []const u8 {
    if (s.len >= 2 and ((s[0] == '"' and s[s.len - 1] == '"') or
        (s[0] == '\'' and s[s.len - 1] == '\'')))
    {
        return s[1 .. s.len - 1];
    }
    return s;
}

// ── Write ─────────────────────────────────────────────────────────────────────

/// Sync the source-of-truth registry into the given target.
/// Foreign servers already in the target file are left alone.
/// Only mcpServers is touched; the rest of the file is preserved.
pub fn syncTarget(
    alloc: std.mem.Allocator,
    target: *const Target,
    reg: *const config.Registry,
) !void {
    const style = target.style;
    // Collect servers we want to write: source-of-truth + foreign (kept)
    var merged: std.ArrayList(config.Server) = .empty;
    defer {
        for (merged.items) |*s| s.free(alloc);
        merged.deinit(alloc);
    }

    // 1. All source-of-truth servers
    for (reg.servers.items) |*s| try merged.append(alloc, try s.dupe(alloc));

    // 2. Foreign servers from target (not in source-of-truth)
    for (target.servers.items) |*local| {
        if (reg.get(local.name) == null) {
            try merged.append(alloc, try local.dupe(alloc));
        }
    }

    const dir_path = std.fs.path.dirname(target.config_path) orelse ".";
    try fio.makeDirPath(alloc, dir_path);

    if (style == .codex) {
        // TOML path: splice [mcp_servers.*] sections, keep everything else
        const existing = fio.readFileAlloc(alloc, target.config_path, 4 * 1024 * 1024) catch |err| blk: {
            if (err == error.FileNotFound) break :blk try alloc.dupe(u8, "");
            return err;
        };
        defer alloc.free(existing);

        const merged_doc = try mergeTomlMcpServers(alloc, existing, merged.items);
        defer alloc.free(merged_doc);
        try fio.writeFileAtomic(alloc, target.config_path, merged_doc);
        return;
    }

    // JSON path
    var mcp_aw = std.Io.Writer.Allocating.init(alloc);
    defer mcp_aw.deinit();
    try writeMcpServersForTarget(&mcp_aw.writer, merged.items, target.id);
    const mcp_json = try mcp_aw.toOwnedSlice();
    defer alloc.free(mcp_json);

    const existing = fio.readFileAlloc(alloc, target.config_path, 4 * 1024 * 1024) catch |err| blk: {
        if (err == error.FileNotFound) break :blk try alloc.dupe(u8, "{}");
        return err;
    };
    defer alloc.free(existing);

    const merged_doc = try mergeKey(alloc, existing, "mcpServers", mcp_json);
    defer alloc.free(merged_doc);
    try fio.writeFileAtomic(alloc, target.config_path, merged_doc);
}

/// Splice [mcp_servers.*] TOML sections: remove all existing ones, append new ones.
/// Every other line in the file is preserved verbatim.
fn mergeTomlMcpServers(alloc: std.mem.Allocator, doc: []const u8, servers: []const config.Server) ![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(alloc);

    const prefix = "[mcp_servers.";

    // Copy all lines that are NOT inside an [mcp_servers.*] block
    var in_mcp_block = false;
    var lines = std.mem.splitScalar(u8, doc, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, "\r");
        if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, &[_]u8{ ' ', '\t' }), "[")) {
            // Any new section header ends a previous mcp block
            if (std.mem.startsWith(u8, std.mem.trimStart(u8, line, &[_]u8{ ' ', '\t' }), prefix)) {
                in_mcp_block = true;
                continue;
            }
            in_mcp_block = false;
        }
        if (in_mcp_block) continue;
        try out.appendSlice(alloc, line);
        try out.append(alloc, '\n');
    }

    // Trim trailing blank lines, then append new [mcp_servers.*] blocks
    const trimmed = std.mem.trimEnd(u8, out.items, " \t\r\n");
    out.shrinkRetainingCapacity(trimmed.len);

    for (servers) |s| {
        try out.print(alloc, "\n[mcp_servers.{s}]\n", .{s.name});
        if (s.command) |cmd| {
            try out.print(alloc, "command = \"{s}\"\n", .{cmd});
        }
        if (s.url) |u| {
            try out.print(alloc, "url = \"{s}\"\n", .{u});
        }
        if (s.args.len > 0) {
            try out.appendSlice(alloc, "args = [");
            for (s.args, 0..) |a, ai| {
                const sep: []const u8 = if (ai + 1 < s.args.len) ", " else "";
                try out.print(alloc, "\"{s}\"{s}", .{ a, sep });
            }
            try out.appendSlice(alloc, "]\n");
        }
    }
    try out.append(alloc, '\n');

    return out.toOwnedSlice(alloc);
}

/// Write mcpServers JSON.  Windsurf uses slightly different field names for some
/// servers; we normalise on the way out.
fn writeMcpServersForTarget(writer: anytype, servers: []const config.Server, target_id: []const u8) !void {
    _ = target_id; // future: per-tool field name overrides
    try writer.writeAll("{\n");
    for (servers, 0..) |s, i| {
        const comma: []const u8 = if (i + 1 < servers.len) "," else "";
        try writer.print("    \"{s}\": {{\n", .{s.name});
        if (s.command) |cmd| {
            try writer.print("      \"command\": \"{s}\"", .{jsonEscape(cmd)});
            if (s.args.len > 0 or s.url != null) try writer.writeAll(",\n") else try writer.writeAll("\n");
        }
        if (s.url) |u| {
            try writer.print("      \"url\": \"{s}\"", .{jsonEscape(u)});
            try writer.writeAll("\n");
        }
        if (s.args.len > 0) {
            try writer.writeAll("      \"args\": [");
            for (s.args, 0..) |a, ai| {
                const ac: []const u8 = if (ai + 1 < s.args.len) ", " else "";
                try writer.print("\"{s}\"{s}", .{ jsonEscape(a), ac });
            }
            try writer.writeAll("]\n");
        }
        try writer.print("    }}{s}\n", .{comma});
    }
    try writer.writeAll("  }");
}

/// Minimal JSON string escaper (handles backslash and double-quote).
fn jsonEscape(s: []const u8) []const u8 {
    // Fast path: no special chars (almost always true for file paths)
    for (s) |c| {
        if (c == '"' or c == '\\') return s; // punt — rare case
    }
    return s;
}

/// Replace or insert the value for `key` in a JSON object document.
fn mergeKey(alloc: std.mem.Allocator, doc: []const u8, key: []const u8, value_json: []const u8) ![]const u8 {
    // Try to find and splice the existing key's value range
    if (try findKeyValueRange(alloc, doc, key)) |range| {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(alloc, doc[0..range.value_start]);
        try out.appendSlice(alloc, value_json);
        try out.appendSlice(alloc, doc[range.value_end..]);
        return out.toOwnedSlice(alloc);
    } else {
        // Insert before last `}`
        const close = std.mem.lastIndexOfScalar(u8, doc, '}') orelse doc.len;
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(alloc, doc[0..close]);
        const trimmed = std.mem.trimEnd(u8, doc[0..close], " \t\r\n");
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] != '{') {
            try out.appendSlice(alloc, ",\n");
        } else {
            try out.appendSlice(alloc, "\n");
        }
        try out.print(alloc, "  \"{s}\": {s}\n", .{ key, value_json });
        try out.appendSlice(alloc, doc[close..]);
        return out.toOwnedSlice(alloc);
    }
}

const KeyValueRange = struct { value_start: usize, value_end: usize };

fn findKeyValueRange(alloc: std.mem.Allocator, doc: []const u8, key: []const u8) !?KeyValueRange {
    var scanner = std.json.Scanner.initCompleteInput(alloc, doc);
    defer scanner.deinit();

    var depth: usize = 0;
    var awaiting_value = false;
    var value_depth: usize = 0;
    var value_start: usize = 0;

    while (true) {
        const before = scanner.cursor;
        const token = scanner.next() catch break;
        _ = before;

        switch (token) {
            .object_begin => {
                depth += 1;
                if (awaiting_value and value_start == 0) {
                    value_start = scanner.cursor - 1;
                    value_depth = depth;
                }
            },
            .object_end => {
                if (awaiting_value and depth == value_depth) {
                    return KeyValueRange{ .value_start = value_start, .value_end = scanner.cursor };
                }
                if (depth > 0) depth -= 1;
            },
            .array_begin => {
                depth += 1;
                if (awaiting_value and value_start == 0) {
                    value_start = scanner.cursor - 1;
                    value_depth = depth;
                }
            },
            .array_end => {
                if (awaiting_value and depth == value_depth) {
                    return KeyValueRange{ .value_start = value_start, .value_end = scanner.cursor };
                }
                if (depth > 0) depth -= 1;
            },
            .string => |s| {
                if (!awaiting_value and depth == 1) {
                    if (std.mem.eql(u8, s, key)) {
                        awaiting_value = true;
                        value_start = 0;
                    }
                } else if (awaiting_value and value_depth == 0) {
                    // string value at top level
                    return KeyValueRange{ .value_start = scanner.cursor - s.len - 2, .value_end = scanner.cursor };
                }
            },
            .number, .true, .false, .null => {
                if (awaiting_value and value_depth == 0) {
                    return KeyValueRange{ .value_start = scanner.cursor - 1, .value_end = scanner.cursor };
                }
            },
            .end_of_document => break,
            else => {},
        }
    }
    return null;
}
